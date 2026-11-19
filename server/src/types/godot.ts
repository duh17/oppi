// Godot pane v1 (`ServerInfo.capabilities.godot`, version 1): the games the server finds in
// workspaces or is sent, their releases, and the link between players (the app's Godot pane) and
// controllers (agent tools, HTTP callers). The server stores, verifies, and announces; it never
// runs an engine. Only `engine.name` names an engine, and v1 knows one: `godot`.
//
// Fixtures: `protocol/godot.json`. Guide: `docs/godot.md`. Apple: `OppiCore/Models/Game*.swift`.

/** The engines v1 knows. A second engine adds a name here and changes no route or message. */
export type GodotEngineName = "godot";

export interface GodotEngine {
  name: GodotEngineName;
  /** The engine version the project targets, as its project file states it (`4.7`). */
  version?: string;
}

/** Pack formats, by their first bytes: `GDPC` (Godot's PCK) or a ZIP local header. */
export type GodotPackFormat = "pck" | "zip";

/** One pack the server stores, content-addressed. */
export interface GodotPack {
  /** Lowercase hex SHA-256 of the bytes; also the pack's id and its HTTP ETag. */
  sha256: string;
  size: number;
  format: GodotPackFormat;
}

/** Where a game starts. Opaque to the server; the player hands both to the engine. */
export interface GodotEntry {
  /** An engine path such as `res://main.tscn`; absent means the project's main scene. */
  scene?: string;
  /** Extra engine arguments. */
  args?: string[];
}

/**
 * How a player applies a release, fastest first. A release carries it as a hint; the player
 * decides by what changed and reports the tier it used (`GodotPlayerState.tier`).
 *
 * - `scripts`: reload the changed scripts in the running game. Everything is kept.
 * - `scene`: mount the new packs into the running engine and reload the current scene.
 *   Autoloads are kept; the scene starts over.
 * - `restart`: the change needs a fresh engine (project settings, autoloads, the class
 *   registry): the player ends the game's engine and starts it again on the release.
 */
export type GodotReloadTier = "scripts" | "scene" | "restart";

/** A playable build of one project: what a player loads. Releases are immutable. */
export interface GodotRelease {
  v: 1;
  /** Per project, from 1, never reused; the release's id. */
  seq: number;
  createdAt: number;
  /** `discovery`: a pack the server found in a workspace. `publish`: `POST .../releases`. */
  origin: "discovery" | "publish";
  engine: GodotEngine;
  /** Base first, then patches; each later pack replaces files in the earlier ones. */
  packs: GodotPack[];
  entry?: GodotEntry;
  reload: GodotReloadTier;
  /** A short note from the publisher (`fix jump`). */
  label?: string;
}

/** Where a discovered project lives. Paths are relative to the checkout, `/`-separated. */
export interface GodotProjectSource {
  workspaceId: string;
  /** `main` for the workspace's own checkout, else the worktree's id. */
  worktreeId: string;
  /** The checkout's display name. */
  checkout: string;
  /** The folder holding the project file; `""` is the checkout itself. */
  root: string;
  /** The pack discovery watches: the newest `build/*.pck`, or `oppi-godot.json`'s `pack`. */
  pack?: string;
}

/**
 * A game the server knows: a project folder in a workspace checkout (one with Godot's
 * `project.godot`), or a project only a publish created.
 */
export interface GodotProject {
  /**
   * Stable and URL-safe: `<folder-slug>-<8 hex>` for a discovered project, or the id a
   * publisher chose (`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`).
   */
  id: string;
  name: string;
  engine: GodotEngine;
  /** Absent for a project only a publish created. */
  source?: GodotProjectSource;
  /** The current release; null while there is no build yet. */
  release: GodotRelease | null;
  /** Players attached now, newest first. */
  players: GodotPlayer[];
}

/** `GET /godot`. */
export interface GodotProjectList {
  projects: GodotProject[];
}

/** `GET /godot/{projectId}`. */
export interface GodotProjectDetail extends GodotProject {
  /** The releases the server keeps (at most five), newest first. */
  releases: GodotRelease[];
  /** `since` for `GET .../logs` to read only what comes next. */
  logNext: number;
}

// ---------------------------------------------------------------------------------------------
// Players
// ---------------------------------------------------------------------------------------------

/** An engine build a player carries. */
export interface GodotRuntimeInfo {
  engine: GodotEngineName;
  version?: string;
  formats: GodotPackFormat[];
}

/** The game view in points; `scale` is pixels per point. */
export interface GodotViewport {
  width: number;
  height: number;
  scale?: number;
}

/**
 * - `idle`: attached, nothing loaded. `loading`: fetching or mounting packs.
 * - `running`, `paused`: a release is live.
 * - `error`: the release failed to load or apply; `message` says why.
 */
export type GodotPhase = "idle" | "loading" | "running" | "paused" | "error";

export interface GodotPlayerState {
  phase: GodotPhase;
  /** The release loaded (`seq`). */
  release?: number;
  /** The tier the player used to apply `release`. */
  tier?: GodotReloadTier;
  fps?: number;
  viewport?: GodotViewport;
  message?: string;
}

/** A player as controllers see it. */
export interface GodotPlayer {
  /** Server-assigned for the link's lifetime; a command may name it. */
  id: string;
  /** The device's display name. */
  device?: string;
  runtimes: GodotRuntimeInfo[];
  attachedAt: number;
  state: GodotPlayerState;
  stateAt: number;
}

// ---------------------------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------------------------

export type GodotLogLevel = "debug" | "info" | "warn" | "error";

/** A place in game code. `file` is an engine path (`res://player.gd`). */
export interface GodotSourceLocation {
  file: string;
  line?: number;
  function?: string;
}

/** One log line as a player sends it. */
export interface GodotLogInput {
  level: GodotLogLevel;
  message: string;
  /** Where it was raised. */
  source?: GodotSourceLocation;
  /** Script frames, innermost first. */
  backtrace?: GodotSourceLocation[];
  /** The release the game was running when it logged the line. */
  release?: number;
}

/** One entry of a project's log ring (2,000 entries). */
export interface GodotLogEntry extends GodotLogInput {
  /** Per project, increasing; `GET .../logs?since=` reads entries after it. */
  seq: number;
  /** When the server received it. */
  at: number;
  /** `server` entries record releases, players attaching and leaving, and command timeouts. */
  origin: "player" | "server";
  playerId?: string;
}

/** `GET /godot/{projectId}/logs?since=&limit=&level=`. */
export interface GodotLogPage {
  entries: GodotLogEntry[];
  /** `since` for the next read. */
  next: number;
  /** Entries after `since` the ring no longer holds. */
  dropped: number;
}

// ---------------------------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------------------------

/** A point in the game view as fractions of its size, from the top-left: (0.5, 0.5) is the middle. */
export interface GodotPoint {
  x: number;
  y: number;
}

/**
 * One input step; a player runs steps in order, each after the last ends. `key` is a key name
 * (`Space`, `Enter`, `Escape`, `Left`, `A`, `F1`); `action` is an input action the project
 * defines (Godot's input map).
 */
export type GodotInputStep =
  | { kind: "tap"; at: GodotPoint; holdMs?: number }
  | { kind: "drag"; from: GodotPoint; to: GodotPoint; durationMs?: number }
  | { kind: "key"; key: string; holdMs?: number }
  | { kind: "action"; action: string; holdMs?: number; strength?: number }
  | { kind: "wait"; ms: number };

/** What the server sends a player. */
export type GodotCommand =
  /** Apply the current release again; `tier` asks for one (the player may refuse a faster one). */
  | { name: "reload"; tier?: GodotReloadTier }
  /** Load and run a release (the current one by default). */
  | { name: "run"; release?: number }
  | { name: "stop" }
  | { name: "pause" }
  | { name: "resume" }
  /** Advance a paused game by `frames` (default 1). */
  | { name: "step"; frames?: number }
  /** Take a PNG of the game view, upload it to `PUT .../captures/{captureId}`, then answer. */
  | { name: "capture"; captureId: string; maxSize?: number }
  | { name: "input"; steps: GodotInputStep[] }
  /** The node drawn at a point. */
  | { name: "pick"; at: GodotPoint }
  /** The scene tree under `path` (the root by default), `depth` levels deep. */
  | { name: "tree"; path?: string; depth?: number }
  | { name: "node"; path: string }
  | { name: "perf" };

export type GodotCommandName = GodotCommand["name"];

/** A command as a controller asks for it: the server names a capture itself. */
export type GodotCommandInput =
  Exclude<GodotCommand, { name: "capture" }> | { name: "capture"; maxSize?: number };

/** `POST /godot/{projectId}/commands`. */
export interface GodotCommandRequest {
  command: GodotCommandInput;
  /** A player id; default: the player that reported most recently. */
  player?: string;
  /** Default per command (`input` adds its steps' time); at most 120,000. */
  timeoutMs?: number;
}

export type GodotErrorCode =
  /** No player is attached, or the one named is gone. */
  | "no_player"
  /** The player did not answer in time; it was sent `cancel`. */
  | "timeout"
  /** The player left before it answered. */
  | "player_left"
  /** The player or its engine does not do this. */
  | "unsupported"
  /** The player tried and failed. */
  | "failed"
  /** The request is malformed. */
  | "invalid"
  /** No such game, or not one the caller may reach (an agent sees only its workspace's). */
  | "not_found";

export interface GodotError {
  code: GodotErrorCode;
  message: string;
}

/** A command's answer, as a controller receives it. */
export interface GodotCommandResult {
  id: string;
  name: GodotCommandName;
  playerId?: string;
  ok: boolean;
  /** Present when `ok`, if the command has an answer (see `GodotCommandOutput`). */
  output?: GodotCommandOutput;
  /** Present when not `ok`. */
  error?: GodotError;
  ms: number;
}

/** A node in the running game. */
export interface GodotNode {
  /** Its path in the scene tree (`/root/Main/Player`). */
  path: string;
  /** Its engine class (`CharacterBody2D`). */
  type: string;
  name?: string;
  /** Its script. */
  script?: string;
  /** The scene file it was instanced from. */
  scene?: string;
  /** Where code created it or last moved it, when the player watched. */
  source?: GodotSourceLocation;
  children?: GodotNode[];
}

/** Each command's answer, by command name. */
export interface GodotCommandOutputs {
  reload: { release: number; tier: GodotReloadTier; ms?: number };
  run: { state: GodotPlayerState };
  stop: { state: GodotPlayerState };
  pause: { state: GodotPlayerState };
  resume: { state: GodotPlayerState };
  step: { frames: number };
  capture: {
    captureId: string;
    mimeType: "image/png" | "image/jpeg";
    width: number;
    height: number;
  };
  input: { steps: number; ms: number };
  pick: { node: GodotNode | null };
  tree: { root: GodotNode };
  node: { node: GodotNode; properties?: Record<string, unknown> };
  perf: {
    fps: number;
    frameMs?: number;
    processMs?: number;
    physicsMs?: number;
    drawCalls?: number;
    nodes?: number;
    memoryMB?: number;
  };
}

export type GodotCommandOutput = GodotCommandOutputs[GodotCommandName];

// ---------------------------------------------------------------------------------------------
// Publishing and captures
// ---------------------------------------------------------------------------------------------

/** `PUT /godot/{projectId}/packs/{sha256}`: the pack, and whether the server already had it. */
export interface GodotPackUploadResponse {
  pack: GodotPack;
  existed: boolean;
}

/** `POST /godot/{projectId}/releases`: every pack must be uploaded first. */
export interface GodotReleaseRequest {
  v: 1;
  engine: GodotEngine;
  packs: Array<{ sha256: string }>;
  entry?: GodotEntry;
  /** Default `scene`. */
  reload?: GodotReloadTier;
  label?: string;
  /** The project's display name, when this publish creates the project. */
  name?: string;
}

/** `POST /godot/{projectId}/releases[?wait=first-frame]`. */
export interface GodotReleaseResponse {
  release: GodotRelease;
  /**
   * With `wait=first-frame`: the first player to report this release running, paused, or in
   * error; null when none did within 30 s.
   */
  applied?: { playerId: string; state: GodotPlayerState } | null;
}

/** `PUT /godot/{projectId}/captures/{captureId}`. */
export interface GodotCapture {
  id: string;
  mimeType: "image/png" | "image/jpeg";
  size: number;
  createdAt: number;
}

/**
 * `oppi-godot.json` beside `project.godot`, all optional: the display name, the pack to watch
 * (relative to the project folder; it must stay inside the checkout), how the game starts, and
 * the reload hint for its releases.
 */
export interface GodotProjectConfig {
  name?: string;
  pack?: string;
  entry?: GodotEntry;
  reload?: GodotReloadTier;
}

// ---------------------------------------------------------------------------------------------
// The link: `WS /godot/{projectId}/link?role=player|follower`
// ---------------------------------------------------------------------------------------------

/**
 * What a player sends. `attach` comes first and names `godot-pane:v1` in `capabilities`; a link
 * that sends anything else first, or leaves it out, is closed.
 *
 * Any link, player or follower, also takes `auth_renew` (`StreamAuthRenewMessage`) at any time,
 * as every device stream does: a link opened with an expiring device token closes with
 * `4001 auth_expired` 30 s after that token expires unless it renews first. The answer is
 * `auth_renew_result` (`StreamAuthRenewResultMessage`), outside the messages below.
 */
export type GodotLinkPlayerMessage =
  | {
      type: "attach";
      capabilities: string[];
      device?: string;
      runtimes: GodotRuntimeInfo[];
      state?: GodotPlayerState;
    }
  | { type: "state"; state: GodotPlayerState }
  | { type: "log"; entries: GodotLogInput[] }
  | { type: "result"; id: string; ok: boolean; output?: GodotCommandOutput; error?: GodotError };

/**
 * What the server sends. A player gets `attached`, `release`, `command`, and `cancel`; a
 * follower gets `attached`, `release`, `players`, and `log`. `error` precedes a close.
 */
export type GodotLinkServerMessage =
  | { type: "attached"; role: "player" | "follower"; playerId?: string; project: GodotProject }
  | { type: "release"; release: GodotRelease }
  | { type: "command"; id: string; command: GodotCommand; timeoutMs: number }
  /** The command timed out here; stop working on it. */
  | { type: "cancel"; id: string }
  | { type: "players"; players: GodotPlayer[] }
  | { type: "log"; entries: GodotLogEntry[] }
  | { type: "error"; error: GodotError };
