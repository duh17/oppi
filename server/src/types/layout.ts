// Pane layout files: `<checkout>/.oppi/layouts/<name>.json`. The spec is `docs/layouts.md`, the
// schema `protocol/layout.schema.json`, and the shared vectors `protocol/layouts/`.

/** One problem or warning in a layout document, at a JSON path like `root.children[1].file`. */
export interface LayoutIssue {
  /** Stable kind, shared with the app's validator through `protocol/layouts/`. */
  code: LayoutIssueCode;
  /** Where in the document: `""` is the document itself. */
  path: string;
  /** What is wrong and what is allowed there. */
  message: string;
}

export type LayoutIssueCode =
  // Reading the bytes
  | "tooLarge"
  | "notUtf8"
  | "notJson"
  // Shape
  | "type"
  | "required"
  | "empty"
  | "tooLong"
  | "pattern"
  | "range"
  | "value"
  // Tree
  | "children"
  | "weights"
  | "depth"
  | "leafCount"
  | "duplicatePane"
  | "focus"
  | "contentCount"
  | "noContent"
  | "modifier"
  // Content
  | "parentPath"
  | "webScheme"
  | "webUserInfo"
  | "webLoopback"
  // Warnings
  | "unknownField"
  | "unknownKind"
  | "absolutePath";

export type LayoutAxis = "row" | "column";

export interface LayoutSplit {
  split: LayoutAxis;
  children: LayoutNode[];
  /** As written; equal shares when absent. */
  weights?: number[];
}

/** `{ "rex": block }`, `{ "hc": terminal }` or `{ "ssh": saved host }`. */
export type LayoutTerminal = { rex: string } | { hc: string } | { ssh: string };

interface LayoutLeafBase {
  /** `[a-z0-9-]{1,24}`, unique in the document. */
  pane: string;
  /** Display name, at most 24 characters, control and bidi characters removed. */
  name?: string;
}

/** A leaf with exactly one known content field. */
export type LayoutKnownLeaf = LayoutLeafBase &
  (
    | { chat: string }
    | { file: string; line?: number }
    | { panel: string; session?: string }
    | { git: string }
    | { web: string }
    | { terminal: LayoutTerminal }
  );

/**
 * A leaf of a kind this server does not know: no known content field, at least one other field.
 * Kept as written (besides a cleaned `name`) so a newer app can show it.
 */
export type LayoutUnknownLeaf = LayoutLeafBase & { [field: string]: unknown };

export type LayoutLeaf = LayoutKnownLeaf | LayoutUnknownLeaf;

export type LayoutNode = LayoutSplit | LayoutLeaf;

/** A valid version 1 document: unknown fields on known objects dropped, title and names cleaned. */
export interface LayoutDocument {
  v: 1;
  title: string;
  root: LayoutNode;
  /** The `pane` of a leaf. */
  focus: string;
}

/** A layout file as the server read it. */
export type LayoutFileState =
  | { state: "valid"; hash: string; layout: LayoutDocument; warnings: LayoutIssue[] }
  /** `hash` is absent when the file was too large to read whole. */
  | { state: "invalid"; hash?: string; problems: LayoutIssue[]; warnings: LayoutIssue[] }
  /** A `v` this server does not know: listed, never opened. */
  | { state: "newer"; hash: string; v: number; title?: string }
  | { state: "missing" };

/** Who wrote a listed layout file, as far as the server can tell. */
export type LayoutSource =
  /** The newest tracked `write` or `edit` that left the file as it is now. */
  | { kind: "session"; sessionId: string }
  /** Tracked and unmodified in the checkout's git repository. */
  | { kind: "repository" }
  /** Anything else: a shell, a script, a person, another program. */
  | { kind: "folder" };

/** One row of `GET /workspaces/{id}/layouts`. */
export interface WorkspaceLayoutSummary {
  /** The file name without `.json`. */
  name: string;
  /** The checkout the file is in. */
  worktreeId: string;
  /** That checkout's display name, so two files with one name can be told apart. */
  checkout: string;
  /** Checkout-relative: `.oppi/layouts/<name>.json`. */
  path: string;
  /** `sha256-<hex>` of the bytes; absent when the file was too large to read whole. */
  hash?: string;
  source: LayoutSource;
  title?: string;
  /** Leaves in a valid document. */
  leafCount?: number;
  /** The first problem of an invalid file. */
  problem?: LayoutIssue;
  /** The file's `v`, when it is newer than this server reads. */
  newerVersion?: number;
}

export interface WorkspaceLayoutsResponse {
  layouts: WorkspaceLayoutSummary[];
}

/** `GET /workspaces/{id}/layouts/{name}`: one file, read now. */
export interface WorkspaceLayoutResponse {
  name: string;
  worktreeId: string;
  checkout: string;
  path: string;
  source: LayoutSource;
  file: Exclude<LayoutFileState, { state: "missing" }>;
}

/**
 * A layout file a session's tracked `write` or `edit` left in a layouts folder. Sent live as
 * `layout_proposal` after the tool call ends, and derived again for each trace page.
 */
export interface LayoutProposal {
  toolCallId: string;
  workspaceId: string;
  worktreeId: string;
  checkout: string;
  name: string;
  path: string;
  /** The file as it is now. */
  file: LayoutFileState;
  /** The file no longer holds what this tool call left (a later write, or an edit undone). */
  changed?: true;
}
