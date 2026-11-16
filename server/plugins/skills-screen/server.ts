import { sleep } from "@earendil-works/chord";
import type { Context } from "@earendil-works/chord/context";
import {
  defineFacet,
  defineScreen,
  oppiHost,
  Sidebar,
  SCREEN_REFRESH_ACTION,
  type OppiSkillsHost,
  type ScreenActArgs,
  type ScreenActResult,
} from "oppi/v1";
import type { ScreenPage } from "../../src/types/screens.js";
import {
  filesPage,
  listPage,
  skillPage,
  SKILLS_SCREEN_ID,
  SKILLS_SIDEBAR_ENTRY,
  type SkillsRead,
} from "./pages.js";

/**
 * Skills as a plugin sidebar entry: the server's catalog, each Skill's page with its server
 * default, and its files as folder pages, drawn by the app's generic list screen. A file row
 * opens the app's own file viewer, which edits a Skill's file as the server allows. Each page is
 * a Chord object whose document is a projection of `oppiHost().skills()`: read when the page
 * opens and after a change any page of this screen made.
 */
const Screen = defineScreen(SKILLS_SCREEN_ID);

/** How often a page checks for a change another page made. */
const POLL_MS = 1000;

/** Counts the changes made through any page of this screen, so the other open pages read again. */
let changes = 0;

const message = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

function skills(): OppiSkillsHost {
  const host = oppiHost().skills();
  if (!host) throw new Error("Skills are not available on this server.");
  return host;
}

/** `skill/<id>`, `files/<id>`, `files/<id>/<folder>` (the folder URI-encoded as one segment). */
function parse(page: string): {
  kind: "list" | "skill" | "files" | "gone";
  id: string;
  folder: string;
} {
  const [kind, id = "", folder] = page.split("/");
  if (page === "list") return { kind: "list", id: "", folder: "" };
  if (kind === "skill" && id && folder === undefined) return { kind: "skill", id, folder: "" };
  if (kind === "files" && id) {
    try {
      return { kind: "files", id, folder: folder === undefined ? "" : decodeURIComponent(folder) };
    } catch {
      return { kind: "gone", id: "", folder: "" };
    }
  }
  return { kind: "gone", id: "", folder: "" };
}

export default defineFacet((host, self) => {
  self.contribute(Sidebar, { ...SKILLS_SIDEBAR_ENTRY, screen: Screen });

  host.serve(Screen.contract, ({ page }, self) => {
    const doc = self.state(Screen.document);
    const target = parse(page);

    const put = (value: ScreenPage | { gone: true }, context: Context): Promise<void> =>
      doc.change((draft) => {
        for (const key of Object.keys(draft)) delete (draft as Record<string, unknown>)[key];
        Object.assign(draft, value);
      }, context);

    let seenChanges = changes;
    const read = async (context: Context): Promise<void> => {
      seenChanges = changes;
      if (target.kind === "gone") return put({ gone: true }, context);
      if (target.kind === "list") {
        let catalog: SkillsRead<{
          skills: Awaited<ReturnType<OppiSkillsHost["listSkills"]>>["skills"];
        }>;
        try {
          catalog = { value: await skills().listSkills() };
        } catch (error) {
          catalog = { error: message(error) };
        }
        return put(listPage(catalog), context);
      }
      let detail: SkillsRead<Awaited<ReturnType<OppiSkillsHost["getSkillDetail"]>>>;
      try {
        detail = { value: await skills().getSkillDetail(target.id) };
      } catch (error) {
        // A Skill that is no longer in the catalog closes its pages.
        if (error instanceof Error && /not found/i.test(error.message))
          return put({ gone: true }, context);
        detail = { error: message(error) };
      }
      return put(
        target.kind === "skill"
          ? skillPage(detail, target.id)
          : filesPage(detail, target.id, target.folder),
        context,
      );
    };

    self.onLive(async (context) => {
      await read(context);
      while (!context.abortSignal?.aborted) {
        await sleep(POLL_MS, context);
        if (seenChanges !== changes) await read(context);
      }
    });

    const act = async (args: ScreenActArgs, context: Context): Promise<ScreenActResult> => {
      try {
        switch (args.action) {
          case SCREEN_REFRESH_ACTION:
            await read(context);
            return { ok: true };
          case "enabled": {
            const value = args.values?.find((item) => item.field === args.row)?.value;
            if (target.kind !== "skill" || typeof value !== "boolean")
              return { ok: false, message: "This page has no switch." };
            await skills().setSkillEnabled(target.id, value);
            changes += 1;
            await read(context);
            return { ok: true };
          }
          default:
            return { ok: false, message: `Unknown action ${args.action}` };
        }
      } catch (error) {
        return { ok: false, message: message(error) };
      }
    };

    return { page: doc, act };
  });
});
