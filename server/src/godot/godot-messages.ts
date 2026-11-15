/**
 * Narrowing of untrusted game input: what a player sends on its link, and the commands and
 * releases controllers ask for. Each parser returns a value of the protocol type or a reason.
 */
import { asRecord } from "../json-shape.js";
import type {
  GodotCommandInput,
  GodotCommandOutput,
  GodotEntry,
  GodotError,
  GodotErrorCode,
  GodotInputStep,
  GodotLogInput,
  GodotLogLevel,
  GodotPhase,
  GodotPlayerState,
  GodotPoint,
  GodotReleaseRequest,
  GodotReloadTier,
  GodotRuntimeInfo,
  GodotSourceLocation,
  GodotViewport,
} from "../types.js";
import {
  GODOT_COMMAND_MAX_TIMEOUT_MS,
  GODOT_COMMAND_TIMEOUT_MS,
  GODOT_INPUT_MAX_STEPS,
  GODOT_LOG_MESSAGE_MAX_CHARS,
  GODOT_LOG_PAGE_MAX,
  GODOT_PACK_SHA256,
} from "./godot-protocol.js";

type Parsed<T> = { ok: true; value: T } | { ok: false; reason: string };

const ok = <T>(value: T): Parsed<T> => ({ ok: true, value });
const fail = <T>(reason: string): Parsed<T> => ({ ok: false, reason });

const PHASES: ReadonlySet<string> = new Set(["idle", "loading", "running", "paused", "error"]);
const TIERS: ReadonlySet<string> = new Set(["scripts", "scene", "restart"]);
const LEVELS: ReadonlySet<string> = new Set(["debug", "info", "warn", "error"]);
const ERROR_CODES: ReadonlySet<string> = new Set([
  "no_player",
  "timeout",
  "player_left",
  "unsupported",
  "failed",
  "invalid",
  "not_found",
]);
const MAX_STEP_MS = 60_000;
const MAX_BACKTRACE = 32;

export function isReloadTier(value: unknown): value is GodotReloadTier {
  return typeof value === "string" && TIERS.has(value);
}

function text(value: unknown, max: number): string | undefined {
  return typeof value === "string" ? value.slice(0, max) : undefined;
}

function finite(value: unknown, min: number, max: number): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= min && value <= max
    ? value
    : undefined;
}

function wholeNumber(value: unknown, min: number, max: number): number | undefined {
  const n = finite(value, min, max);
  return n !== undefined && Number.isInteger(n) ? n : undefined;
}

/** `{ scene?, args? }`, or undefined when the shape is wrong. */
export function parseGodotEntry(value: unknown): GodotEntry | undefined {
  const raw = asRecord(value);
  if (!raw) return undefined;
  const entry: GodotEntry = {};
  if (raw.scene !== undefined) {
    if (typeof raw.scene !== "string" || raw.scene.length > 512) return undefined;
    entry.scene = raw.scene;
  }
  if (raw.args !== undefined) {
    if (
      !Array.isArray(raw.args) ||
      raw.args.length > 64 ||
      !raw.args.every((arg) => typeof arg === "string" && arg.length <= 512)
    )
      return undefined;
    entry.args = raw.args as string[];
  }
  return entry;
}

// --- From a player -----------------------------------------------------------------------------

export function parsePlayerState(value: unknown): GodotPlayerState | undefined {
  const raw = asRecord(value);
  if (!raw || typeof raw.phase !== "string" || !PHASES.has(raw.phase)) return undefined;
  const state: GodotPlayerState = { phase: raw.phase as GodotPhase };
  const release = wholeNumber(raw.release, 1, Number.MAX_SAFE_INTEGER);
  if (release !== undefined) state.release = release;
  if (isReloadTier(raw.tier)) state.tier = raw.tier;
  const fps = finite(raw.fps, 0, 1_000);
  if (fps !== undefined) state.fps = fps;
  const viewport = parseViewport(raw.viewport);
  if (viewport) state.viewport = viewport;
  const message = text(raw.message, 2_000);
  if (message) state.message = message;
  return state;
}

function parseViewport(value: unknown): GodotViewport | undefined {
  const raw = asRecord(value);
  const width = finite(raw?.width, 1, 100_000);
  const height = finite(raw?.height, 1, 100_000);
  if (width === undefined || height === undefined) return undefined;
  const scale = finite(raw?.scale, 0.1, 10);
  return { width, height, ...(scale !== undefined ? { scale } : {}) };
}

export function parseRuntimes(value: unknown): GodotRuntimeInfo[] {
  if (!Array.isArray(value)) return [];
  const runtimes: GodotRuntimeInfo[] = [];
  for (const item of value.slice(0, 8)) {
    const raw = asRecord(item);
    if (raw?.engine !== "godot") continue;
    const formats = Array.isArray(raw.formats)
      ? raw.formats.filter((f): f is "pck" | "zip" => f === "pck" || f === "zip")
      : [];
    const version = text(raw.version, 32);
    runtimes.push({ engine: "godot", ...(version ? { version } : {}), formats });
  }
  return runtimes;
}

function parseSource(value: unknown): GodotSourceLocation | undefined {
  const raw = asRecord(value);
  const file = text(raw?.file, 1_024);
  if (!raw || !file) return undefined;
  const line = wholeNumber(raw.line, 0, 10_000_000);
  const fn = text(raw.function, 256);
  return { file, ...(line !== undefined ? { line } : {}), ...(fn ? { function: fn } : {}) };
}

/** A player's log batch; malformed entries are dropped, long messages cut. */
export function parseLogInputs(value: unknown): GodotLogInput[] {
  if (!Array.isArray(value)) return [];
  const entries: GodotLogInput[] = [];
  for (const item of value.slice(0, GODOT_LOG_PAGE_MAX)) {
    const raw = asRecord(item);
    if (!raw || typeof raw.message !== "string") continue;
    const level: GodotLogLevel =
      typeof raw.level === "string" && LEVELS.has(raw.level)
        ? (raw.level as GodotLogLevel)
        : "info";
    const entry: GodotLogInput = {
      level,
      message: raw.message.slice(0, GODOT_LOG_MESSAGE_MAX_CHARS),
    };
    const source = parseSource(raw.source);
    if (source) entry.source = source;
    if (Array.isArray(raw.backtrace)) {
      const frames = raw.backtrace
        .slice(0, MAX_BACKTRACE)
        .map(parseSource)
        .filter((f): f is GodotSourceLocation => f !== undefined);
      if (frames.length > 0) entry.backtrace = frames;
    }
    entries.push(entry);
  }
  return entries;
}

/** A player's answer to a command. */
export function parsePlayerResult(
  raw: Record<string, unknown>,
):
  | { id: string; ok: true; output?: GodotCommandOutput }
  | { id: string; ok: false; error: GodotError }
  | undefined {
  if (typeof raw.id !== "string" || typeof raw.ok !== "boolean") return undefined;
  if (raw.ok) {
    const output = asRecord(raw.output);
    return {
      id: raw.id,
      ok: true,
      ...(output ? { output: output as unknown as GodotCommandOutput } : {}),
    };
  }
  const error = asRecord(raw.error);
  const code: GodotErrorCode =
    typeof error?.code === "string" && ERROR_CODES.has(error.code)
      ? (error.code as GodotErrorCode)
      : "failed";
  return {
    id: raw.id,
    ok: false,
    error: { code, message: text(error?.message, 2_000) || "The player could not do it." },
  };
}

// --- From a controller -------------------------------------------------------------------------

function parsePoint(value: unknown): GodotPoint | undefined {
  const raw = asRecord(value);
  const x = finite(raw?.x, 0, 1);
  const y = finite(raw?.y, 0, 1);
  return x === undefined || y === undefined ? undefined : { x, y };
}

function optionalMs(raw: Record<string, unknown>, key: string): Parsed<number | undefined> {
  if (raw[key] === undefined) return ok(undefined);
  const ms = finite(raw[key], 0, MAX_STEP_MS);
  return ms === undefined ? fail(`${key} must be 0 to ${MAX_STEP_MS} ms`) : ok(ms);
}

function parseStep(value: unknown, index: number): Parsed<GodotInputStep> {
  const raw = asRecord(value);
  const at = `steps[${index}]`;
  if (!raw) return fail(`${at} must be an object`);
  const hold = optionalMs(raw, "holdMs");
  if (!hold.ok) return fail(`${at}: ${hold.reason}`);
  const holdMs = hold.value !== undefined ? { holdMs: hold.value } : {};
  switch (raw.kind) {
    case "tap": {
      const point = parsePoint(raw.at);
      if (!point) return fail(`${at}.at must be { x, y }, each 0 to 1`);
      return ok({ kind: "tap", at: point, ...holdMs });
    }
    case "drag": {
      const from = parsePoint(raw.from);
      const to = parsePoint(raw.to);
      if (!from || !to) return fail(`${at}: from and to must be { x, y }, each 0 to 1`);
      const duration = optionalMs(raw, "durationMs");
      if (!duration.ok) return fail(`${at}: ${duration.reason}`);
      return ok({
        kind: "drag",
        from,
        to,
        ...(duration.value !== undefined ? { durationMs: duration.value } : {}),
      });
    }
    case "key": {
      const key = text(raw.key, 32);
      if (!key) return fail(`${at}.key must name a key`);
      return ok({ kind: "key", key, ...holdMs });
    }
    case "action": {
      const action = text(raw.action, 128);
      if (!action) return fail(`${at}.action must name an input action`);
      const strength = raw.strength === undefined ? undefined : finite(raw.strength, 0, 1);
      if (raw.strength !== undefined && strength === undefined)
        return fail(`${at}.strength must be 0 to 1`);
      return ok({
        kind: "action",
        action,
        ...holdMs,
        ...(strength !== undefined ? { strength } : {}),
      });
    }
    case "wait": {
      const ms = finite(raw.ms, 0, MAX_STEP_MS);
      if (ms === undefined) return fail(`${at}.ms must be 0 to ${MAX_STEP_MS}`);
      return ok({ kind: "wait", ms });
    }
    default:
      return fail(`${at}.kind must be tap, drag, key, action, or wait`);
  }
}

/** How long a step takes, for the command's timeout. */
function stepMs(step: GodotInputStep): number {
  switch (step.kind) {
    case "wait":
      return step.ms;
    case "drag":
      return step.durationMs ?? 250;
    default:
      return step.holdMs ?? 50;
  }
}

/** A controller's command, checked. */
export function parseCommandInput(value: unknown): Parsed<GodotCommandInput> {
  const raw = asRecord(value);
  if (!raw || typeof raw.name !== "string") return fail("command.name is required");
  switch (raw.name) {
    case "reload":
      if (raw.tier !== undefined && !isReloadTier(raw.tier))
        return fail("tier must be scripts, scene, or restart");
      return ok({ name: "reload", ...(isReloadTier(raw.tier) ? { tier: raw.tier } : {}) });
    case "run": {
      const release = wholeNumber(raw.release, 1, Number.MAX_SAFE_INTEGER);
      if (raw.release !== undefined && release === undefined)
        return fail("release must be a release number");
      return ok({ name: "run", ...(release !== undefined ? { release } : {}) });
    }
    case "stop":
    case "pause":
    case "resume":
    case "perf":
      return ok({ name: raw.name });
    case "step": {
      const frames = raw.frames === undefined ? 1 : wholeNumber(raw.frames, 1, 600);
      if (frames === undefined) return fail("frames must be 1 to 600");
      return ok({ name: "step", frames });
    }
    case "capture": {
      const maxSize = wholeNumber(raw.maxSize, 64, 8_192);
      if (raw.maxSize !== undefined && maxSize === undefined)
        return fail("maxSize must be 64 to 8192 pixels");
      return ok({ name: "capture", ...(maxSize !== undefined ? { maxSize } : {}) });
    }
    case "input": {
      if (!Array.isArray(raw.steps) || raw.steps.length === 0)
        return fail("steps must be a non-empty list");
      if (raw.steps.length > GODOT_INPUT_MAX_STEPS)
        return fail(`At most ${GODOT_INPUT_MAX_STEPS} steps`);
      const steps: GodotInputStep[] = [];
      for (const [index, item] of raw.steps.entries()) {
        const step = parseStep(item, index);
        if (!step.ok) return fail(step.reason);
        steps.push(step.value);
      }
      // The steps must fit the longest wait for an answer, with the command's own margin.
      const total = steps.reduce((sum, step) => sum + stepMs(step), 0);
      const most = GODOT_COMMAND_MAX_TIMEOUT_MS - GODOT_COMMAND_TIMEOUT_MS.input;
      if (total > most)
        return fail(`The steps take ${Math.ceil(total / 1000)} s; at most ${most / 1000} s`);
      return ok({ name: "input", steps });
    }
    case "pick": {
      const at = parsePoint(raw.at);
      return at ? ok({ name: "pick", at }) : fail("at must be { x, y }, each 0 to 1");
    }
    case "tree": {
      const depth = raw.depth === undefined ? undefined : wholeNumber(raw.depth, 1, 32);
      if (raw.depth !== undefined && depth === undefined) return fail("depth must be 1 to 32");
      const path = text(raw.path, 1_024);
      return ok({
        name: "tree",
        ...(path ? { path } : {}),
        ...(depth !== undefined ? { depth } : {}),
      });
    }
    case "node": {
      const path = text(raw.path, 1_024);
      return path ? ok({ name: "node", path }) : fail("path must name a node");
    }
    default:
      return fail(`Unknown command ${JSON.stringify(raw.name).slice(0, 40)}`);
  }
}

/** A publisher's release, checked; whether its packs are stored is the caller's to check. */
export function parseReleaseRequest(value: unknown): Parsed<GodotReleaseRequest> {
  const raw = asRecord(value);
  if (!raw || raw.v !== 1) return fail("v must be 1");
  const engine = asRecord(raw.engine);
  if (engine?.name !== "godot") return fail("engine.name must be godot");
  if (!Array.isArray(raw.packs) || raw.packs.length === 0 || raw.packs.length > 16)
    return fail("packs must list 1 to 16 packs, base first");
  const packs: GodotReleaseRequest["packs"] = [];
  for (const item of raw.packs) {
    const sha256 = asRecord(item)?.sha256;
    if (typeof sha256 !== "string" || !GODOT_PACK_SHA256.test(sha256))
      return fail("Each pack is { sha256 }, a lowercase hex SHA-256");
    packs.push({ sha256 });
  }
  const entry = raw.entry === undefined ? undefined : parseGodotEntry(raw.entry);
  if (raw.entry !== undefined && !entry)
    return fail("entry must be { scene?: string, args?: string[] }");
  if (raw.reload !== undefined && !isReloadTier(raw.reload))
    return fail("reload must be scripts, scene, or restart");
  const version = text(engine.version, 32);
  const label = text(raw.label, 200);
  const name = typeof raw.name === "string" ? raw.name.trim().slice(0, 80) : "";
  return ok({
    v: 1,
    engine: { name: "godot", ...(version ? { version } : {}) },
    packs,
    ...(entry ? { entry } : {}),
    ...(isReloadTier(raw.reload) ? { reload: raw.reload } : {}),
    ...(label ? { label } : {}),
    ...(name ? { name } : {}),
  });
}

/** The command's own time limit, or the default for it; never over the maximum. */
export function commandTimeoutMs(command: GodotCommandInput, requested?: unknown): number {
  const asked = finite(requested, 1, GODOT_COMMAND_MAX_TIMEOUT_MS);
  if (asked !== undefined) return asked;
  const base = GODOT_COMMAND_TIMEOUT_MS[command.name];
  const steps =
    command.name === "input" ? command.steps.reduce((sum, step) => sum + stepMs(step), 0) : 0;
  return Math.min(base + steps, GODOT_COMMAND_MAX_TIMEOUT_MS);
}
