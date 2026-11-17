/**
 * Example plugin: a panel of tiles that opens what the chat has made.
 *
 * The shelf shows as a pill above the composer ("Shelf · 4"). Tapping it opens a panel pane of
 * tiles, drawn as the Pinned screen draws pins: the files the chat wrote or changed (pictures,
 * PDFs, and documents first), the subagents it started, and the Godot game of its workspace. A
 * tap on a tile opens the file, the subagent's chat, or the game in the panel's pane, with Back to
 * the tiles.
 *
 * It has no tool and no state of its own: everything comes from what the server already knows
 * about the chat. After each round of tool calls a hook draws the shelf again.
 *
 * It ships off. Turn it on with `oppi extensions enable example-shelf`; see README.md.
 */
import { createHash } from "node:crypto";

import type { Context } from "@earendil-works/chord/context";
import {
  blocks,
  defineExtension,
  defineFacet,
  Extensions,
  GenerationTask,
  group,
  hook,
  oppiHost,
  pill,
  stack,
  surface,
  text,
  tiles,
  type SurfaceConversation,
} from "oppi/v1";

/** A place on the shelf: an `oppi://` link, and the name to show instead of the place's own. */
type Tile = { id: string; link: string; title?: string };
type Shelf = { files: Tile[]; subagents: Tile[]; games: Tile[] };

/** A tiles node holds at most 12 tiles. */
const SHOWN = 12;

/** Pictures and PDFs first, then documents, then the rest. */
function rank(path: string): number {
  const extension = path.split(".").pop()?.toLowerCase() ?? "";
  if (["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "pdf"].includes(extension)) return 0;
  if (["md", "txt", "html", "csv", "org"].includes(extension)) return 1;
  return 2;
}

/** A query value with its slashes kept, so a path stays readable in the link. */
function query(value: string): string {
  return encodeURIComponent(value).replaceAll("%2F", "/");
}

/**
 * A tile's id: stable while the place is on the shelf, and a plain identifier (letters, digits,
 * `.`, `_`, `:`, `-`, at most 128), which a path or an id may not be. A short hash of the place
 * keeps the id the same as the shelf grows and reorders.
 */
function tileId(kind: string, key: string): string {
  return `${kind}:${createHash("sha256").update(key).digest("hex").slice(0, 16)}`;
}

/**
 * The chat's shelf, read fresh each time the panel is drawn. `undefined` while the chat has made
 * nothing, so there is no pill.
 */
async function load(
  conversation: SurfaceConversation,
  context: Context,
): Promise<Shelf | undefined> {
  const activity = await oppiHost().sessionActivity(conversation, context);
  if (!activity) return undefined;
  const session = query(activity.sessionId);

  // Newest first, then by kind: a stable sort keeps the newest first within a kind.
  const files = [...activity.changedFiles]
    .reverse()
    .sort((a, b) => rank(a) - rank(b))
    .map((path) => ({
      id: tileId("file", path),
      link: `oppi://file?session=${session}&path=${query(path)}`,
    }));

  const subagents = activity.children.map((child) => ({
    id: tileId("session", child.id),
    link: `oppi://session/${query(child.id)}`,
    ...(child.name ? { title: child.name } : {}),
  }));

  // The game a `godot_*` tool would mean, or every game of the workspace when there are several.
  const godot = await oppiHost().godot(conversation, context);
  const found = godot ? await godot.resolve(undefined) : undefined;
  const projects = !found ? [] : "project" in found ? [found.project] : found.projects;
  const games = projects.map((project) => ({
    id: tileId("game", project.id),
    link: `oppi://godot?project=${query(project.id)}`,
    title: project.name,
  }));

  return files.length + subagents.length + games.length > 0
    ? { files, subagents, games }
    : undefined;
}

/** One group of tiles, or nothing when the group is empty. */
function shelfGroup(id: string, title: string, items: Tile[]): ReturnType<typeof group>[] {
  if (items.length === 0) return [];
  const shown = items.length > SHOWN ? `${title} (${SHOWN} of ${items.length})` : title;
  return [
    group({
      id,
      title: shown,
      children: [tiles({ id: `${id}:tiles`, items: items.slice(0, SHOWN) })],
    }),
  ];
}

/**
 * The panel: `placement: "panel"` makes the pill open the pane directly, beside the chat on an
 * iPad and full screen on an iPhone.
 */
const shelf = surface<Shelf>({
  id: "example-shelf",
  title: "Shelf",
  placement: { kind: "panel" },
  panel: { icon: "tray", size: "regular" },
  load,
  view: ({ files, subagents, games }) => {
    const count = files.length + subagents.length + games.length;
    return {
      header: { title: "Shelf", subtitle: `${count} ${count === 1 ? "place" : "places"}` },
      pill: pill({ content: [text({ text: `Shelf · ${count}`, style: "headline" })] }),
      sections: [
        blocks({
          id: "shelf",
          fallback: `Shelf: ${count} places`,
          body: stack({
            id: "groups",
            children: [
              ...shelfGroup("files", "Files", files),
              ...shelfGroup("subagents", "Subagents", subagents),
              ...shelfGroup("games", "Games", games),
            ],
          }),
        }),
      ],
    };
  },
});

const ExampleShelf = defineExtension({
  name: "example-shelf",
  runtimes: ["host", "sandbox"],
  hooks: [
    // After each round of tool calls (a file written, a subagent started), draw the shelf again.
    hook(GenerationTask, {
      afterTools: async (_assistant, _results, api, context) => {
        // A hook has no `api.env` for `oppiHost().surfaces(env)`; this is the same loop.
        const surfaces = await oppiHost().sessionSurfaces(api, context);
        if (surfaces) await shelf.sync({ surfaces }, context);
      },
    }),
  ],
  // Drawn again when a chat attaches, after a server restart too.
  surfaces: [shelf],
});

export default defineFacet((_host, self) => self.contribute(Extensions, ExampleShelf));
