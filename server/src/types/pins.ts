// Pins: saved pane routes, one list per server (`<dataDir>/settings/pins.json`). A pin names
// anything a pane can show, in the route shape `oppi://` links decode to (`protocol/links.json`),
// and the app opens it the way it opens that link. A pin grants no access of its own.

/**
 * What a pin opens: a pane route without its server (the list is the server's). Every field a
 * kind has is present, `null` where the link leaves it out.
 *
 * - `file` and `files` paths are relative to the workspace's checkout (a worktree's when
 *   `worktree` names one), to a session's copy, or, for `origin: "host"`, written `~/…` in the
 *   server's home folder; a `files` path of `null` is the root (the home folder for `host`).
 * - `browser` URLs are http or https, at most 2 KiB, with no user-info, and not loopback.
 * - `godot` names a Godot project id (`GodotProject.id`), stable for the same project folder of
 *   the same checkout.
 * - Git and commit routes are links only; a pin never names them.
 */
export type PinRoute =
  | { kind: "sessions"; workspace: string | null }
  | { kind: "session"; id: string }
  | { kind: "thread"; id: string }
  | {
      kind: "file";
      origin: "workspace";
      workspace: string;
      worktree: string | null;
      path: string;
      line: number | null;
    }
  | { kind: "file"; origin: "host"; path: string; line: number | null }
  | { kind: "file"; origin: "session"; session: string; path: string; line: number | null }
  | { kind: "files"; workspace: string; path: string | null }
  | { kind: "files"; origin: "host"; path: string | null }
  | { kind: "panel"; session: string; id: string }
  | { kind: "browser"; url: string }
  | { kind: "godot"; project: string };

export interface Pin {
  /** `pin_` and 12 base64url characters. */
  id: string;
  target: PinRoute;
  /** The name shown instead of the target's own; absent shows the target's own name. */
  label?: string;
  createdAt: number;
}

/**
 * What a list read found at the target, checked once per read where the server can tell:
 * `missing` when a session, file, folder, or game is gone (or a file became a folder);
 * `unreadable` when the server may not read it; `workspaceMissing` when its workspace is gone;
 * `unknown` when the check took too long (a sleeping disk). A target the server does not check
 * (a web page, a worktree's file) reads `ok`.
 */
export type PinStatus = "ok" | "missing" | "unreadable" | "workspaceMissing" | "unknown";

export interface PinWithStatus extends Pin {
  status: PinStatus;
  /** A game pin's game name as the server knows it now; absent for other pins and a gone game. */
  name?: string;
}

/** `GET /pins` and `PUT /pins`; also the `current` of a 409 `revision_conflict`. */
export interface PinsResponse {
  revision: number;
  pins: PinWithStatus[];
}

/** `POST /pins`: the list after the add, and the id of the added (or already saved) pin. */
export interface PinAddResponse extends PinsResponse {
  pinId: string;
}
