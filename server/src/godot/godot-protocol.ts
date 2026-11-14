// Fixed limits and names of the Godot pane protocol v1 (`server/src/types/godot.ts`). The Apple app
// reads the same values from `protocol/godot.json`.

/** What a player names in `attach.capabilities`; the server serves v1 only to a link that does. */
export const GODOT_PANE_CLIENT_CAPABILITY = "godot-pane:v1";

/** `ServerInfo.capabilities.godot`. */
export const GODOT_CAPABILITY_VERSION = 1;

/** Releases kept per project; their packs stay, every other pack is deleted. */
export const GODOT_RELEASES_KEPT = 5;
/** Entries in a project's log ring. */
export const GODOT_LOG_RING_SIZE = 2_000;
/** Largest pack `PUT .../packs/{sha256}` takes. */
export const GODOT_PACK_MAX_BYTES = 512 * 1024 * 1024;
/** Largest capture `PUT .../captures/{id}` takes. */
export const GODOT_CAPTURE_MAX_BYTES = 20 * 1024 * 1024;
/** Captures kept per project, newest first. */
export const GODOT_CAPTURES_KEPT = 20;
/** Longest a command waits for its answer. */
export const GODOT_COMMAND_MAX_TIMEOUT_MS = 120_000;
/** Longest `wait=first-frame` holds a publish. */
export const GODOT_FIRST_FRAME_WAIT_MS = 30_000;
/** Most log entries one `log` message or one `GET .../logs` page carries. */
export const GODOT_LOG_PAGE_MAX = 500;
/** Longest log message kept; longer ones are cut. */
export const GODOT_LOG_MESSAGE_MAX_CHARS = 8_000;
/** Most steps one `input` command takes. */
export const GODOT_INPUT_MAX_STEPS = 200;

/** A publisher-chosen project id; discovered ids (`<slug>-<8 hex>`) match it too. */
export const GODOT_PROJECT_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
/** A capture id. */
export const GODOT_CAPTURE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
/** A pack id: lowercase hex SHA-256. */
export const GODOT_PACK_SHA256 = /^[0-9a-f]{64}$/;

/** Default answer time per command; `input` adds the time its steps take. */
export const GODOT_COMMAND_TIMEOUT_MS = {
  reload: 30_000,
  run: 30_000,
  stop: 10_000,
  pause: 5_000,
  resume: 5_000,
  step: 5_000,
  capture: 15_000,
  input: 10_000,
  pick: 5_000,
  tree: 10_000,
  node: 5_000,
  perf: 5_000,
} as const;
