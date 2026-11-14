import { join } from "node:path";

import {
  GODOT_CAPTURE_MAX_BYTES,
  GODOT_LOG_RING_SIZE,
  GODOT_PACK_MAX_BYTES,
  GODOT_PANE_CLIENT_CAPABILITY,
  GODOT_RELEASES_KEPT,
} from "../src/godot/godot-protocol.js";
import type {
  GodotCapture,
  GodotCommandRequest,
  GodotCommandResult,
  GodotInputStep,
  GodotLinkPlayerMessage,
  GodotLinkServerMessage,
  GodotLogPage,
  GodotPackUploadResponse,
  GodotPlayer,
  GodotProject,
  GodotProjectConfig,
  GodotProjectDetail,
  GodotProjectList,
  GodotRelease,
  GodotReleaseRequest,
  GodotReleaseResponse,
  StreamAuthRenewMessage,
  StreamAuthRenewResultMessage,
} from "../src/types.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/godot.json`: one example of every Godot pane v1 body and link message, so the server
 * and the Apple app agree on the wire.
 *
 * Only this serializer defines the bytes. `godot-fixtures.test.ts` rebuilds it in memory and
 * compares against the committed file; `npm run protocol:fixtures:update` writes it. Apple
 * `GodotProtocolContractTests` decodes every example.
 */

export const GODOT_SNAPSHOT_FILE = join(PROTOCOL_DIR, "godot.json");

export const GODOT_FIXTURE_DESCRIPTION =
  "Godot pane v1: the HTTP bodies under /godot and every message on WS /godot/{projectId}/link, one example each (a discovered project with a release and a player, one with no build yet, a published project, every command and its answer, a timeout, the log ring, publishing, captures). Built by server/tests/godot-fixtures.ts; server/tests/godot-fixtures.test.ts fails when the committed bytes differ, and Apple GodotProtocolContractTests decodes every example.";

const t = (iso: string): number => Date.parse(iso);
const SHA_BASE = "4f3c2b1a09e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2";
const SHA_PATCH = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

const RELEASE: GodotRelease = {
  v: 1,
  seq: 7,
  createdAt: t("2026-11-14T18:02:11Z"),
  origin: "discovery",
  engine: { name: "godot", version: "4.7" },
  packs: [{ sha256: SHA_BASE, size: 18_734_112, format: "pck" }],
  entry: { scene: "res://main.tscn" },
  reload: "scene",
};

const PUBLISHED_RELEASE: GodotRelease = {
  v: 1,
  seq: 2,
  createdAt: t("2026-11-14T17:40:00Z"),
  origin: "publish",
  engine: { name: "godot", version: "4.7" },
  packs: [
    { sha256: SHA_BASE, size: 18_734_112, format: "pck" },
    { sha256: SHA_PATCH, size: 41_210, format: "zip" },
  ],
  entry: { scene: "res://levels/level_2.tscn", args: ["--level=2"] },
  reload: "scripts",
  label: "fix jump",
};

const PLAYER: GodotPlayer = {
  id: "p-3k9x",
  device: "Alex's iPad mini",
  runtimes: [{ engine: "godot", version: "4.7", formats: ["pck", "zip"] }],
  attachedAt: t("2026-11-14T17:58:00Z"),
  state: {
    phase: "running",
    release: 7,
    tier: "scene",
    fps: 60,
    viewport: { width: 744, height: 512, scale: 2 },
  },
  stateAt: t("2026-11-14T18:02:12Z"),
};

const TIDE: GodotProject = {
  id: "tide-3fa9c2b1",
  name: "Tide",
  engine: { name: "godot", version: "4.7" },
  source: {
    workspaceId: "ws-games",
    worktreeId: "main",
    checkout: "main",
    root: "games/tide",
    pack: "games/tide/build/tide.pck",
  },
  release: RELEASE,
  players: [PLAYER],
};

const NO_BUILD: GodotProject = {
  id: "sandbox-07be41d2",
  name: "Sandbox",
  engine: { name: "godot" },
  source: {
    workspaceId: "ws-games",
    worktreeId: "wt-feature",
    checkout: "feature/physics",
    root: "",
  },
  release: null,
  players: [],
};

const PUBLISHED: GodotProject = {
  id: "ci-runner",
  name: "CI build",
  engine: { name: "godot", version: "4.7" },
  release: PUBLISHED_RELEASE,
  players: [],
};

const projectList: GodotProjectList = { projects: [TIDE, NO_BUILD, PUBLISHED] };

const projectDetail: GodotProjectDetail = {
  ...TIDE,
  releases: [
    RELEASE,
    {
      ...RELEASE,
      seq: 6,
      createdAt: t("2026-11-14T17:51:30Z"),
      packs: [{ sha256: SHA_PATCH.replace(/a/g, "b"), size: 18_730_004, format: "pck" }],
    },
  ],
  logNext: 412,
};

const logPage: GodotLogPage = {
  entries: [
    {
      seq: 409,
      at: t("2026-11-14T18:02:11Z"),
      origin: "server",
      level: "info",
      message: "Release 7 from games/tide/build/tide.pck (17.9 MB)",
    },
    {
      seq: 410,
      at: t("2026-11-14T18:02:12Z"),
      origin: "player",
      playerId: "p-3k9x",
      level: "info",
      message: "level 1 ready",
    },
    {
      seq: 411,
      at: t("2026-11-14T18:02:14Z"),
      origin: "player",
      playerId: "p-3k9x",
      level: "error",
      message: "Invalid access to property or key 'velocity' on a base object of type 'Nil'.",
      source: { file: "res://player.gd", line: 42, function: "_physics_process" },
      backtrace: [
        { file: "res://player.gd", line: 42, function: "_physics_process" },
        { file: "res://main.gd", line: 12, function: "_ready" },
      ],
    },
  ],
  next: 412,
  dropped: 0,
};

const INPUT_STEPS: GodotInputStep[] = [
  { kind: "tap", at: { x: 0.5, y: 0.82 }, holdMs: 80 },
  { kind: "wait", ms: 300 },
  { kind: "drag", from: { x: 0.2, y: 0.5 }, to: { x: 0.8, y: 0.5 }, durationMs: 400 },
  { kind: "key", key: "Space", holdMs: 120 },
  { kind: "action", action: "jump", holdMs: 200, strength: 1 },
];

const commandRequests: GodotCommandRequest[] = [
  { command: { name: "capture" } },
  { command: { name: "input", steps: INPUT_STEPS }, player: "p-3k9x" },
  { command: { name: "reload", tier: "scripts" }, timeoutMs: 20_000 },
];

const ROOT_NODE = {
  path: "/root/Main",
  type: "Node2D",
  name: "Main",
  scene: "res://main.tscn",
  script: "res://main.gd",
  children: [
    {
      path: "/root/Main/Player",
      type: "CharacterBody2D",
      name: "Player",
      script: "res://player.gd",
      source: { file: "res://main.gd", line: 18, function: "_spawn_player" },
    },
  ],
};

const commandResults: GodotCommandResult[] = [
  {
    id: "c-11",
    name: "capture",
    playerId: "p-3k9x",
    ok: true,
    output: { captureId: "cap-11", mimeType: "image/png", width: 1488, height: 1024 },
    ms: 84,
  },
  {
    id: "c-12",
    name: "reload",
    playerId: "p-3k9x",
    ok: true,
    output: { release: 7, tier: "scripts", ms: 3 },
    ms: 41,
  },
  {
    id: "c-13",
    name: "input",
    playerId: "p-3k9x",
    ok: true,
    output: { steps: 5, ms: 1_120 },
    ms: 1_131,
  },
  {
    id: "c-14",
    name: "pick",
    playerId: "p-3k9x",
    ok: true,
    output: { node: ROOT_NODE.children[0] ?? null },
    ms: 6,
  },
  { id: "c-15", name: "tree", playerId: "p-3k9x", ok: true, output: { root: ROOT_NODE }, ms: 9 },
  {
    id: "c-16",
    name: "node",
    playerId: "p-3k9x",
    ok: true,
    output: {
      node: { path: "/root/Main/Player", type: "CharacterBody2D", name: "Player" },
      properties: { position: [312, 480], velocity: [0, -40.5], visible: true },
    },
    ms: 4,
  },
  {
    id: "c-17",
    name: "perf",
    playerId: "p-3k9x",
    ok: true,
    output: {
      fps: 60,
      frameMs: 16.7,
      processMs: 1.9,
      physicsMs: 0.6,
      drawCalls: 38,
      nodes: 412,
      memoryMB: 96.4,
    },
    ms: 3,
  },
  {
    id: "c-18",
    name: "pause",
    playerId: "p-3k9x",
    ok: true,
    output: { state: { ...PLAYER.state, phase: "paused" } },
    ms: 5,
  },
  { id: "c-19", name: "step", playerId: "p-3k9x", ok: true, output: { frames: 1 }, ms: 18 },
  {
    id: "c-20",
    name: "reload",
    playerId: "p-3k9x",
    ok: false,
    error: { code: "timeout", message: "The player did not answer within 30 s." },
    ms: 30_000,
  },
  {
    id: "c-21",
    name: "capture",
    ok: false,
    error: { code: "no_player", message: "No player is attached to tide-3fa9c2b1." },
    ms: 0,
  },
  {
    id: "c-22",
    name: "tree",
    playerId: "p-3k9x",
    ok: false,
    error: { code: "unsupported", message: "This player does not read the scene tree yet." },
    ms: 2,
  },
  {
    id: "c-0",
    name: "capture",
    ok: false,
    error: { code: "not_found", message: "No game pong-5e1d0a77 in this workspace." },
    ms: 0,
  },
];

const packUpload: GodotPackUploadResponse = {
  pack: { sha256: SHA_PATCH, size: 41_210, format: "zip" },
  existed: false,
};

const releaseRequest: GodotReleaseRequest = {
  v: 1,
  engine: { name: "godot", version: "4.7" },
  packs: [{ sha256: SHA_BASE }, { sha256: SHA_PATCH }],
  entry: { scene: "res://levels/level_2.tscn", args: ["--level=2"] },
  reload: "scripts",
  label: "fix jump",
  name: "CI build",
};

const releaseResponse: GodotReleaseResponse = {
  release: PUBLISHED_RELEASE,
  applied: {
    playerId: "p-3k9x",
    state: { phase: "running", release: 2, tier: "scripts", fps: 60 },
  },
};

const capture: GodotCapture = {
  id: "cap-11",
  mimeType: "image/png",
  size: 912_330,
  createdAt: t("2026-11-14T18:03:01Z"),
};

const projectConfig: GodotProjectConfig = {
  name: "Tide",
  pack: "build/tide.pck",
  entry: { scene: "res://main.tscn", args: ["--debug-collisions"] },
  reload: "scene",
};

const playerMessages: GodotLinkPlayerMessage[] = [
  {
    type: "attach",
    capabilities: [GODOT_PANE_CLIENT_CAPABILITY],
    device: "Alex's iPad mini",
    runtimes: [{ engine: "godot", version: "4.7", formats: ["pck", "zip"] }],
    state: { phase: "idle", viewport: { width: 744, height: 512, scale: 2 } },
  },
  { type: "state", state: { phase: "loading", release: 7 } },
  { type: "state", state: PLAYER.state },
  {
    type: "state",
    state: {
      phase: "relaunch",
      release: 6,
      tier: "restart",
      message: "Project settings changed; relaunch Oppi to apply release 7.",
    },
  },
  {
    type: "log",
    entries: logPage.entries.slice(1).map(({ level, message, source, backtrace }) => ({
      level,
      message,
      ...(source ? { source } : {}),
      ...(backtrace ? { backtrace } : {}),
    })),
  },
  {
    type: "result",
    id: "c-11",
    ok: true,
    output: { captureId: "cap-11", mimeType: "image/png", width: 1488, height: 1024 },
  },
  {
    type: "result",
    id: "c-22",
    ok: false,
    error: { code: "unsupported", message: "This player does not read the scene tree yet." },
  },
];

const serverMessages: GodotLinkServerMessage[] = [
  { type: "attached", role: "player", playerId: "p-3k9x", project: TIDE },
  { type: "attached", role: "follower", project: TIDE },
  { type: "release", release: RELEASE },
  {
    type: "command",
    id: "c-11",
    command: { name: "capture", captureId: "cap-11" },
    timeoutMs: 15_000,
  },
  {
    type: "command",
    id: "c-13",
    command: { name: "input", steps: INPUT_STEPS },
    timeoutMs: 11_120,
  },
  { type: "command", id: "c-12", command: { name: "reload", tier: "scripts" }, timeoutMs: 20_000 },
  { type: "command", id: "c-23", command: { name: "run", release: 7 }, timeoutMs: 30_000 },
  { type: "command", id: "c-24", command: { name: "stop" }, timeoutMs: 10_000 },
  { type: "command", id: "c-18", command: { name: "pause" }, timeoutMs: 5_000 },
  { type: "command", id: "c-25", command: { name: "resume" }, timeoutMs: 5_000 },
  { type: "command", id: "c-19", command: { name: "step", frames: 1 }, timeoutMs: 5_000 },
  {
    type: "command",
    id: "c-14",
    command: { name: "pick", at: { x: 0.42, y: 0.9 } },
    timeoutMs: 5_000,
  },
  {
    type: "command",
    id: "c-15",
    command: { name: "tree", path: "/root/Main", depth: 2 },
    timeoutMs: 10_000,
  },
  {
    type: "command",
    id: "c-16",
    command: { name: "node", path: "/root/Main/Player" },
    timeoutMs: 5_000,
  },
  { type: "command", id: "c-17", command: { name: "perf" }, timeoutMs: 5_000 },
  { type: "cancel", id: "c-20" },
  { type: "players", players: [PLAYER] },
  { type: "log", entries: logPage.entries },
  {
    type: "error",
    error: { code: "invalid", message: "The first message must be attach naming godot-pane:v1." },
  },
];

/** `auth_renew` on a link, as on every device stream, and the two shapes of its answer. */
const authRenew: {
  request: StreamAuthRenewMessage;
  results: StreamAuthRenewResultMessage[];
} = {
  request: { type: "auth_renew", token: "at_example-access-token" },
  results: [
    { type: "auth_renew_result", ok: true, expiresAt: t("2026-11-14T18:12:00Z") },
    { type: "auth_renew_result", ok: false, reason: "wrong_device" },
  ],
};

export function buildGodotFixture(): Record<string, unknown> {
  return {
    _meta: { description: GODOT_FIXTURE_DESCRIPTION, source: "server/src/types/godot.ts" },
    capability: GODOT_PANE_CLIENT_CAPABILITY,
    serverInfo: { godot: { version: 1 } },
    limits: {
      releasesKept: GODOT_RELEASES_KEPT,
      logRingSize: GODOT_LOG_RING_SIZE,
      packMaxBytes: GODOT_PACK_MAX_BYTES,
      captureMaxBytes: GODOT_CAPTURE_MAX_BYTES,
    },
    projectList,
    projectDetail,
    logPage,
    commandRequests,
    commandResults,
    packUpload,
    releaseRequest,
    releaseResponse,
    capture,
    projectConfig,
    link: { player: playerMessages, server: serverMessages, authRenew },
  };
}

export function serializeGodotFixture(): string {
  return JSON.stringify(buildGodotFixture(), null, 2) + "\n";
}
