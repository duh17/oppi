/**
 * The rules of a pane layout document (`docs/layouts.md`), as one pure function: no file system,
 * no network, no clock. Discovery (`layout-files.ts`) and `oppi layout check` both call it, so a
 * host with no file system can run the same rules; the app's Swift validator passes the same
 * vectors (`protocol/layouts/`).
 *
 * Each typed content field is checked directly. There is no link parser here: a layout only names
 * what a pane shows, and the app builds its links. Problems are collected in document order, and
 * the first one is the one a card names.
 */
import type {
  LayoutDocument,
  LayoutIssue,
  LayoutIssueCode,
  LayoutLeaf,
  LayoutNode,
  LayoutSplit,
  LayoutTerminal,
} from "./types.js";

export const LAYOUT_VERSION = 1;
/** Bytes; a reader reads at most one more to know a file is over. */
export const LAYOUT_MAX_BYTES = 16 * 1024;
const LAYOUT_MAX_LEAVES = 8;
/** Nested splits on the deepest path; a lone leaf is 0. */
const LAYOUT_MAX_DEPTH = 3;
const LAYOUT_MIN_CHILDREN = 2;
const LAYOUT_MAX_CHILDREN = 8;
const LAYOUT_TITLE_MAX = 60;
const LAYOUT_NAME_MAX = 24;
const LAYOUT_WEB_MAX_BYTES = 2048;
/** Where a checkout keeps its layout files, relative to the checkout. */
export const LAYOUTS_FOLDER = ".oppi/layouts";
/** A layout file's name; the layout's name is this without `.json`. */
export const LAYOUT_FILE_NAME = /^[a-z0-9][a-z0-9_-]{0,47}\.json$/;

const PANE_ID = /^[a-z0-9-]{1,24}$/;
/** A session id (a UUID today) or a surface id: printable, no spaces. */
const REFERENCE = /^[\x21-\x7e]{1,128}$/;
const GIT_SHA = /^[0-9a-f]{7,64}$/;
const TERMINAL_KINDS = ["rex", "hc", "ssh"] as const;
const CONTENT_FIELDS = ["chat", "file", "panel", "git", "web", "terminal", "godot"] as const;
type ContentField = (typeof CONTENT_FIELDS)[number];

const DOCUMENT_FIELDS = new Set(["$schema", "v", "title", "root", "focus"]);
const SPLIT_FIELDS = new Set(["split", "children", "weights"]);
/** Fields a known leaf may carry besides its content field. */
const LEAF_FIELDS: Record<ContentField, readonly string[]> = {
  chat: [],
  file: ["line"],
  panel: ["session"],
  git: [],
  web: [],
  terminal: [],
  godot: [],
};
/** Fields that only mean something next to one content field. */
const MODIFIER_OF: Record<string, ContentField> = { line: "file", session: "panel" };

export type LayoutValidation =
  | { kind: "valid"; layout: LayoutDocument; warnings: LayoutIssue[] }
  | { kind: "invalid"; problems: LayoutIssue[]; warnings: LayoutIssue[] }
  /** A `v` above 1: listed as needing a newer Oppi, never opened. */
  | { kind: "newer"; v: number; title?: string };

/**
 * A layout file's bytes, as read. More than `LAYOUT_MAX_BYTES` is refused unparsed. A UTF-8 byte
 * order mark is skipped; any other encoding is refused.
 */
export function validateLayoutBytes(bytes: Uint8Array): LayoutValidation {
  if (bytes.length > LAYOUT_MAX_BYTES) {
    return refused(
      "tooLarge",
      "",
      `a layout is at most ${LAYOUT_MAX_BYTES} bytes (16 KiB), found more`,
    );
  }
  const body =
    bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? bytes.subarray(3) : bytes;
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    return refused("notUtf8", "", "a layout file is UTF-8 text");
  }
  return validateLayoutText(text);
}

/** A layout document's JSON text, for a file already decoded or an inline block. */
export function validateLayoutText(text: string): LayoutValidation {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return refused("notJson", "", "a layout is one JSON object");
  }
  return validateLayoutValue(value);
}

/** A parsed layout document. JSON's last-key-wins already applied when it was parsed. */
export function validateLayoutValue(value: unknown): LayoutValidation {
  const check = new Checker();
  if (!isObject(value)) {
    check.problem("type", "", "a layout is one JSON object");
    return check.result(undefined);
  }

  const version = value.v;
  if (version === undefined) {
    check.problem("required", "v", `"v" is required: the layout version, ${LAYOUT_VERSION}`);
  } else if (typeof version !== "number" || !Number.isInteger(version)) {
    check.problem("type", "v", `"v" is an integer: the layout version, ${LAYOUT_VERSION}`);
  } else if (version < LAYOUT_VERSION) {
    check.problem("range", "v", `"v" is ${LAYOUT_VERSION}, found ${version}`);
  } else if (version > LAYOUT_VERSION) {
    // Only the title is read from a newer document: it names the row that needs a newer Oppi.
    const title = typeof value.title === "string" ? cleanLabel(value.title) : "";
    return {
      kind: "newer",
      v: version,
      ...(title && codePoints(title) <= LAYOUT_TITLE_MAX ? { title } : {}),
    };
  }

  check.unknownFields(value, DOCUMENT_FIELDS, "");
  const title = check.label(value.title, "title", LAYOUT_TITLE_MAX, true);

  let root: LayoutNode | undefined;
  if (value.root === undefined) {
    check.problem("required", "root", `"root" is required: a split or a leaf`);
  } else {
    root = check.node(value.root, "root", 0);
  }

  let focus: string | undefined;
  if (value.focus === undefined) {
    check.problem("required", "focus", `"focus" is required: the "pane" of one leaf`);
  } else if (typeof value.focus !== "string") {
    check.problem("type", "focus", `"focus" is a string: the "pane" of one leaf`);
  } else if (root && !check.panes.includes(value.focus)) {
    check.problem(
      "focus",
      "focus",
      `"focus" names a leaf's "pane" (${check.panes.join(", ") || "none"}), found "${value.focus}"`,
    );
  } else {
    focus = value.focus;
  }

  if (check.leafCount > LAYOUT_MAX_LEAVES) {
    check.problem(
      "leafCount",
      "root",
      `a layout has at most ${LAYOUT_MAX_LEAVES} leaves, found ${check.leafCount}`,
    );
  }

  return check.result(
    title !== undefined && root && focus !== undefined
      ? { v: LAYOUT_VERSION, title, root, focus }
      : undefined,
  );
}

/** Leaves in tree order. */
export function layoutLeaves(node: LayoutNode): LayoutLeaf[] {
  return isSplit(node) ? node.children.flatMap(layoutLeaves) : [node];
}

/** The content field a known leaf carries; undefined for a leaf of an unknown kind. */
export function layoutLeafKind(leaf: LayoutLeaf): ContentField | undefined {
  return CONTENT_FIELDS.find((field) => Object.hasOwn(leaf, field));
}

/**
 * A title or pane name as it is shown: control and bidirectional formatting characters removed,
 * line breaks and tabs as spaces, trimmed. Both are one line of plain text, never Markdown.
 * Pin labels follow the same rule.
 */
export function cleanLabel(text: string): string {
  return (
    text
      // Line and paragraph breaks and tabs keep the words apart.
      .replace(/[\t\n\v\f\r\u0085\u2028\u2029]+/g, " ")
      // C0 and C1 controls, and the bidi embedding, override, isolate, and mark characters.
      // eslint-disable-next-line no-control-regex
      .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .trim()
  );
}

function refused(code: LayoutIssueCode, path: string, message: string): LayoutValidation {
  return { kind: "invalid", problems: [{ code, path, message }], warnings: [] };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSplit(node: LayoutNode): node is LayoutSplit {
  return Object.hasOwn(node, "split");
}

function codePoints(text: string): number {
  let count = 0;
  for (const _ of text) count += 1;
  return count;
}

function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length;
}

function join(path: string, key: string): string {
  return path ? `${path}.${key}` : key;
}

class Checker {
  readonly problems: LayoutIssue[] = [];
  readonly warnings: LayoutIssue[] = [];
  /** Every leaf id, in tree order, duplicates included once. */
  readonly panes: string[] = [];
  leafCount = 0;

  problem(code: LayoutIssueCode, path: string, message: string): void {
    this.problems.push({ code, path, message });
  }

  warning(code: LayoutIssueCode, path: string, message: string): void {
    this.warnings.push({ code, path, message });
  }

  result(layout: LayoutDocument | undefined): LayoutValidation {
    if (this.problems.length > 0 || !layout) {
      return { kind: "invalid", problems: this.problems, warnings: this.warnings };
    }
    return { kind: "valid", layout, warnings: this.warnings };
  }

  unknownFields(object: Record<string, unknown>, known: ReadonlySet<string>, path: string): void {
    for (const key of Object.keys(object)) {
      if (known.has(key)) continue;
      this.warning("unknownField", join(path, key), "unknown field, ignored");
    }
  }

  /** A title or name: a string, cleaned, not empty, at most `max` characters. */
  label(value: unknown, path: string, max: number, required: boolean): string | undefined {
    if (value === undefined) {
      if (required)
        this.problem("required", path, `"${path}" is required: at most ${max} characters`);
      return undefined;
    }
    if (typeof value !== "string") {
      this.problem("type", path, `a string of at most ${max} characters`);
      return undefined;
    }
    const clean = cleanLabel(value);
    if (!clean) {
      this.problem("empty", path, `at most ${max} characters, found none`);
      return undefined;
    }
    const length = codePoints(clean);
    if (length > max) {
      this.problem("tooLong", path, `at most ${max} characters, found ${length}`);
      return undefined;
    }
    return clean;
  }

  node(value: unknown, path: string, depth: number): LayoutNode | undefined {
    if (!isObject(value)) {
      this.problem("type", path, `a split ({ "split", "children" }) or a leaf ({ "pane", ... })`);
      return undefined;
    }
    if (Object.hasOwn(value, "split")) return this.split(value, path, depth + 1);
    if (Object.hasOwn(value, "pane")) return this.leaf(value, path);
    this.problem(
      "required",
      path,
      `a split needs "split" ("row" or "column"), a leaf needs "pane"`,
    );
    return undefined;
  }

  split(value: Record<string, unknown>, path: string, depth: number): LayoutSplit | undefined {
    this.unknownFields(value, SPLIT_FIELDS, path);
    let ok = true;
    const axis = value.split;
    if (axis !== "row" && axis !== "column") {
      this.problem("value", join(path, "split"), `"row" or "column", found ${describe(axis)}`);
      ok = false;
    }
    if (depth > LAYOUT_MAX_DEPTH) {
      this.problem(
        "depth",
        path,
        `splits nest at most ${LAYOUT_MAX_DEPTH} deep, this one is ${depth} deep`,
      );
      ok = false;
    }

    const rawChildren = value.children;
    if (!Array.isArray(rawChildren)) {
      this.problem(
        rawChildren === undefined ? "required" : "type",
        join(path, "children"),
        `a list of ${LAYOUT_MIN_CHILDREN} to ${LAYOUT_MAX_CHILDREN} splits or leaves`,
      );
      return undefined;
    }
    if (rawChildren.length < LAYOUT_MIN_CHILDREN || rawChildren.length > LAYOUT_MAX_CHILDREN) {
      this.problem(
        "children",
        path,
        `a split needs ${LAYOUT_MIN_CHILDREN} to ${LAYOUT_MAX_CHILDREN} children, found ${rawChildren.length}`,
      );
      ok = false;
    }

    let weights: number[] | undefined;
    if (value.weights !== undefined) {
      const raw = value.weights;
      if (!Array.isArray(raw)) {
        this.problem("type", join(path, "weights"), "a list of positive numbers, one per child");
        ok = false;
      } else if (raw.length !== rawChildren.length) {
        this.problem(
          "weights",
          join(path, "weights"),
          `one weight per child: ${rawChildren.length} children, found ${raw.length} weights`,
        );
        ok = false;
      } else if (!raw.every((weight) => typeof weight === "number" && weight > 0)) {
        this.problem("weights", join(path, "weights"), "every weight is a positive number");
        ok = false;
      } else {
        weights = raw as number[];
      }
    }

    const children: LayoutNode[] = [];
    rawChildren.forEach((child, index) => {
      const node = this.node(child, `${path}.children[${index}]`, depth);
      if (node) children.push(node);
      else ok = false;
    });
    if (!ok) return undefined;
    return {
      split: axis as LayoutSplit["split"],
      children,
      ...(weights ? { weights } : {}),
    };
  }

  leaf(value: Record<string, unknown>, path: string): LayoutLeaf | undefined {
    this.leafCount += 1;
    let ok = true;

    const pane = value.pane;
    if (typeof pane !== "string" || !PANE_ID.test(pane)) {
      this.problem(
        "pattern",
        join(path, "pane"),
        `an id of 1 to 24 lowercase letters, digits, and "-", found ${describe(pane)}`,
      );
      ok = false;
    } else if (this.panes.includes(pane)) {
      this.problem("duplicatePane", join(path, "pane"), `"${pane}" is already another leaf's id`);
      ok = false;
    } else {
      this.panes.push(pane);
    }
    const name = this.label(value.name, join(path, "name"), LAYOUT_NAME_MAX, false);
    if (value.name !== undefined && name === undefined) ok = false;

    const present = CONTENT_FIELDS.filter((field) => Object.hasOwn(value, field));
    if (present.length > 1) {
      this.problem(
        "contentCount",
        path,
        `a leaf shows one thing: one of ${CONTENT_FIELDS.join(", ")}, found ${present.join(" and ")}`,
      );
      return undefined;
    }

    const kind = present[0];
    if (kind === undefined) {
      const others = Object.keys(value).filter(
        (key) => key !== "pane" && key !== "name" && !Object.hasOwn(MODIFIER_OF, key),
      );
      if (others.length === 0) {
        this.problem("noContent", path, `a leaf needs one of ${CONTENT_FIELDS.join(", ")}`);
        return undefined;
      }
      // A newer kind of leaf: it keeps its place and shows "Needs a newer Oppi".
      this.warning(
        "unknownKind",
        path,
        `a leaf of a kind this Oppi does not know (${others.join(", ")}); it needs a newer Oppi`,
      );
      if (!ok) return undefined;
      return { ...value, pane: pane as string, ...(name ? { name } : {}) } as LayoutLeaf;
    }

    const allowed = new Set(["pane", "name", kind, ...LEAF_FIELDS[kind]]);
    for (const key of Object.keys(value)) {
      if (allowed.has(key)) continue;
      const owner = MODIFIER_OF[key];
      if (owner) {
        this.problem("modifier", join(path, key), `"${key}" belongs only to a "${owner}" leaf`);
        ok = false;
      } else {
        this.warning("unknownField", join(path, key), "unknown field, ignored");
      }
    }

    const content = this.content(kind, value, path);
    if (!content || !ok) return undefined;
    return { pane: pane as string, ...(name ? { name } : {}), ...content } as LayoutLeaf;
  }

  content(
    kind: ContentField,
    leaf: Record<string, unknown>,
    path: string,
  ): Record<string, unknown> | undefined {
    const value = leaf[kind];
    const at = join(path, kind);
    switch (kind) {
      case "chat":
        if (typeof value === "string" && (value === "self" || REFERENCE.test(value))) {
          return { chat: value };
        }
        this.problem("value", at, `"self" (the chat it opens from) or a session id`);
        return undefined;
      case "file":
        return this.file(value, leaf.line, path);
      case "panel": {
        if (typeof value !== "string" || !REFERENCE.test(value)) {
          this.problem("value", at, 'a surface id, like "widget:subagents"');
          return undefined;
        }
        const session = leaf.session;
        if (session === undefined) return { panel: value };
        if (typeof session === "string" && (session === "self" || REFERENCE.test(session))) {
          return { panel: value, session };
        }
        this.problem("value", join(path, "session"), `"self" (the default) or a session id`);
        return undefined;
      }
      case "git":
        if (typeof value === "string" && (value === "status" || GIT_SHA.test(value))) {
          return { git: value };
        }
        this.problem("value", at, `"status" or a commit sha (7 to 64 lowercase hex digits)`);
        return undefined;
      case "web":
        return this.web(value, at);
      case "terminal":
        return this.terminal(value, at);
      case "godot":
        // The id the server's discovery names (`GET /godot`); whether it still exists is
        // decided when the pane opens, as for a session.
        if (typeof value === "string" && REFERENCE.test(value)) return { godot: value };
        this.problem("value", at, 'a Godot project id, like "tide-3fa9c2b1"');
        return undefined;
    }
  }

  file(value: unknown, line: unknown, path: string): Record<string, unknown> | undefined {
    const at = join(path, "file");
    let ok = true;
    if (typeof value !== "string" || value.length === 0) {
      this.problem("value", at, "a path relative to the checkout, or an absolute path");
      return undefined;
    }
    // eslint-disable-next-line no-control-regex
    if (/[\u0000-\u001f\u007f]/.test(value)) {
      this.problem("value", at, "a path with no control characters");
      ok = false;
    } else if (value.split(/[/\\]/).includes("..")) {
      this.problem("parentPath", at, `a path with no ".." part`);
      ok = false;
    } else if (value.startsWith("~")) {
      this.problem("value", at, `a path relative to the checkout, or absolute ("/..."), not "~"`);
      ok = false;
    } else if (value.startsWith("/")) {
      this.warning(
        "absolutePath",
        at,
        "an absolute path ties this layout to one machine; a path relative to the checkout works on every one",
      );
    }
    if (line !== undefined && !(typeof line === "number" && Number.isInteger(line) && line >= 1)) {
      this.problem("range", join(path, "line"), "a line number, 1 or more");
      ok = false;
    }
    if (!ok) return undefined;
    return { file: value, ...(line !== undefined ? { line } : {}) };
  }

  web(value: unknown, at: string): Record<string, unknown> | undefined {
    if (typeof value !== "string") {
      this.problem("value", at, "an http or https URL");
      return undefined;
    }
    if (utf8Length(value) > LAYOUT_WEB_MAX_BYTES) {
      this.problem("tooLong", at, `a URL of at most ${LAYOUT_WEB_MAX_BYTES} bytes`);
      return undefined;
    }
    let url: URL;
    try {
      url = new URL(value);
    } catch {
      this.problem("value", at, "an http or https URL");
      return undefined;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      this.problem("webScheme", at, `an http or https URL, found "${url.protocol}"`);
      return undefined;
    }
    if (url.username || url.password) {
      this.problem("webUserInfo", at, "a URL with no user name or password");
      return undefined;
    }
    if (isLoopbackHost(url.hostname)) {
      // On the phone, loopback is the phone; on the Mac it is the Mac. The same layout would
      // open a different site on each, so it names a reachable host instead.
      this.problem(
        "webLoopback",
        at,
        "a host other devices can reach; loopback (localhost, 127.0.0.0/8, ::1) means a different machine on each device",
      );
      return undefined;
    }
    return { web: value };
  }

  terminal(value: unknown, at: string): Record<string, unknown> | undefined {
    const allowed = `{ "rex": block }, { "hc": terminal } or { "ssh": saved host }`;
    if (!isObject(value)) {
      this.problem("type", at, allowed);
      return undefined;
    }
    const kinds = TERMINAL_KINDS.filter((kind) => Object.hasOwn(value, kind));
    if (kinds.length !== 1) {
      this.problem("value", at, `exactly one of ${allowed}`);
      return undefined;
    }
    const kind = kinds[0] as (typeof TERMINAL_KINDS)[number];
    const target = value[kind];
    if (
      typeof target !== "string" ||
      !target ||
      cleanLabel(target) !== target ||
      codePoints(target) > 128
    ) {
      this.problem("value", join(at, kind), "a name on one line, at most 128 characters");
      return undefined;
    }
    this.unknownFields(value, new Set([kind]), at);
    return { terminal: { [kind]: target } as LayoutTerminal };
  }
}

/** Loopback as a URL parser leaves it: `localhost`, `*.localhost`, 127.0.0.0/8, `[::1]`. */
export function isLoopbackHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (host === "localhost" || host.endsWith(".localhost")) return true;
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
  if (host === "[::1]") return true;
  // IPv4-mapped IPv6 of 127.0.0.0/8, which the parser writes in hex: [::ffff:7f00:1].
  return /^\[::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}\]$/.test(host);
}

function describe(value: unknown): string {
  if (value === undefined) return "nothing";
  if (typeof value === "string") return `"${value}"`;
  return JSON.stringify(value) ?? String(value);
}
