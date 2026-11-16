// Plugin screens: sidebar entries a built-in plugin contributes (`oppi.sidebar`) and the list
// pages it draws them with, one Chord document per `{ scope, page }`, watched over
// `WS /screens/stream`. The vocabulary is closed and versioned as one integer
// (`capabilities.screens.v`); the app draws it with its own list kit, so a page is data, never
// code. Fixtures: `protocol/screens.json` (server `screens-fixtures.test.ts`, Apple
// `PluginScreenProtocolTests`).

import type { ServerFeature } from "./config.js";
import type { ConversationDocOp } from "./protocol.js";

/** A word's colour, the only styling a page has. Status is always a word, never tone alone. */
export type ScreenTone = "secondary" | "accent" | "success" | "warning" | "danger";

/** A row's status: a word, an optional symbol from the surface icon allow-list, and a tone. */
export interface ScreenStatus {
  text: string;
  symbol?: string;
  tone?: ScreenTone;
}

/**
 * A row that opens something: another page of this entry (`push`), a web page (`url`), or a
 * file on the server's host (`file`, an absolute path), which the app opens in its own file
 * viewer with whatever editing the server allows for that file. At most one of the three.
 * `symbol` leads the row; `subtitle` may run several lines.
 */
export interface ScreenItemRow {
  kind: "item";
  id: string;
  title: string;
  subtitle?: string;
  symbol?: string;
  status?: ScreenStatus;
  push?: string;
  url?: string;
  file?: string;
}

/** A label and its value. `mono` sets both in monospace, the label quieter: a key and its value. */
export interface ScreenValueRow {
  kind: "value";
  id: string;
  label: string;
  value: string;
  mono?: boolean;
}

/** Text on its own: a URL, a command, a note, an error. */
export interface ScreenTextRow {
  kind: "text";
  id: string;
  text: string;
  style?: "body" | "footnote";
  mono?: boolean;
  tone?: ScreenTone;
  selectable?: boolean;
}

/**
 * A switch. On a page without `submit` a change sends `act { action, row, values }`; on a form
 * page it writes the local draft under the row's id.
 */
export interface ScreenToggleRow {
  kind: "toggle";
  id: string;
  label: string;
  value: boolean;
  action?: string;
  disabled?: boolean;
}

/**
 * One of a few values; the app picks a menu or a segmented control. Acts or drafts as a toggle.
 * The chosen option's `footer` leads its section's footer, so a form explains what is picked as
 * the person picks it, without a round trip.
 */
export interface ScreenChoiceRow {
  kind: "choice";
  id: string;
  label: string;
  value: string;
  options: { value: string; title: string; footer?: string }[];
  action?: string;
  disabled?: boolean;
}

/** What a destructive button asks before it acts; the app draws the confirmation. */
export interface ScreenConfirm {
  title: string;
  message?: string;
  button: string;
}

/** A button: an action of the plugin's, or a web page. */
export interface ScreenButtonRow {
  kind: "button";
  id: string;
  title: string;
  role?: "destructive";
  action?: string;
  url?: string;
  confirm?: ScreenConfirm;
  disabled?: boolean;
}

/** Text the person types into the page's local draft, under the row's id; only form pages. */
export interface ScreenFieldRow {
  kind: "field";
  id: string;
  label?: string;
  placeholder?: string;
  value?: string;
  input?: "text" | "secret" | "number" | "url" | "multiline";
}

export type ScreenRow =
  | ScreenItemRow
  | ScreenValueRow
  | ScreenTextRow
  | ScreenToggleRow
  | ScreenChoiceRow
  | ScreenButtonRow
  | ScreenFieldRow;

export type ScreenRowKind = ScreenRow["kind"];

/** A group of rows. `when` shows it only while the draft's `field` equals `is` (a form's Transport). */
export interface ScreenSection {
  id: string;
  header?: string;
  /**
   * The app adds its own name for this server to the header (`<header> · <server>`): only the
   * app knows what the person calls the host.
   */
  namesHost?: boolean;
  footer?: string;
  rows: ScreenRow[];
  when?: { field: string; is: string };
}

/** A navigation bar button: an action, or another page pushed or presented as a sheet. */
export interface ScreenBarItem {
  id: string;
  title: string;
  symbol?: string;
  action?: string;
  push?: string;
  present?: string;
  disabled?: boolean;
}

/** The page's own state in place of its rows: loading, empty, or failed with Retry (`refresh`). */
export interface ScreenPageState {
  kind: "loading" | "empty" | "failed";
  title?: string;
  message?: string;
}

/**
 * One page. A page with `submit` is a form: the app keeps a local draft of its toggles, choices
 * and fields, so typing never round-trips, and sends it with `submit.action`. Submit stays off
 * until every field `requires` names is filled, among the sections the draft shows.
 */
export interface ScreenPage {
  title: string;
  state?: ScreenPageState;
  /**
   * A search field in the bar. The app filters the page's item rows on the device by their
   * title, subtitle and status, hides sections left without rows, and keeps the query while the
   * page updates.
   */
  search?: { prompt: string };
  bar?: ScreenBarItem[];
  sections: ScreenSection[];
  submit?: { title: string; action: string; requires?: string[] };
}

/** What an action asks the app to do next; only the person's own tap leads here. */
export type ScreenNav =
  { kind: "pop" } | { kind: "push"; page: string } | { kind: "present"; page: string };

/** A draft value or a toggle's new state, by row id. */
export interface ScreenValue {
  field: string;
  value: string | boolean;
}

/** A sidebar entry as `/server/info` lists it. */
export interface ScreenSidebarEntry {
  id: string;
  title: string;
  /** An SF Symbol from the surface icon allow-list. */
  icon: string;
  order: number;
  /**
   * `server`: a sidebar entry. `workspace`: the same screen scoped to one host workspace, which
   * the app opens from Workspace Settings by the entry's `feature`.
   */
  scopes: ("server" | "workspace")[];
  /** The server switch the entry belongs to; the app finds a workspace's page by it. */
  feature?: ServerFeature;
}

// ---------------------------------------------------------------------------------------------
// WS /screens/stream
// ---------------------------------------------------------------------------------------------

export type ScreensClientMessage =
  | {
      type: "watch";
      /** The app's id for this watch on this socket. */
      watch: string;
      entry: string;
      /** `server`, or `workspace:<id>` for an entry whose scopes include `workspace`. */
      scope: string;
      page: string;
      /** The vocabulary version the app draws (`capabilities.screens.v`). */
      v: number;
    }
  | { type: "unwatch"; watch: string }
  | {
      type: "act";
      watch: string;
      /** The app's id for this call; its `result` carries it. */
      call: string;
      action: string;
      row?: string;
      values?: ScreenValue[];
    };

/** `off`: the entry's feature switch is off on this server (`server-features.ts`). */
export type ScreenEndReason = "gone" | "off" | "unsupported";

export type ScreensServerMessage =
  | { type: "value"; watch: string; value: ScreenPage }
  | { type: "ops"; watch: string; ops: ConversationDocOp[] }
  /** The page's new value broke the vocabulary or its budget; the app keeps the last one. */
  | { type: "failed"; watch: string; message: string }
  | { type: "ended"; watch: string; reason: ScreenEndReason }
  | { type: "result"; call: string; ok: boolean; message?: string; nav?: ScreenNav };
