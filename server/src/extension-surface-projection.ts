import {
  EXTENSION_UI_SURFACE_WORKING_ICON,
  EXTENSION_UI_SURFACE_WORKING_ICON_STAND_IN,
} from "./extension-surface-icons.js";
import { decodePaneLink } from "./pane-link.js";
import type {
  ExtensionUISurface,
  ExtensionUISurfaceElapsedNode,
  ExtensionUISurfaceTile,
  ExtensionUISurfaceNode,
  ExtensionUISurfacePillNode,
  ExtensionUISurfaceTone,
} from "./types.js";

/**
 * The v1 projection of a blocks tree: the blocks an older client can already draw.
 *
 * Nothing here validates; `extension-surface.ts` has already accepted the tree. A control v1 has
 * no shape for — a button, a toggle, a menu — is collected by title instead of dropped, so a
 * projected surface never loses a verb the surface offered.
 */

/**
 * The words a client without the elapsed node shows: the span as it stands when the surface is
 * sent. It is a snapshot, refreshed whenever the surface republishes; the live tick is the
 * client's. Same shapes the client draws, so both read alike.
 */
export function elapsedSnapshotText(
  node: { since: number; format?: "clock" | "short" },
  now: number = Date.now(),
): string {
  const total = Math.max(0, Math.floor((now - node.since) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const sec = total % 60;
  if (node.format === "short") {
    if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
    return m > 0 ? `${m}m` : `${sec}s`;
  }
  const two = (n: number): string => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(sec)}` : `${m}:${two(sec)}`;
}

type AnyNode = ExtensionUISurfaceNode | ExtensionUISurfacePillNode;

/** Does any tree or the pill hold a node that `matches`? */
function surfaceHolds(surface: ExtensionUISurface, matches: (node: AnyNode) => boolean): boolean {
  const holds = (node: AnyNode): boolean =>
    matches(node) || ("children" in node && node.children.some(holds));
  return (
    (surface.pill?.content.children.some(holds) ?? false) ||
    surface.sections.some((section) => section.composite === "blocks" && holds(section.body))
  );
}

/** The surface with each node `swap` answers for replaced, in its trees and its pill. */
function rewriteNodes(
  surface: ExtensionUISurface,
  swap: (node: AnyNode) => AnyNode | undefined,
): ExtensionUISurface {
  const rewrite = <T extends AnyNode>(node: T): T => {
    const swapped = swap(node);
    if (swapped !== undefined) return swapped as T;
    if (!("children" in node)) return node;
    return { ...node, children: node.children.map(rewrite) };
  };
  return {
    ...surface,
    ...(surface.pill === undefined
      ? {}
      : { pill: { ...surface.pill, content: rewrite(surface.pill.content) } }),
    sections: surface.sections.map((section) =>
      section.composite === "blocks" ? { ...section, body: rewrite(section.body) } : section,
    ),
  };
}

/** Does any tree or the pill hold an elapsed node? */
export function extensionUISurfaceUsesElapsed(surface: ExtensionUISurface): boolean {
  return surfaceHolds(surface, (node) => node.type === "elapsed");
}

/**
 * The surface for a client that draws trees but declared no `v2:elapsed`: every elapsed node is a
 * text node of its span at `now`. Such a build decodes a node kind it does not know as
 * "Unsupported block", so it is never sent one. Call only when `extensionUISurfaceUsesElapsed`.
 */
export function withStaticElapsed(surface: ExtensionUISurface, now: number): ExtensionUISurface {
  return rewriteNodes(surface, (node) =>
    node.type === "elapsed" ? elapsedAsText(node, now) : undefined,
  );
}

/** Does any tree or the pill hold an `icon` node that names the working mark? */
export function extensionUISurfaceUsesWorkingIcon(surface: ExtensionUISurface): boolean {
  return surfaceHolds(
    surface,
    (node) => node.type === "icon" && node.name === EXTENSION_UI_SURFACE_WORKING_ICON,
  );
}

/**
 * The surface for a client that draws trees but declared no `v2:working`: each working mark is the
 * symbol such a build can draw. It leaves an icon name it does not know as an empty gap. Call only
 * when `extensionUISurfaceUsesWorkingIcon`.
 */
export function withWorkingIconStandIn(surface: ExtensionUISurface): ExtensionUISurface {
  return rewriteNodes(surface, (node) =>
    node.type === "icon" && node.name === EXTENSION_UI_SURFACE_WORKING_ICON
      ? { ...node, name: EXTENSION_UI_SURFACE_WORKING_ICON_STAND_IN }
      : undefined,
  );
}

/** Does any tree hold a `tiles` node? A pill never does. */
export function extensionUISurfaceUsesTiles(surface: ExtensionUISurface): boolean {
  return surfaceHolds(surface, (node) => node.type === "tiles");
}

/**
 * The words a tile shows where it cannot be drawn: its title, else its target's own name (a
 * file's or folder's name, a page's host, a game's project id), as a tile without a title shows.
 */
export function tileTitle(tile: ExtensionUISurfaceTile): string {
  if (tile.title !== undefined) return tile.title;
  const decoded = decodePaneLink(tile.link);
  if (!decoded?.ok) return tile.link;
  const route = decoded.link.route;
  const last = (path: string): string => path.split("/").filter(Boolean).pop() ?? path;
  switch (route.kind) {
    case "file":
      return last(route.path);
    case "files":
      return route.path === null ? ("origin" in route ? "Home" : "Workspace") : last(route.path);
    case "session":
    case "thread":
      return "Session";
    case "sessions":
      return "Sessions";
    case "panel":
      return route.id;
    case "browser":
      return new URL(route.url).host;
    case "godot":
      return route.project;
    case "git":
    case "commit":
      return tile.link;
  }
}

/** Markdown's link text, with the characters that would end or break the link escaped. */
function markdownLinkText(text: string): string {
  // One line: a line break would end the list item, and the rest would be Markdown of its own.
  return text
    .replace(/\s*[\r\n\u2028\u2029]+\s*/g, " ")
    .replace(/[\\[\]*_`<>]/g, (character) => `\\${character}`);
}

/**
 * A link inside Markdown's `<…>`: a `<`, a `>`, or whitespace would end it, so each is
 * percent-encoded, which a pane link decodes back to the same value.
 */
function markdownLinkDestination(link: string): string {
  return link.replace(/[\s<>]/g, (character) => encodeURIComponent(character));
}

/**
 * The surface for a client that draws trees but declared no `v2:tiles`: each tiles node is a
 * Markdown list of its tiles as links, with the node's id. Such a build opens a Markdown link as a
 * chat link, and would draw a tiles node as "Unsupported block". Call only when
 * `extensionUISurfaceUsesTiles`.
 */
export function withTilesAsLinks(surface: ExtensionUISurface): ExtensionUISurface {
  return rewriteNodes(surface, (node) => {
    if (node.type !== "tiles") return undefined;
    const lines = node.items.map((tile) => {
      const subtitle = tile.subtitle === undefined ? "" : ` · ${markdownLinkText(tile.subtitle)}`;
      return `- [${markdownLinkText(tileTitle(tile))}](<${markdownLinkDestination(tile.link)}>)${subtitle}`;
    });
    return {
      type: "markdown",
      ...(node.id === undefined ? {} : { id: node.id }),
      ...(node.accessibility === undefined ? {} : { accessibility: node.accessibility }),
      markdown: lines.join("\n"),
    } as ExtensionUISurfaceNode;
  });
}

function isPillHeadline(
  node: ExtensionUISurfacePillNode,
): node is Extract<ExtensionUISurfacePillNode, { type: "text" | "elapsed" }> {
  return (node.type === "text" || node.type === "elapsed") && node.style === "headline";
}

/** Does the pill hold a `headline` text or elapsed node? */
export function extensionUISurfacePillUsesHeadline(surface: ExtensionUISurface): boolean {
  return surface.pill?.content.children.some(isPillHeadline) ?? false;
}

/**
 * The surface for a client that draws trees but declared no `v2:elapsed`: a pill's `headline` words
 * become `caption`. Those builds draw a pill's `headline` at a card title's size, which makes the
 * pill taller than the strip's others and pushes it off the strip's edge; every build that declares
 * `elapsed` draws it at the size of a strip pill's title. Call only when
 * `extensionUISurfacePillUsesHeadline`.
 */
export function withPillHeadlinesAsCaption(surface: ExtensionUISurface): ExtensionUISurface {
  const pill = surface.pill;
  if (pill === undefined) return surface;
  const children = pill.content.children.map((node): ExtensionUISurfacePillNode =>
    isPillHeadline(node) ? { ...node, style: "caption" } : node,
  );
  return { ...surface, pill: { ...pill, content: { ...pill.content, children } } };
}

/** Does the surface carry pane hints: a `panel` placement or `panel` icon and size? */
export function extensionUISurfaceUsesPanelHints(surface: ExtensionUISurface): boolean {
  return surface.panel !== undefined || surface.placement.kind === "panel";
}

/**
 * The surface for a client that predates panel panes: no `panel` hints, and a `panel` placement
 * sent as `strip`. Those builds draw only `strip` surfaces, so a `panel` one would vanish; as a
 * strip its pill opens the drawer and the drawer's full screen, as before. Call only when
 * `extensionUISurfaceUsesPanelHints`.
 */
export function withoutPanelHints(surface: ExtensionUISurface): ExtensionUISurface {
  const { panel: _panel, ...rest } = surface;
  return { ...rest, placement: { ...surface.placement, kind: "strip" } };
}

function elapsedAsText(
  node: ExtensionUISurfaceElapsedNode,
  now: number,
): ExtensionUISurfaceNode & ExtensionUISurfacePillNode {
  return {
    type: "text",
    ...(node.id === undefined ? {} : { id: node.id }),
    ...(node.accessibility === undefined ? {} : { accessibility: node.accessibility }),
    text: elapsedSnapshotText(node, now),
    ...(node.style === undefined ? {} : { style: node.style }),
    ...(node.tone === undefined ? {} : { tone: node.tone }),
  };
}

/** The line a v1 panel shows under its title: the pill's own words when the surface has one. */
export function v1PillSubtitle(surface: ExtensionUISurface): string | undefined {
  if (!surface.pill) return surface.header.subtitle;
  const parts = surface.pill.content.children.map((child): string | undefined => {
    switch (child.type) {
      case "text":
      case "badge":
        return child.text;
      case "icon":
        return undefined;
      case "elapsed":
        return elapsedSnapshotText(child);
      case "progress":
        return child.label;
      default:
        return undefined;
    }
  });
  const line = parts.filter((part): part is string => Boolean(part)).join(" · ");
  return line.length > 0 ? line : surface.header.subtitle;
}

export function v1TextBlock(id: string | undefined, line: string): unknown {
  return { type: "text", ...(id === undefined ? {} : { id }), spans: [{ text: line }] };
}

function v1SpanRole(tone: ExtensionUISurfaceTone | undefined): string | undefined {
  return tone === undefined || tone === "neutral" ? undefined : tone;
}

/** The primitives a row reads as a single line: everything else keeps its own block. */
const V1_INLINE_NODE_TYPES = new Set(["text", "badge", "icon", "elapsed"]);

function v1InlineText(node: ExtensionUISurfaceNode): string | undefined {
  switch (node.type) {
    case "text":
    case "badge":
      return node.text;
    case "icon":
      return node.name;
    case "elapsed":
      return elapsedSnapshotText(node);
    default:
      return undefined;
  }
}

/**
 * One node as v1 blocks, collecting the controls v1 has no shape for. Layout becomes a group or,
 * when every child is an inline fact, one line; controls are named in the caller's text.
 *
 * `actionTitle` names an action id for that text: the caller holds the surface's action table, and
 * a row action carries no title of its own.
 */
export function projectNodeToV1(
  node: ExtensionUISurfaceNode,
  controls: string[],
  actionTitle: (id: string) => string = (id) => id,
): unknown[] {
  const id = node.id;
  switch (node.type) {
    case "row":
    case "stack": {
      const inline = node.children.every((child) => V1_INLINE_NODE_TYPES.has(child.type));
      if (inline) {
        // An inline fact that offers a tap is still a verb v1 cannot draw, one line or not.
        for (const child of node.children) {
          if ("action" in child && child.action) controls.push(actionTitle(child.action.id));
        }
        const line = node.children
          .map((child) => v1InlineText(child))
          .filter((part): part is string => Boolean(part))
          .join(" · ");
        return line.length > 0 ? [v1TextBlock(id, line)] : [];
      }
      const projected = node.children.flatMap((child) =>
        projectNodeToV1(child, controls, actionTitle),
      );
      // A layout of nothing but controls draws nothing: an empty group is not content either.
      if (projected.length === 0) return [];
      return [
        {
          type: "section",
          ...(id === undefined ? {} : { id }),
          blocks: projected,
        },
      ];
    }
    case "group":
      // v1 has no disclosure: a group is its heading and its contents, always unfolded.
      return [
        {
          type: "section",
          ...(id === undefined ? {} : { id }),
          blocks: [
            v1TextBlock(undefined, node.title),
            ...node.children.flatMap((child) => projectNodeToV1(child, controls, actionTitle)),
          ],
        },
      ];
    case "text":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [
            {
              text: node.text,
              ...(node.style === "mono"
                ? { role: "code" }
                : v1SpanRole(node.tone) === undefined
                  ? {}
                  : { role: v1SpanRole(node.tone) }),
            },
          ],
        },
      ];
    case "markdown":
      return [{ type: "markdown", ...(id === undefined ? {} : { id }), markdown: node.markdown }];
    case "badge":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [
            {
              text: node.text,
              ...(v1SpanRole(node.tone) === undefined ? {} : { role: v1SpanRole(node.tone) }),
            },
          ],
        },
      ];
    case "icon":
      // v1 has no icon: its name is the only honest text it can show.
      return [v1TextBlock(id, node.name)];
    case "elapsed":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [
            {
              text: elapsedSnapshotText(node),
              ...(node.style === "mono"
                ? { role: "code" }
                : v1SpanRole(node.tone) === undefined
                  ? {}
                  : { role: v1SpanRole(node.tone) }),
            },
          ],
        },
      ];
    case "progress":
      return [
        {
          type: "progress",
          ...(id === undefined ? {} : { id }),
          ...(node.label === undefined ? {} : { label: node.label }),
          ...(node.value === undefined ? { indeterminate: true } : { value: node.value }),
        },
      ];
    case "keyValue":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [{ text: node.pairs.map((pair) => `${pair.key}: ${pair.value}`).join("\n") }],
        },
      ];
    case "table":
      // A row action is a verb v1 cannot draw either: its row's actions are named once each.
      for (const row of node.rows) {
        for (const action of row.actions ?? []) controls.push(actionTitle(action.id));
      }
      return [
        {
          type: "table",
          ...(id === undefined ? {} : { id }),
          columns: node.columns,
          rows: node.rows.map((row) => row.cells),
          ...(node.truncated === undefined ? {} : { truncated: node.truncated }),
        },
      ];
    case "chart":
      return [
        {
          type: "chart",
          ...(id === undefined ? {} : { id }),
          kind: node.kind,
          ...(node.title === undefined ? {} : { title: node.title }),
          labels: node.labels,
          series: node.series,
          ...(node.truncated === undefined ? {} : { truncated: node.truncated }),
        },
      ];
    case "code":
      return [
        {
          type: "code",
          ...(id === undefined ? {} : { id }),
          ...(node.language === undefined ? {} : { language: node.language }),
          text: node.text,
        },
      ];
    case "divider":
      return [{ type: "divider", ...(id === undefined ? {} : { id }) }];
    case "spacer":
      return [
        {
          type: "spacer",
          ...(id === undefined ? {} : { id }),
          ...(node.size === undefined ? {} : { size: node.size }),
        },
      ];
    case "button":
      controls.push(node.title);
      return [];
    case "toggle":
      controls.push(`${node.title} (${node.value ? "on" : "off"})`);
      return [];
    case "menu":
      controls.push(
        [node.title, node.items.map((item) => item.title).join(" / ")]
          .filter((part): part is string => Boolean(part))
          .join(": "),
      );
      return [];
    case "tiles":
      // v1 has no tile: each is a line of text that opens its link, as an activity row's does.
      return node.items.map((tile) => ({
        type: "text",
        id: tile.id,
        spans: [
          { text: tileTitle(tile), link: tile.link },
          ...(tile.subtitle === undefined ? [] : [{ text: ` · ${tile.subtitle}`, role: "muted" }]),
        ],
      }));
  }
}
