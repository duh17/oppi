// Pins: saved places, one list per server (`<dataDir>/settings/pins.json`): File Browser folders
// and files, and sessions. A pin names a place the app can already open; it grants no access of
// its own.

/**
 * Where a pin points. A workspace pin is a path in the workspace's main checkout (`""` is its
 * root); a host pin is a path in the server's home folder, written `~` or `~/…`; a session pin
 * names one session by id.
 */
export type PinTarget =
  | { origin: "workspace"; workspaceId: string; path: string }
  | { origin: "host"; path: string }
  | { origin: "session"; sessionId: string };

export interface Pin {
  /** `pin_` and 12 base64url characters. */
  id: string;
  target: PinTarget;
  /** What the target was when it was pinned; a session target is always `session`. */
  kind: "directory" | "file" | "session";
  /** The name shown instead of the target's own; absent shows the file or folder name. */
  label?: string;
  createdAt: number;
}

/**
 * What a list read found at the target, checked once per read: `missing` when nothing (or not the
 * pinned kind) is there, or the session was deleted; `unreadable` when the server may not read it,
 * `workspaceMissing` when the workspace is gone, and `unknown` when the check took too long (a
 * sleeping disk).
 */
export type PinStatus = "ok" | "missing" | "unreadable" | "workspaceMissing" | "unknown";

export interface PinWithStatus extends Pin {
  status: PinStatus;
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
