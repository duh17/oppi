import type { JsonValue } from "@earendil-works/chord";
import { answerRecord, decodePathSegment, type ControlWrite } from "oppi/durable";

/**
 * The owner's confirm card for one write, in plain words. It is computed only from the request
 * the server is about to send and the records it read (`ControlWrite`), never from anything the
 * model said. Layout of `message`: a one-line summary, the fields one by one, plain warnings, and
 * last a "Details" line with the method and path.
 *
 * Two rules keep the card honest. Text that comes from the request, a record, or an error
 * reaches `message` only inside `code()` or `fenced()`, where Markdown is inert; a title shows it
 * as plain text through `flat()`. The only live Markdown is the server's own words: bold labels,
 * warning sentences, and "Details:". And the card never hides what it sends: a character the
 * owner cannot see (`HIDDEN`) is shown in a value as `⟨N hidden characters⟩`, and a warning
 * counts them. Only a title, which is a short name, drops them silently.
 */
export interface WriteCard {
  title: string;
  /** Markdown; its first line reads fine unrendered. */
  message: string;
  /** Label of the button that sends the write. */
  confirm: string;
}

type Obj = { [key: string]: JsonValue };
const record = (value: JsonValue | undefined): Obj | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Obj) : undefined;

// ---------------------------------------------------------------------------------------------
// Which write is this: title, button, and what it does, by method and path
// ---------------------------------------------------------------------------------------------

interface Route {
  title: (name: string | undefined) => string;
  /** The button that sends it. */
  confirm: string;
  /** The summary line of a write that carries no fields. */
  does: string;
  /** An update: the card shows what differs from the current record. */
  change?: true;
  /** The id whose name the title shows. */
  target?: { noun: string; id: string };
  /** Field shown in a text block, however short: the message or prompt the write sends. */
  quote?: string;
  /** Fields left out because the card's words already say it. */
  hide?: string[];
}

/** Request mechanics the host sets or the user never chooses; not shown as fields. */
const MECHANICS = new Set(["idempotencyKey", "requestId", "clientTurnId"]);

/** A title of the item's own wording around its name; `item` is the usual "Verb Noun “name”?". */
function phrase(
  before: string,
  noun: string,
  id: string | undefined,
  confirm: string,
  does: string,
  extra: Partial<Route> = {},
): Route {
  return {
    title: (name) => {
      const shown = name ?? id;
      return `${before}${shown ? ` “${flat(shown, NAME_LENGTH)}”` : ""}?`;
    },
    confirm,
    does,
    ...(id ? { target: { noun, id } } : {}),
    ...extra,
  };
}

const item = (
  verb: string,
  noun: string,
  id: string | undefined,
  does: string,
  extra: Partial<Route> = {},
): Route => phrase(`${verb} ${noun}`, noun, id, `${verb} ${noun}`, does, extra);

const CHANGE = "Apply Change";

/** A lookup that ignores `Object.prototype`, so a key named "constructor" finds nothing. */
const own = <T>(table: { [key: string]: T }, key: string): T | undefined =>
  Object.hasOwn(table, key) ? table[key] : undefined;

const words = (segment: string): string =>
  segment
    .split("-")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");

function routeOf(method: string, path: string, body: Obj | undefined): Route {
  let segments = (path.split("?", 1)[0] ?? "").split("/").filter(Boolean).map(decodePathSegment);
  // A workspace's session is the session.
  if (segments[0] === "workspaces" && segments[2] === "sessions" && segments[3])
    segments = segments.slice(2);
  const [collection, id, sub, sub2] = segments;
  const shape = `${collection ?? ""}${id ? "/:id" : ""}${sub ? `/${sub}` : ""}`;

  switch (`${method} ${shape}`) {
    case "POST agents":
      return item("Create", "Agent", undefined, "Creates an Agent.", {
        title: () => `Create Agent${nameOf(body)}?`,
      });
    case "PATCH agents/:id":
      return item("Change", "Agent", id, "Changes the Agent.", { change: true, confirm: CHANGE });
    case "DELETE agents/:id":
      return item("Archive", "Agent", id, "Archives the Agent.");
    case "POST agents/:id/sessions":
      return phrase(
        "Start a session with Agent",
        "Agent",
        id,
        "Start Session",
        "Starts a session with the Agent.",
        { quote: "prompt.text" },
      );
    case "POST schedules":
      return item("Create", "Schedule", undefined, "Creates a Schedule.", {
        title: () => `Create Schedule${nameOf(body)}?`,
      });
    case "PATCH schedules/:id":
      return item("Change", "Schedule", id, "Changes the Schedule.", {
        change: true,
        confirm: CHANGE,
      });
    case "POST schedules/:id/run":
      return item("Run", "Schedule", id, "Runs the Schedule now.");
    case "POST schedules/:id/pause":
      return item("Pause", "Schedule", id, "Pauses the Schedule.");
    case "POST schedules/:id/resume":
      return item("Resume", "Schedule", id, "Resumes the Schedule.");
    case "POST schedules/:id/archive":
      return item("Archive", "Schedule", id, "Archives the Schedule.");
    case "POST schedules/:id/restore":
      return item("Restore", "Schedule", id, "Restores the Schedule.");
    case "POST workspaces":
      return item("Create", "Workspace", undefined, "Creates a Workspace.", {
        title: () => `Create Workspace${nameOf(body)}?`,
      });
    case "PUT workspaces/:id":
      return item("Change", "Workspace", id, "Changes the Workspace.", {
        change: true,
        confirm: CHANGE,
      });
    case "DELETE workspaces/:id":
      return item("Delete", "Workspace", id, "Deletes the Workspace.");
    case "POST workspaces/:id/sessions":
      return phrase(
        "Start a session in",
        "Workspace",
        id,
        "Start Session",
        "Starts a session in the Workspace.",
        { quote: "prompt" },
      );
    case "POST workspaces/:id/worktrees":
      // `worktrees/open` and `worktrees/:id/preview` are handled below.
      if (sub2) break;
      return phrase(
        "Create a worktree in",
        "Workspace",
        id,
        "Create Worktree",
        "Creates a worktree.",
      );
    case "POST sessions/:id/command": {
      const type = body?.type;
      if (type === "prompt")
        return phrase(
          "Send a message to",
          "Session",
          id,
          "Send Message",
          "Sends a message to the session.",
          { quote: "message", hide: ["type"] },
        );
      if (type === "abort")
        return phrase(
          "Stop the current turn of",
          "Session",
          id,
          "Stop Turn",
          "Stops the session's current turn.",
          { hide: ["type"] },
        );
      return phrase(
        "Send a command to",
        "Session",
        id,
        "Send Command",
        "Sends a command to the session.",
      );
    }
    case "POST sessions/:id/stop":
      return item("Stop", "Session", id, "Stops the session.");
    case "POST sessions/:id/resume":
      return item("Resume", "Session", id, "Resumes the session.");
    case "POST sessions/:id/fork":
      return item("Fork", "Session", id, "Starts a new session from this one.");
    case "DELETE sessions/:id":
      return item("Delete", "Session", id, "Deletes the session.");
    default:
      break;
  }
  if (collection === "workspaces" && id && sub === "worktrees") {
    if (method === "POST" && sub2 === "open")
      return phrase("Open a worktree in", "Workspace", id, "Open Worktree", "Opens a worktree.");
    if (method === "POST" && segments[4] === "preview")
      return phrase(
        "Preview merging a worktree in",
        "Workspace",
        id,
        "Preview Merge",
        "Previews a merge.",
      );
    if (method === "DELETE")
      return phrase(
        "Remove a worktree from",
        "Workspace",
        id,
        "Remove Worktree",
        "Removes the worktree.",
      );
  }
  if (collection === "durable" && id === "extensions") {
    if (method === "PUT" && sub2 === "enabled" && sub) {
      const verb = body?.enabled === false ? "Disable" : "Enable";
      // An Extension is named by its id: there is no record to look up.
      const { target: _named, ...route } = item(verb, "Extension", sub, `${verb}s the Extension.`, {
        hide: ["enabled"],
      });
      return route;
    }
    if (method === "POST" && sub === "reload")
      return {
        title: () => "Reload Extensions?",
        confirm: "Reload Extensions",
        does: "Reloads the Extensions.",
      };
  }
  if (collection === "dictation" && id === "dictionary") {
    const scope = sub === "workspaces" ? "a Workspace's" : "the";
    if (method === "POST")
      return {
        title: () => `Add to ${scope} dictation dictionary?`,
        confirm: "Add Phrases",
        does: "Adds phrases to the dictionary.",
      };
    if (method === "DELETE")
      return body?.phrase !== undefined
        ? {
            title: () => `Remove a phrase from ${scope} dictation dictionary?`,
            confirm: "Remove Phrase",
            does: "Removes a phrase.",
          }
        : {
            title: () => `Clear ${scope} dictation dictionary?`,
            confirm: "Clear Dictionary",
            does: "Clears the dictionary.",
          };
  }
  // Any other path: the request's own nouns. Ids and other mixed segments are left out.
  const nouns = segments.filter((segment) => /^[a-z][a-z-]*$/.test(segment)).map(words);
  const subject = nouns.length > 0 ? nouns.join(" ") : "Oppi";
  return method === "DELETE"
    ? {
        title: () => `Delete ${subject}?`,
        confirm: "Delete",
        does: `Deletes ${subject}.`,
      }
    : {
        title: () => `Change ${subject}?`,
        confirm: CHANGE,
        does: `Sends a change to ${subject}.`,
        ...(method === "PATCH" || method === "PUT" ? { change: true as const } : {}),
      };
}

function nameOf(body: Obj | undefined): string {
  return typeof body?.name === "string" && body.name !== ""
    ? ` “${flat(body.name, NAME_LENGTH)}”`
    : "";
}

// ---------------------------------------------------------------------------------------------
// Fields: label, value, and what changed
// ---------------------------------------------------------------------------------------------

interface Field {
  path: string;
  /** `undefined`: the record has no such field, or its current value is not known. */
  before?: JsonValue;
  after?: JsonValue;
  /** The patch removes the field. */
  removed?: boolean;
}

const LABELS: { [path: string]: string } = {
  name: "Name",
  description: "Description",
  instructions: "Instructions",
  "instructions.text": "Instructions",
  "instructions.mode": "Instructions mode",
  model: "Model",
  thinking: "Thinking",
  thinkingLevel: "Thinking",
  prompt: "Prompt",
  "prompt.text": "Prompt",
  message: "Message",
  trigger: "When",
  "trigger.type": "Trigger type",
  "trigger.expression": "Cron schedule",
  "trigger.intervalMs": "Repeats every",
  "trigger.at": "Runs at",
  "trigger.timeZone": "Time zone",
  "action.type": "Action",
  "action.name": "Session name",
  icon: "Icon",
  tools: "Tools",
  "sandboxConfig.allowedHosts": "Allowed hosts",
  "sandboxConfig.mcpServers": "MCP servers",
  workspaceId: "Workspace",
  agentId: "Agent",
  sessionId: "Session",
  worktreeId: "Worktree",
  sessionName: "Session name",
  enabled: "Enabled",
  streamingBehavior: "Delivery",
};

/** Words for coded values. */
const VALUE_WORDS: { [value: string]: string } = {
  new_session: "Start a new session",
  existing_session: "Message an existing session",
  steer: "Interrupts the current turn (steer)",
  followUp: "Waits for the current turn to finish (follow-up)",
};

const WRAPPERS = /^(action|sessionDefaults|target|overrides)\./;

/** A label for a key the table lacks: only letters, digits, spaces and `›`, so it is never Markdown. */
function humanize(path: string): string {
  const text = path
    .split(".")
    .map((part) => part.replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase())
    .join(" › ")
    .replace(/[^A-Za-z0-9 ›]+/g, " ")
    .replace(/ {2,}/g, " ")
    .trim();
  return text === "" ? "Field" : text.charAt(0).toUpperCase() + text.slice(1);
}

/** The label of a field's path; `made` when no table row names it, so the label is only a reading of the key. */
function labelOf(path: string): { text: string; made: boolean } {
  const known = own(LABELS, path) ?? own(LABELS, path.replace(WRAPPERS, ""));
  return known === undefined
    ? { text: humanize(path.replace(WRAPPERS, "")), made: true }
    : { text: known, made: false };
}

function instant(ms: number): string {
  return `${new Date(ms).toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

function interval(ms: number): string {
  for (const [unit, size] of [
    ["day", 86_400_000],
    ["hour", 3_600_000],
    ["minute", 60_000],
    ["second", 1000],
  ] as const) {
    if (ms >= size && ms % size === 0) {
      const count = ms / size;
      return `${count} ${unit}${count === 1 ? "" : "s"}`;
    }
  }
  return `${ms} ms`;
}

/** A schedule trigger in words. */
function triggerText(trigger: Obj): string {
  const zone = typeof trigger.timeZone === "string" ? ` (${trigger.timeZone})` : "";
  if (trigger.type === "at" && typeof trigger.at === "number")
    return `once at ${instant(trigger.at)}${zone}`;
  if (trigger.type === "every" && typeof trigger.intervalMs === "number")
    return `every ${interval(trigger.intervalMs)}${zone}`;
  if (trigger.type === "cron" && typeof trigger.expression === "string")
    return `cron ${trigger.expression}${zone}`;
  return JSON.stringify(trigger);
}

const ALLOWED_HOSTS = "sandboxConfig.allowedHosts";

/** Lists that lift a limit when empty or missing, instead of setting one: what each means then. */
const LIFTS: { [path: string]: { empty: string; gone: string; sentence: string } } = {
  [ALLOWED_HOSTS]: {
    empty: "no host allowed",
    gone: "every host allowed",
    sentence: "Without an allowed hosts list, every host is allowed.",
  },
  tools: {
    empty: "every tool allowed",
    gone: "every tool allowed",
    sentence: "Without a tools list, every tool is allowed.",
  },
};

/** What a removed field lifts: a removed allowed hosts list, or a removed config that held one. */
const liftedBy = (field: Field): (typeof LIFTS)[string] | undefined =>
  field.removed !== true
    ? undefined
    : (own(LIFTS, field.path) ??
      (field.path === "sandboxConfig" && Array.isArray(record(field.before)?.allowedHosts)
        ? LIFTS[ALLOWED_HOSTS]
        : undefined));

/** Fields that hold the id of a record the host may have looked up. */
const ID_KEYS = new Set(["workspaceId", "agentId", "sessionId"]);
/** Fields whose value is a code with words of its own. */
const CODED_KEYS = new Set(["type", "streamingBehavior"]);

/** A field's value as the card writes it: an id with the name the host found for it, a code in words. Still raw: a sink makes it visible. */
function show(path: string, value: JsonValue, names: { [id: string]: string }): string {
  const key = path.slice(path.lastIndexOf(".") + 1);
  if (typeof value === "string") {
    const name = ID_KEYS.has(key) ? own(names, value) : undefined;
    if (name !== undefined && name !== value) return `${name} (${value})`;
    return (CODED_KEYS.has(key) ? own(VALUE_WORDS, value) : undefined) ?? value;
  }
  if (typeof value === "number") {
    if (path === "trigger.at") return instant(value);
    if (path === "trigger.intervalMs") return interval(value);
  }
  const trigger = path === "trigger" ? record(value) : undefined;
  return trigger ? triggerText(trigger) : JSON.stringify(value);
}

/** A value goes in a block when its visible text, hidden-character markers included, is more than a short line. */
const isLong = (text: string): boolean => {
  const shown = visible(text);
  return shown.includes("\n") || [...shown].length > LINE_LENGTH;
};

const LINE_LENGTH = 80;

/** The characters of a text, as many as it sends. */
const countOf = (text: string): number => [...text].length;

/** Every leaf of a body. A schedule's trigger is one value; arrays are values. */
function leaves(
  value: JsonValue,
  path: string,
  hidden: ReadonlySet<string>,
  out: Field[],
): Field[] {
  const fields = record(value);
  if (fields && !(path === "trigger" && typeof fields.type === "string")) {
    for (const [key, inner] of Object.entries(fields)) {
      const next = path ? `${path}.${key}` : key;
      if (!hidden.has(next)) leaves(inner, next, hidden, out);
    }
  } else out.push({ path, after: value });
  return out;
}

/** A field the server replaces as one value: a schedule's trigger. */
const WHOLE_VALUE = new Set(["trigger"]);
/** Objects it replaces whole (an Agent's instructions and icon, a Workspace's sandbox config): the card shows them leaf by leaf, with what the new value drops. */
const WHOLE_OBJECT = new Set(["instructions", "icon", "sandboxConfig"]);

/** The non-null leaves of a value, by dotted path. */
function flatten(
  value: JsonValue | undefined,
  path: string,
  out: Map<string, JsonValue>,
): Map<string, JsonValue> {
  const fields = record(value);
  if (fields)
    for (const [key, inner] of Object.entries(fields)) flatten(inner, `${path}.${key}`, out);
  else if (value !== undefined && value !== null) out.set(path, value);
  return out;
}

/** A value the server replaces whole: each leaf of the old and new one, so a dropped leaf shows. */
function replaced(
  path: string,
  before: JsonValue | undefined,
  after: JsonValue,
  out: Field[],
): void {
  const was = flatten(before, path, new Map());
  const now = flatten(after, path, new Map());
  for (const key of new Set([...was.keys(), ...now.keys()])) {
    const old = was.get(key);
    const next = now.get(key);
    if (next === undefined) out.push({ path: key, before: old, removed: true });
    else if (JSON.stringify(next) !== JSON.stringify(old))
      out.push({ path: key, before: old, after: next });
  }
}

/**
 * What an update changes against the record it updates, the way the server applies it
 * (`updateSchedule`, `mergeScheduleActionPatch`, `mergeAgentDefinition`): objects merge, except
 * the values above and a schedule action whose type changes, which are replaced. `null` removes.
 */
function changes(body: Obj, current: JsonValue, hidden: ReadonlySet<string>): Field[] {
  // `GET /agents/:id` wraps the record, and an Agent's patch is of its `definition`.
  const base = answerRecord(current);
  const inner = record(base?.definition);
  const out: Field[] = [];
  const walk = (patch: JsonValue, before: JsonValue | undefined, path: string): void => {
    if (hidden.has(path)) return;
    const fields = record(patch);
    const was = record(before);
    if (fields && WHOLE_OBJECT.has(path)) return replaced(path, before, patch, out);
    if (fields && path === "action" && fields.type !== undefined && fields.type !== was?.type)
      return replaced(path, before, patch, out);
    if (fields && !WHOLE_VALUE.has(path)) {
      for (const [key, value] of Object.entries(fields))
        walk(value, was ? own(was, key) : undefined, path ? `${path}.${key}` : key);
      return;
    }
    if (patch === null) {
      if (before !== undefined) out.push({ path, before, removed: true });
    } else if (JSON.stringify(patch) !== JSON.stringify(before))
      out.push({ path, before, after: patch });
  };
  for (const [key, value] of Object.entries(body))
    walk(
      value,
      base && Object.hasOwn(base, key) ? base[key] : inner ? own(inner, key) : undefined,
      key,
    );
  return out;
}

// ---------------------------------------------------------------------------------------------
// Markdown pieces
// ---------------------------------------------------------------------------------------------

/**
 * The ways a text can send what the owner cannot see: control and format characters, every
 * default-ignorable character (zero-width, bidi controls, variation selectors, fillers, tag
 * characters and the rest of U+E0000–E0FFF, which no screen draws), and lone surrogates. A line
 * ending, and a tab, are seen. So is the part of an emoji that joins or styles it
 * (`partOfGlyph`).
 */
const HIDDEN = /(?:(?![\n\t])\p{Cc}|\p{Cf}|\p{Default_Ignorable_Code_Point}|\p{Cs})+/gu;

/**
 * Every line ending the client's parsers know (\r, \r\n, \v, \f, U+0085, U+2028, U+2029) becomes
 * \n, so a split on \n is the split cmark, TextKit and `String.newlines` all agree on.
 */
const lineEnds = (text: string): string => text.replace(/\r\n?|[\v\f\u0085\u2028\u2029]/g, "\n");

const KEYCAP_BASE = /^[0-9#*]$/;
const PICTOGRAPH = /^\p{Extended_Pictographic}$/u;
const GLYPH_BASE = /^[\p{Extended_Pictographic}\p{Emoji_Modifier}]$/u;

/**
 * Whether a run of hidden characters, in `text` at `offset`, is the one piece of an emoji that
 * the glyph draws: a single text or emoji selector (U+FE0E, U+FE0F) right after a pictograph
 * (❤️, ©️), or after a keycap base when the enclosing keycap U+20E3 follows (1️⃣, #️⃣), or a single joiner (U+200D) between two pictographs (👩‍💻, 👩🏽‍💻, ❤️‍🔥).
 * Nothing longer is: a run of selectors, or any supplementary selector, carries data.
 */
function partOfGlyph(run: string, text: string, offset: number): boolean {
  const before = text.slice(Math.max(0, offset - 2), offset).match(/.$/su)?.[0] ?? "";
  const after = text.slice(offset + run.length, offset + run.length + 2).match(/^./su)?.[0] ?? "";
  if (run === "\uFE0E" || run === "\uFE0F")
    return PICTOGRAPH.test(before) || (KEYCAP_BASE.test(before) && after === "\u20E3");
  if (run === "\u200D") return GLYPH_BASE.test(before) && PICTOGRAPH.test(after);
  if (run === "\uFE0F\u200D") return PICTOGRAPH.test(before) && PICTOGRAPH.test(after);
  return false;
}

/** How many characters of `text` the card cannot show. */
const hiddenIn = (text: string): number =>
  [...lineEnds(text).matchAll(HIDDEN)].reduce(
    (sum, run) => sum + (partOfGlyph(run[0], run.input, run.index) ? 0 : countOf(run[0])),
    0,
  );

/** A text the owner can read in full: line endings as \n, each hidden run as a visible count. Idempotent. */
const visible = (text: string): string =>
  lineEnds(text).replace(HIDDEN, (run, offset: number, whole: string) => {
    if (partOfGlyph(run, whole, offset)) return run;
    const count = countOf(run);
    return `⟨${count} hidden character${count === 1 ? "" : "s"}⟩`;
  });

/** A title: the client shows it as plain text, so it is one clipped line with hidden characters dropped. */
function flat(text: string, length: number): string {
  const one = lineEnds(text)
    .replace(HIDDEN, (run, offset: number, whole: string) =>
      partOfGlyph(run, whole, offset) ? run : "",
    )
    .replace(/[“”]/g, '"')
    .replace(/\s+/gu, " ")
    .trim();
  const chars = [...one];
  return chars.length > length
    ? `${chars
        .slice(0, length - 1)
        .join("")
        .trimEnd()}…`
    : one;
}

const NAME_LENGTH = 60;
/** A value in the summary line stays short; the detail below it has the rest. */
const SUMMARY_VALUE_LENGTH = 40;

const longestRun = (text: string): number =>
  Math.max(0, ...(text.match(/`+/g) ?? []).map((run) => run.length));

/**
 * Inline code of a raw text: its delimiter is longer than any backtick run inside, and it never
 * spans lines (a line ending is a space). Nothing else changes and nothing is cut, so a value
 * shows as it is sent.
 */
const code = (text: string): string => span(visible(text).replace(/\n/g, " "));

/** `code` of the first characters only, ending in "…": a preview that the whole value follows. */
function brief(text: string): string {
  const chars = [...visible(text).replace(/\n/g, " ")];
  return span(
    chars.length > SUMMARY_VALUE_LENGTH
      ? `${chars.slice(0, SUMMARY_VALUE_LENGTH - 1).join("")}…`
      : chars.join(""),
  );
}

/** A code span around one line of visible text. */
function span(inside: string): string {
  if (inside === "") return "` `";
  const run = longestRun(inside);
  const mark = "`".repeat(run + 1);
  // Markdown drops one space at each end of a span that has one at both, and a span cannot begin or end with a backtick.
  const pad = run > 0 || (inside.startsWith(" ") && inside.endsWith(" ") && inside.trim() !== "");
  return pad ? `${mark} ${inside} ${mark}` : `${mark}${inside}${mark}`;
}

/** A fenced block of a raw text, whose fence is longer than any backtick run in it. */
function fenced(language: string, text: string): string {
  const lines = visible(text).split("\n");
  const mark = "`".repeat(Math.max(3, longestRun(lines.join("\n")) + 1));
  return [`${mark}${language}`, ...lines, mark].join("\n");
}

const CONTEXT = 2;
const MAX_LCS_CELLS = 250_000;

type Op = [" " | "-" | "+", string];

/** Line changes, `- old` / `+ new`, of two raw texts, with only a few unchanged lines around each change. */
function lineDiff(before: string, after: string): string[] {
  const a = before === "" ? [] : visible(before).split("\n");
  const b = after === "" ? [] : visible(after).split("\n");
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head += 1;
  let tail = 0;
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  )
    tail += 1;
  const midA = a.slice(head, a.length - tail);
  const midB = b.slice(head, b.length - tail);
  const ops: Op[] = a.slice(0, head).map((line) => [" ", line]);
  if (midA.length * midB.length > MAX_LCS_CELLS)
    ops.push(...midA.map((line): Op => ["-", line]), ...midB.map((line): Op => ["+", line]));
  else {
    // Longest common subsequence of the lines that differ, as a flat table.
    const width = midB.length + 1;
    const table = new Uint32Array((midA.length + 1) * width);
    const cell = (i: number, j: number): number => table[i * width + j] ?? 0;
    for (let i = midA.length - 1; i >= 0; i -= 1)
      for (let j = midB.length - 1; j >= 0; j -= 1)
        table[i * width + j] =
          midA[i] === midB[j] ? cell(i + 1, j + 1) + 1 : Math.max(cell(i + 1, j), cell(i, j + 1));
    let i = 0;
    let j = 0;
    while (i < midA.length || j < midB.length) {
      if (i < midA.length && j < midB.length && midA[i] === midB[j]) {
        ops.push([" ", midA[i] ?? ""]);
        i += 1;
        j += 1;
      } else if (j >= midB.length || (i < midA.length && cell(i + 1, j) >= cell(i, j + 1))) {
        ops.push(["-", midA[i] ?? ""]);
        i += 1;
      } else {
        ops.push(["+", midB[j] ?? ""]);
        j += 1;
      }
    }
  }
  ops.push(...a.slice(a.length - tail).map((line): Op => [" ", line]));

  const near = ops.map((_, index) =>
    ops.slice(Math.max(0, index - CONTEXT), index + CONTEXT + 1).some(([mark]) => mark !== " "),
  );
  const lines: string[] = [];
  let skipped = false;
  ops.forEach(([mark, line], index) => {
    if (!near[index]) {
      skipped = lines.length > 0;
      return;
    }
    if (skipped) lines.push("@@");
    skipped = false;
    lines.push(`${mark} ${line}`);
  });
  return lines;
}

// ---------------------------------------------------------------------------------------------
// The card
// ---------------------------------------------------------------------------------------------

const SUMMARY_FIELDS = 4;

/** A value as the text of a diff or text block: a string as is, anything else as pretty JSON. */
const linesOf = (value: JsonValue, raw: string): string =>
  typeof value === "string" ? raw : JSON.stringify(value, null, 2);

/** One field in words: its part of the summary line, and its detail block. */
function render(
  field: Field,
  names: { [id: string]: string },
  quote: string | undefined,
  diff: boolean,
): { summary: string; detail: string; hidden: number } {
  const { text: label, made } = labelOf(field.path);
  // A made label loses case, dots and hidden characters, so the key itself follows it, as sent.
  const key = made ? ` (${code(field.path)})` : "";
  const keyBrief = made ? ` (${brief(field.path)})` : "";
  const head = made ? `**${label}**${key}:` : `**${label}:**`;
  const name = `${label}${keyBrief}`;
  const before = field.before === undefined ? undefined : show(field.path, field.before, names);
  const after = field.after === undefined ? undefined : show(field.path, field.after, names);
  // What a missing or empty list means: a sandbox with no allowed hosts reaches every host, and an
  // empty one none; with no tools list every tool is allowed.
  const lifts = own(LIFTS, field.path);
  const dropped = liftedBy(field);
  const emptied =
    field.removed !== true && lifts && Array.isArray(field.after) && field.after.length === 0
      ? ` (${lifts.empty})`
      : "";
  const effect = dropped ? `: ${dropped.gone}` : "";
  const block = (lines: string[]): string =>
    `**${label}**${key}\n\n${fenced("diff", lines.join("\n"))}${dropped ? `\n\n${dropped.sentence}` : ""}`;
  // The hidden characters this field shows as markers, once each: its values, and a key shown as sent.
  const hidden = hiddenIn(before ?? "") + hiddenIn(after ?? "") + (made ? hiddenIn(field.path) : 0);

  if (field.removed) {
    const old = field.before === undefined ? "" : linesOf(field.before, before ?? "");
    return isLong(before ?? "")
      ? { summary: `${name} removed${effect}`, detail: block(lineDiff(old, "")), hidden }
      : {
          summary: `${name} removed${effect}`,
          detail: `${head} ${before === undefined ? "" : `${code(before)} → `}(removed${effect})`,
          hidden,
        };
  }
  const text = after ?? "";
  if (diff) {
    if (isLong(before ?? "") || isLong(text)) {
      const old = field.before === undefined ? "" : linesOf(field.before, before ?? "");
      return {
        summary: `${name} changed`,
        detail: block(lineDiff(old, linesOf(field.after as JsonValue, text))),
        hidden,
      };
    }
    return {
      summary:
        before === undefined
          ? `${name} set to ${brief(text)}${emptied}`
          : `${name} ${brief(before)} → ${brief(text)}${emptied}`,
      detail: `${head} ${before === undefined ? "(not set)" : code(before)} → ${code(text)}${emptied}`,
      hidden,
    };
  }
  if (field.path === quote || isLong(text))
    return {
      summary: `${name} (${countOf(text)} characters)`,
      detail: `**${label}**${key}\n\n${fenced("text", linesOf(field.after as JsonValue, text))}`,
      hidden,
    };
  return {
    summary: `${name}: ${brief(text)}${emptied}`,
    detail: `${head} ${code(text)}${emptied}`,
    hidden,
  };
}

/** The confirm card of `write`: what changes in words, by name, and the technical request last. */
export function cardOf(write: ControlWrite): WriteCard {
  const body = record(write.body);
  const names = write.names ?? {};
  const nameFor = (id: string): string | undefined => own(names, id);
  const route = routeOf(write.method, write.path, body);
  const hidden = new Set([...MECHANICS, ...(route.hide ?? [])]);
  const known = write.current !== undefined;
  const diff = route.change === true && known;
  const fields = body
    ? diff
      ? changes(body, write.current as JsonValue, hidden)
      : leaves(body, "", hidden, [])
    : [];
  const rendered = fields.map((field) => render(field, names, route.quote, diff));

  let summary: string;
  if (diff && rendered.length === 0) summary = "No field differs from the current record.";
  else if (rendered.length === 0) summary = route.does;
  else {
    const parts = rendered.slice(0, SUMMARY_FIELDS).map((entry) => entry.summary);
    if (rendered.length > SUMMARY_FIELDS) parts.push(`+${rendered.length - SUMMARY_FIELDS} more`);
    summary = (route.change && !diff ? "Sets " : "") + parts.join(" · ");
  }

  const warnings: string[] = [];
  // Every hidden character the card shows as a marker: in a value, in the details, in an error.
  let marked =
    rendered.reduce((sum, entry) => sum + entry.hidden, 0) +
    hiddenIn(`${write.method} ${write.path}`);
  const noun = route.target?.noun ?? "record";
  const why = (): string => {
    if (!write.currentError) return "";
    marked += hiddenIn(write.currentError);
    return `: ${code(write.currentError)}`;
  };
  if (route.change && !known)
    warnings.push(
      write.currentError !== undefined
        ? `Oppi could not read the current ${noun}, so this card cannot show what changes${why()}.`
        : `Oppi does not read the current record for this request, so this card cannot show what changes.`,
    );
  else if (route.target && nameFor(route.target.id) === undefined)
    warnings.push(`Oppi could not look up this ${noun}'s name, so it is shown by its id${why()}.`);
  // A body that replaces the sandbox config without a hosts list lifts the host limit, whether or
  // not the old config was read, and a field above may already say so.
  const config = body ? own(body, "sandboxConfig") : undefined;
  if (
    config !== undefined &&
    (config === null ||
      (record(config) && own(record(config) as Obj, "allowedHosts") === undefined)) &&
    !fields.some((field) => liftedBy(field)?.gone === LIFTS[ALLOWED_HOSTS]?.gone)
  )
    warnings.push(
      "This replaces the sandbox config without an allowed hosts list: every host is allowed.",
    );
  if (write.method === "PATCH" && !/[?&]expectedVersion=/.test(write.path))
    warnings.push(
      known
        ? "If this changed since Oppi read it, this overwrites the newer version."
        : "Nothing checks whether this changed meanwhile, so it overwrites any newer version.",
    );

  if (marked > 0)
    warnings.push(
      marked === 1
        ? "This card shows 1 character as a ⟨hidden⟩ marker; if it is in the request, it is sent as written."
        : `This card shows ${marked} characters as ⟨hidden⟩ markers; any in the request are sent as written.`,
    );

  const message = [
    summary,
    ...rendered.map((entry) => entry.detail),
    ...warnings,
    `Details: ${code(`${write.method} ${write.path}`)}`,
  ].join("\n\n");
  const name = route.target ? nameFor(route.target.id) : undefined;
  return { title: route.title(name), message, confirm: route.confirm };
}
