import { defineRegistry, defineState, local, method, str as param } from "@earendil-works/chord";
import type { Context } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord/json";
import type { Watchable } from "@earendil-works/chord/watch";
import { arr, bool, obj, opt, str, union, unknown } from "@earendil-works/pi-schema";
import { EXTENSION_UI_SURFACE_ICON_NAMES } from "./extension-surface-icons.js";
import { isServerFeature, type ServerFeatureSwitches } from "./server-features.js";
import type { ServerFeature } from "./types/config.js";
import type {
  ScreenNav,
  ScreenPage,
  ScreenRow,
  ScreenSidebarEntry,
  ScreenValue,
} from "./types/screens.js";

/**
 * Plugin screens, the author's side (`oppi/v1`): a built-in plugin contributes a sidebar entry to
 * `Sidebar` and serves its screen, a `local` Chord object per `{ scope, page }` whose `page`
 * member is an in-memory document holding one `ScreenPage`, and whose `act` runs the person's
 * taps. The document is a projection of the plugin's real source, never persisted.
 *
 * ```ts
 * const Screen = defineScreen("acme.things");
 * export default defineFacet((host, self) => {
 *   self.contribute(Extensions, defineExtension({ name: "acme.things" }));
 *   self.contribute(Sidebar, { id: "acme.things", title: "Things", icon: "list.bullet",
 *     order: 50, scopes: ["server"], screen: Screen });
 *   host.serve(Screen.contract, ({ page }, self) => {
 *     const doc = self.state(Screen.document);
 *     self.onLive((ctx) => self.tx(async (tx) => Object.assign(await tx.draft(doc), render(page)), ctx));
 *     return { page: doc, act: async (args, ctx) => ({ ok: true }) };
 *   });
 * });
 * ```
 *
 * The server (`screens-stream.ts`) validates and budgets every value the document takes
 * (`checkScreenPage`) before an app sees it, and sends what changed as Chord delta ops.
 * @public
 */

/** The vocabulary version this server draws to (`capabilities.screens.v`). */
export const SCREENS_VERSION = 1;

/** A page's budget: what `checkScreenPage` refuses, never repairs. */
export const SCREEN_PAGE_MAX_BYTES = 64 * 1024;
export const SCREEN_SECTION_MAX_ROWS = 200;
/** Page ids are paths of at most this many `/` segments: `list`, `server/<name>`. */
export const SCREEN_PAGE_MAX_DEPTH = 3;
const BAR_MAX_ITEMS = 2;

/** What `act` takes: the action, the row that asked, and the draft or the new value. */
export interface ScreenActArgs {
  action: string;
  row?: string;
  values?: ScreenValue[];
}

/** What `act` answers; a failure's `message` shows in the tapped row's section. */
export interface ScreenActResult {
  ok: boolean;
  message?: string;
  nav?: ScreenNav;
}

/** The action Retry sends on a failed page; every screen answers it by reading its source again. */
export const SCREEN_REFRESH_ACTION = "refresh";

const actArgs = obj({
  action: str(),
  row: opt(str()),
  values: opt(arr(obj({ field: str(), value: union([str(), bool()]) }))),
});

/** A page while its source has not answered yet: every screen document starts as this. */
export const LOADING_PAGE: ScreenPage = { title: "", state: { kind: "loading" }, sections: [] };

/**
 * A screen's members. Chord exports `method()` but not the class it returns, so `act`'s type is
 * named through the function: `oppi/v1`'s published declarations can then spell the contract.
 */
const screenMembers: {
  readonly page: ReturnType<typeof unknown>;
  readonly act: ReturnType<typeof method<typeof actArgs, ReturnType<typeof unknown>>>;
} = { page: unknown(), act: method(actArgs, unknown()) };

/** One screen type: its Chord contract (one object per `{ scope, page }`) and its page document. */
// eslint-disable-next-line @typescript-eslint/explicit-function-return-type -- Chord infers the contract's type from its declaration.
export function defineScreen(id: string) {
  const contract = local(`oppi.screen/${id}`, {
    version: 1,
    params: { scope: param(), page: param() },
    members: screenMembers,
  });
  const document = defineState(`oppi.screen/${id}.page`, {
    schema: obj({}, { open: true }),
    version: 1,
    initial: () => ({ ...LOADING_PAGE }) as unknown as Record<string, never>,
  });
  return { id, contract, document };
}

export type ScreenDefinition = ReturnType<typeof defineScreen>;

/**
 * A sidebar entry as a plugin contributes it: what `/server/info` lists, its screen, and the
 * feature switch that hides it while off (`server-features.ts`).
 */
export interface SidebarContribution extends ScreenSidebarEntry {
  readonly screen: ScreenDefinition;
  readonly feature?: ServerFeature;
}

/** Oppi's registry of sidebar entries; only built-in plugins' contributions are listed. */
export const Sidebar = defineRegistry<SidebarContribution, readonly SidebarContribution[]>(
  "oppi.sidebar",
  { version: 1 },
);

/** A screen object the server holds for one watch. */
export interface ScreenReference {
  readonly page: Watchable<JsonValue>;
  act(args: ScreenActArgs, context: Context): Promise<unknown>;
  release(): void;
}

/** The plugin host's side the stream reads: the composed entries, and a screen object by params. */
export interface ScreenHost {
  entries(): readonly SidebarContribution[];
  open(
    entry: SidebarContribution,
    params: { scope: string; page: string },
    context: Context,
  ): Promise<ScreenReference>;
}

/**
 * The loaded plugins' screens: the plugin host sets it after each first load. One process-wide
 * slot like the Godot one, outside `oppi/v1`.
 */
let loaded: ScreenHost | undefined;

export function serveScreens(screens: ScreenHost | undefined): void {
  loaded = screens;
}

export function loadedScreens(): ScreenHost | undefined {
  return loaded;
}

/** The entry as `/server/info` lists it. */
export function sidebarEntryInfo(entry: SidebarContribution): ScreenSidebarEntry {
  return {
    id: entry.id,
    title: entry.title,
    icon: entry.icon,
    order: entry.order,
    scopes: [...entry.scopes],
  };
}

/** Whether `entry` is offered: its feature, when it names one, is on. */
export function sidebarEntryOn(
  entry: Pick<SidebarContribution, "feature">,
  features: Readonly<ServerFeatureSwitches>,
): boolean {
  return entry.feature === undefined || features[entry.feature];
}

/** Why a sidebar contribution cannot be listed, or undefined. Checked when the host composes. */
export function sidebarProblem(value: unknown): string | undefined {
  if (!isObject(value)) return "not an object";
  if (!isId(value.id)) return "its id must be a lowercase dotted name";
  if (!isText(value.title)) return "it has no title";
  if (!isIcon(value.icon)) return `icon ${JSON.stringify(value.icon)} is not an allowed symbol`;
  if (typeof value.order !== "number") return "its order is not a number";
  if (value.feature !== undefined && !isServerFeature(value.feature))
    return `its feature ${JSON.stringify(value.feature)} is not a feature switch`;
  if (
    !Array.isArray(value.scopes) ||
    value.scopes.length === 0 ||
    value.scopes.some((scope) => scope !== "server" && scope !== "workspace")
  )
    return "its scopes must be server and/or workspace";
  const screen = value.screen as Partial<ScreenDefinition> | undefined;
  if (!screen?.contract || !screen.document) return "its screen is not a defineScreen() value";
  return undefined;
}

/** A page id the stream accepts: a path of at most `SCREEN_PAGE_MAX_DEPTH` non-empty segments. */
export function screenPageIdProblem(page: string): string | undefined {
  const segments = page.split("/");
  if (segments.length > SCREEN_PAGE_MAX_DEPTH) return "the page is too deep";
  if (segments.some((segment) => segment.length === 0 || segment.length > 128))
    return "the page id has an empty or long segment";
  return undefined;
}

/**
 * Why `value` is not a page the app can draw, or undefined. Checks the vocabulary (seven row
 * kinds, their fields, ids unique in the page) and the budget; the page is refused whole.
 */
export function checkScreenPage(value: unknown): string | undefined {
  if (!isObject(value)) return "the page is not an object";
  const bytes = Buffer.byteLength(JSON.stringify(value));
  if (bytes > SCREEN_PAGE_MAX_BYTES)
    return `the page is ${bytes} bytes; the budget is ${SCREEN_PAGE_MAX_BYTES}`;
  if (typeof value.title !== "string") return "the page has no title";
  if (value.state !== undefined) {
    const state = value.state as Record<string, unknown>;
    if (!isObject(state) || !["loading", "empty", "failed"].includes(state.kind as string))
      return "the page state is not loading, empty or failed";
  }
  // Ids are unique per kind in the page: the app keys its list and its identifiers by them.
  const ids = new Map<string, Set<string>>();
  const unique = (id: unknown, what: string): string | undefined => {
    if (!isText(id)) return `a ${what} has no id`;
    const seen = ids.get(what) ?? new Set<string>();
    ids.set(what, seen);
    if (seen.has(id)) return `${what} id ${JSON.stringify(id)} is used twice`;
    seen.add(id);
    return undefined;
  };
  if (value.bar !== undefined) {
    if (!Array.isArray(value.bar) || value.bar.length > BAR_MAX_ITEMS)
      return `the bar holds at most ${BAR_MAX_ITEMS} items`;
    for (const item of value.bar) {
      if (!isObject(item) || !isText(item.title)) return "a bar item has no title";
      if (item.symbol !== undefined && !isIcon(item.symbol))
        return `bar symbol ${JSON.stringify(item.symbol)} is not allowed`;
      if (
        [item.action, item.push, item.present].filter((target) => target !== undefined).length !== 1
      )
        return "a bar item needs one of action, push or present";
      const problem = unique(item.id, "bar item");
      if (problem) return problem;
    }
  }
  if (value.submit !== undefined) {
    const submit = value.submit as Record<string, unknown>;
    if (!isObject(submit) || !isText(submit.title) || !isText(submit.action))
      return "submit needs a title and an action";
  }
  if (!Array.isArray(value.sections)) return "the page has no sections";
  for (const section of value.sections) {
    if (!isObject(section)) return "a section is not an object";
    const problem = unique(section.id, "section");
    if (problem) return problem;
    if (!Array.isArray(section.rows)) return `section ${section.id as string} has no rows`;
    if (section.rows.length > SCREEN_SECTION_MAX_ROWS)
      return `section ${section.id as string} has ${section.rows.length} rows; the budget is ${SCREEN_SECTION_MAX_ROWS}`;
    if (section.when !== undefined) {
      const when = section.when as Record<string, unknown>;
      if (!isObject(when) || !isText(when.field) || typeof when.is !== "string")
        return "a section's when needs a field and a value";
    }
    for (const row of section.rows) {
      const rowProblem = checkRow(row) ?? unique((row as { id?: unknown }).id, "row");
      if (rowProblem) return rowProblem;
    }
  }
  return undefined;
}

function checkRow(row: unknown): string | undefined {
  if (!isObject(row)) return "a row is not an object";
  const kind = row.kind as ScreenRow["kind"];
  const need = (field: string, test: (value: unknown) => boolean): string | undefined =>
    test(row[field]) ? undefined : `a ${kind} row's ${field} is missing or wrong`;
  const optional = (field: string, test: (value: unknown) => boolean): string | undefined =>
    row[field] === undefined || test(row[field]) ? undefined : `a ${kind} row's ${field} is wrong`;
  switch (kind) {
    case "item":
      return (
        need("title", isText) ??
        optional("subtitle", isString) ??
        optional("push", isText) ??
        optional("url", isUrl) ??
        optional(
          "status",
          (status) =>
            isObject(status) &&
            isText(status.text) &&
            (status.symbol === undefined || isIcon(status.symbol)) &&
            (status.tone === undefined || isTone(status.tone)),
        )
      );
    case "value":
      return need("label", isText) ?? need("value", isString) ?? optional("mono", isBool);
    case "text":
      return (
        need("text", isString) ??
        optional("style", (style) => style === "body" || style === "footnote") ??
        optional("mono", isBool) ??
        optional("tone", isTone) ??
        optional("selectable", isBool)
      );
    case "toggle":
      return (
        need("label", isText) ??
        need("value", isBool) ??
        optional("action", isText) ??
        optional("disabled", isBool)
      );
    case "choice":
      return (
        need("label", isText) ??
        need("value", isString) ??
        need(
          "options",
          (options) =>
            Array.isArray(options) &&
            options.length > 0 &&
            options.every(
              (option) => isObject(option) && isString(option.value) && isText(option.title),
            ),
        ) ??
        optional("action", isText) ??
        optional("disabled", isBool)
      );
    case "button":
      return (
        need("title", isText) ??
        optional("role", (role) => role === "destructive") ??
        optional("action", isText) ??
        optional("url", isUrl) ??
        optional("disabled", isBool) ??
        optional(
          "confirm",
          (confirm) => isObject(confirm) && isText(confirm.title) && isText(confirm.button),
        ) ??
        (row.action === undefined && row.url === undefined
          ? "a button needs an action or a url"
          : undefined)
      );
    case "field":
      return (
        optional("label", isString) ??
        optional("placeholder", isString) ??
        optional("value", isString) ??
        optional("input", (input) =>
          ["text", "secret", "number", "url", "multiline"].includes(input as string),
        )
      );
    default:
      return `row kind ${JSON.stringify(kind)} is not one of the seven`;
  }
}

const TONES = new Set(["secondary", "accent", "success", "warning", "danger"]);
const ICONS = new Set<string>(EXTENSION_UI_SURFACE_ICON_NAMES);
const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isString = (value: unknown): value is string => typeof value === "string";
const isText = (value: unknown): value is string => typeof value === "string" && value.length > 0;
const isBool = (value: unknown): value is boolean => typeof value === "boolean";
const isTone = (value: unknown): boolean => TONES.has(value as string);
const isIcon = (value: unknown): boolean => ICONS.has(value as string);
const isId = (value: unknown): boolean =>
  typeof value === "string" && /^[a-z][a-z0-9._-]*$/.test(value);
const isUrl = (value: unknown): boolean => {
  if (typeof value !== "string") return false;
  try {
    return ["https:", "http:"].includes(new URL(value).protocol);
  } catch {
    return false;
  }
};
