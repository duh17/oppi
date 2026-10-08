/**
 * Simulator lifecycle for the pool: idle reaping, the booted-simulator ceiling,
 * and session-owned claims. Every shutdown happens under the slot's flock
 * lease, so a run, a claim owner, and a reaper never race on one simulator.
 */
import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  constants,
  existsSync,
  mkdirSync,
  openSync,
  readdirSync,
  statSync,
  truncateSync,
} from "node:fs";
import { join } from "node:path";
import {
  beginPublishing,
  flockFd,
  inspectSlot,
  LOCK_EX,
  LOCK_NB,
  readSlotState,
  recordOwnedPgid,
  releaseClaimed,
  releaseReusable,
  releaseUncertain,
  tryAcquireSlot,
  type AcquireSuccess,
  type SlotClaim,
  type SlotState,
} from "./sim-pool-lock";
import {
  die,
  ensureSim,
  listDevices,
  log,
  poolSlotRange,
  prepareSimulator,
  resolveRuntime,
  runXcrun,
  type PoolConfig,
} from "./sim-pool-ops";
import {
  deviceState,
  parseDevicesJson,
  poolDeviceName,
  preferredAcquireSlots,
  simctlDeviceEnv,
  type SimulatorDevice,
} from "./sim-pool-simctl";
import { CommandSession } from "./sim-pool-supervise";

/** How often a watcher rechecks booted claims, whose owners can stop at any time. */
const CLAIM_POLL_MS = 5 * 60_000;
/** When a pass failed to shut something down, the watcher tries again this soon. */
const RETRY_MS = 2 * 60_000;
/** Longest watcher sleep, so a watcher notices slots released after it planned. */
const WATCH_MAX_SLEEP_MS = 10 * 60_000;
const REAPER_LOG_MAX_BYTES = 1_000_000;

const POOL_NAME = /^Oppi-Pool-(\d+)$/;

function poolSlot(device: SimulatorDevice): number | null {
  const match = POOL_NAME.exec(device.name);
  return match ? Number(match[1]) : null;
}

function isBooted(device: SimulatorDevice): boolean {
  return device.state === "Booted" || device.state === "Booting";
}

/** A reusable slot's state is written when it is released; that is its last use. */
function lastUsedMs(state: SlotState | null): number {
  return state ? Date.parse(state.started_at) || 0 : 0;
}

function formatAge(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h${minutes % 60}m`;
}

/**
 * `abandoned`: no lease holds the slot, but its last lease ended `uncertain` or
 * died `in-flight`. `tryAcquireSlot` takes it back once its processes are gone.
 */
export type IdleSlot = { slot: number; udid: string; lastUsedMs: number; abandoned?: boolean };

type RestingSlot =
  | { kind: "idle"; lastUsedMs: number; abandoned: boolean }
  | { kind: "claimed"; claim: SlotClaim; claimedAtMs: number }
  | { kind: "busy" };

/**
 * What a slot is while no lease holds it: idle, claimed, or busy (held now,
 * legacy, unreadable). A claim on an `uncertain` or dead `in-flight` record
 * still counts as a claim, so the reaper and `release` can finish it.
 */
function restingSlot(lockDir: string, slot: number): RestingSlot {
  const info = inspectSlot(lockDir, slot);
  if (info.legacy || info.flockHeld || info.state === "unreadable") {
    return { kind: "busy" };
  }
  const state = info.state;
  if (state?.claim) {
    return { kind: "claimed", claim: state.claim, claimedAtMs: lastUsedMs(state) };
  }
  return { kind: "idle", lastUsedMs: lastUsedMs(state), abandoned: state !== null && state.status !== "reusable" };
}

/**
 * Idle booted pool simulators to shut down now. The `keepWarm` most recently
 * used stay booted no matter how long they idle; the rest go once idle for
 * `idleMs`. `nextDueMs` is when the next kept-for-now simulator expires.
 */
export function planIdleReap(
  idle: IdleSlot[],
  nowMs: number,
  idleMs: number,
  keepWarm: number,
): { expired: IdleSlot[]; nextDueMs?: number } {
  const byRecent = [...idle].sort((a, b) => b.lastUsedMs - a.lastUsedMs);
  const expired: IdleSlot[] = [];
  let nextDueMs: number | undefined;
  for (const slot of byRecent.slice(keepWarm)) {
    const due = slot.lastUsedMs + idleMs;
    if (due <= nowMs) {
      expired.push(slot);
    } else {
      nextDueMs = nextDueMs === undefined ? due : Math.min(nextDueMs, due);
    }
  }
  return { expired, nextDueMs };
}

export type OwnerInfo = { status: string; lastActivityMs?: number } | "gone" | "unknown";
export type ClaimVerdict = "release" | "power-down" | "keep";

/**
 * A stopped or deleted owner loses the claim. A busy owner keeps its simulator
 * booted. An owner idle past `idleMs` keeps the claim but not the power, unless
 * it claimed (or re-claimed) within `idleMs`: a claim is a use, and session
 * activity does not see it. Its next `claim` boots the same simulator again;
 * `idleMs` 0 (reaper off) never powers one down. Unknown owners are left alone.
 */
export function claimVerdict(
  owner: OwnerInfo,
  nowMs: number,
  idleMs: number,
  claimedAtMs: number,
): ClaimVerdict {
  if (owner === "gone") {
    return "release";
  }
  if (owner === "unknown") {
    return "keep";
  }
  if (owner.status === "stopped") {
    return "release";
  }
  if (owner.status === "busy" || owner.status === "starting" || owner.status === "stopping") {
    return "keep";
  }
  if (
    idleMs > 0 &&
    owner.lastActivityMs !== undefined &&
    nowMs - owner.lastActivityMs >= idleMs &&
    nowMs - claimedAtMs >= idleMs
  ) {
    return "power-down";
  }
  return "keep";
}

function oppiJson(args: string[]): Record<string, unknown> | undefined {
  const result = spawnSync("oppi", args, { encoding: "utf8", timeout: 30_000 });
  if (result.error || !result.stdout) {
    return undefined;
  }
  try {
    return JSON.parse(result.stdout) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

function ownerFromSession(session: Record<string, unknown>): OwnerInfo {
  const activity = Number(session.lastActivity ?? session.last_activity);
  return {
    status: String(session.status ?? ""),
    ...(Number.isFinite(activity) && activity > 0 ? { lastActivityMs: activity } : {}),
  };
}

/**
 * Looks owners up through the oppi CLI: one `session list` for the recent
 * sessions, then `session get` for any owner the list does not show, so only
 * a confirmed `session_not_found` counts as gone.
 */
export function lookupOwners(owners: string[]): Map<string, OwnerInfo> {
  const found = new Map<string, OwnerInfo>();
  if (owners.length === 0) {
    return found;
  }
  const listed = oppiJson(["session", "list", "--json"]);
  const rows = (listed?.data as { sessions?: Array<Record<string, unknown>> } | undefined)?.sessions ?? [];
  for (const row of rows) {
    const id = String(row.id ?? "");
    if (owners.includes(id)) {
      found.set(id, ownerFromSession(row));
    }
  }
  for (const owner of owners) {
    if (found.has(owner)) {
      continue;
    }
    const got = oppiJson(["session", "get", owner, "--json"]);
    const session = (got?.data as { session?: Record<string, unknown> } | undefined)?.session;
    if (got?.ok === true && session) {
      found.set(owner, ownerFromSession(session));
    } else if ((got?.error as { code?: string } | undefined)?.code === "session_not_found") {
      found.set(owner, "gone");
    } else {
      found.set(owner, "unknown");
    }
  }
  return found;
}

type ClaimedSlot = { slot: number; claim: SlotClaim; claimedAtMs: number };

function slotStates(lockDir: string): Map<number, SlotState> {
  const states = new Map<number, SlotState>();
  if (!existsSync(lockDir)) {
    return states;
  }
  for (const name of readdirSync(lockDir)) {
    const match = /^slot-([0-9]+)\.state\.json$/.exec(name);
    if (!match) {
      continue;
    }
    const slot = Number(match[1]);
    const state = readSlotState(lockDir, slot);
    if (state && state !== "unreadable") {
      states.set(slot, state);
    }
  }
  return states;
}

/** Claims no lease is working on right now, including ones a failed shutdown left `uncertain`. */
function claimedSlots(lockDir: string): ClaimedSlot[] {
  const claimed: ClaimedSlot[] = [];
  for (const [slot, state] of slotStates(lockDir)) {
    if (!state.claim) {
      continue;
    }
    const resting = restingSlot(lockDir, slot);
    if (resting.kind === "claimed") {
      claimed.push({ slot, claim: resting.claim, claimedAtMs: resting.claimedAtMs });
    }
  }
  return claimed.sort((a, b) => a.slot - b.slot);
}

function poolDeviceFor(devices: SimulatorDevice[], slot: number): SimulatorDevice | undefined {
  return devices.find((device) => device.isAvailable && poolSlot(device) === slot);
}

type ShutdownMode = {
  /** Lets this caller take a claimed slot (owner release, reaper). */
  claimed?: (state: SlotState) => boolean;
  /** End the claim on success; otherwise a claim survives the shutdown. */
  endClaim?: boolean;
  /** Skip the slot if it was used again after the caller planned around this time. */
  idleSince?: number;
  /**
   * Decides again under the lease, from fresh owner state, just before the
   * shutdown; `keep` puts the slot back untouched and `release` ends the claim.
   */
  confirm?: (previous: SlotState | null) => ClaimVerdict;
};

type ShutdownOutcome = "shutdown" | "not-booted" | "skipped" | "failed";

/**
 * Shuts one pool simulator down under its slot lease: acquire, recheck that
 * the device is still booted, shut it down, release. Busy, legacy, and
 * other owners' slots are skipped. A failure restores the previous state
 * (a claim stays claimed); unproven quiescence leaves the slot uncertain.
 */
async function shutdownPoolSlot(
  session: CommandSession,
  config: PoolConfig,
  slot: number,
  udid: string | undefined,
  label: string,
  mode: ShutdownMode = {},
): Promise<ShutdownOutcome> {
  const acquired = tryAcquireSlot({ lockDir: config.lockDir, slot, argv: [label], claimed: mode.claimed });
  if (!acquired.ok) {
    if (/legacy|busy|in-flight|uncertain|claimed/.test(acquired.reason)) {
      log(`[sim-pool] ${label}: skipping slot ${slot} (${acquired.reason})`);
      return "skipped";
    }
    log(`[sim-pool] ${label}: failed to acquire slot ${slot}: ${acquired.reason}`);
    return "failed";
  }
  const owned = acquired.owned;
  const previousClaim = acquired.previous?.claim;
  session.onBeforeSpawn = () => {
    beginPublishing(owned);
  };
  session.onSpawned = (child) => {
    recordOwnedPgid(owned, child.pgid);
  };
  let released = false;
  let endClaim = mode.endClaim ?? false;
  // Restoring is not a use: keep the previous timestamp so idle clocks run on.
  const previousStartedAt = acquired.previous?.started_at;
  const finish = (kind: "done" | "restore" | "uncertain", note?: string): void => {
    if (released) {
      return;
    }
    released = true;
    session.onBeforeSpawn = undefined;
    session.onSpawned = undefined;
    if (kind === "uncertain") {
      releaseUncertain(owned, note ?? `${label} did not prove quiescence`, previousStartedAt);
    } else if (previousClaim && (kind === "restore" || !endClaim)) {
      releaseClaimed(owned, previousClaim, previousStartedAt);
    } else if (kind === "restore") {
      releaseReusable(owned, previousStartedAt);
    } else {
      releaseReusable(owned);
    }
  };
  try {
    if (mode.idleSince !== undefined && lastUsedMs(acquired.previous) !== mode.idleSince) {
      finish("restore");
      return "skipped";
    }
    if (mode.confirm) {
      const verdict = mode.confirm(acquired.previous);
      if (verdict === "keep") {
        log(`[sim-pool] ${label}: owner of slot ${slot} is active again; leaving it`);
        finish("restore");
        return "skipped";
      }
      endClaim = verdict === "release";
    }
    if (!udid) {
      finish("done");
      return "not-booted";
    }
    const recheck = await runXcrun(session, ["simctl", "list", "devices", "-j"]);
    if (!recheck.stop.quiescent) {
      log(`[sim-pool] ${label}: recheck did not prove quiescence for ${udid}`);
      finish("uncertain", recheck.stop.note ?? "recheck did not prove quiescence");
      return "failed";
    }
    if (session.canceled) {
      finish("restore");
      return "failed";
    }
    let state = "";
    if (recheck.code === 0) {
      try {
        state = deviceState(parseDevicesJson(recheck.stdout), udid) ?? "";
      } catch {
        state = "";
      }
    }
    if (!state) {
      log(`[sim-pool] ${label}: failed to recheck ${udid}`);
      finish("restore");
      return "failed";
    }
    if (state !== "Booted") {
      log(`[sim-pool] ${label}: ${udid} state is ${state} (not Booted)`);
      finish("done");
      return "not-booted";
    }
    if (session.canceled) {
      finish("restore");
      return "failed";
    }
    log(`[sim-pool] ${label}: shutting down ${poolDeviceName(slot)} ${udid}`);
    const shutdown = await runXcrun(session, ["simctl", "shutdown", udid]);
    if (!shutdown.stop.quiescent) {
      log(`[sim-pool] ${label}: shutdown did not prove quiescence for ${udid}`);
      finish("uncertain", shutdown.stop.note ?? "shutdown did not prove quiescence");
      return "failed";
    }
    if (shutdown.code !== 0) {
      log(`[sim-pool] ${label}: failed to shut down ${udid}`);
      finish("restore");
      return "failed";
    }
    finish("done");
    return "shutdown";
  } catch (error) {
    finish(owned.pgids.length > 0 ? "uncertain" : "restore", error instanceof Error ? error.message : String(error));
    throw error;
  } finally {
    if (!released) {
      finish(owned.pgids.length > 0 ? "uncertain" : "restore", `${label} released without completion`);
    }
  }
}

export async function commandShutdownIdle(config: PoolConfig): Promise<number> {
  const session = new CommandSession();
  session.installHandlers();
  let status = 0;
  try {
    const list = await runXcrun(session, ["simctl", "list", "devices", "-j"]);
    if (session.canceled) {
      return session.cancelExitCode();
    }
    if (!list.stop.quiescent) {
      log(`[sim-pool] shutdown-idle: list did not prove quiescence${list.stop.note ? ` (${list.stop.note})` : ""}`);
      return 1;
    }
    if (list.code !== 0) {
      log("[sim-pool] shutdown-idle: failed to list simulators");
      return 1;
    }
    let devices: SimulatorDevice[];
    try {
      devices = parseDevicesJson(list.stdout);
    } catch {
      log("[sim-pool] shutdown-idle: failed to parse simulator list");
      return 1;
    }
    for (const device of devices) {
      const slot = poolSlot(device);
      if (slot == null || device.state !== "Booted") {
        continue;
      }
      if (session.canceled) {
        break;
      }
      const outcome = await shutdownPoolSlot(session, config, slot, device.udid, "shutdown-idle");
      if (outcome === "failed") {
        status = 1;
      }
    }
    if (session.canceled) {
      status = session.cancelExitCode();
    }
  } finally {
    const stopped = await session.dispose();
    if (!stopped.quiescent && status === 0 && !session.canceled) {
      status = 1;
    }
  }
  return status;
}

type ClaimPass = { bootedKept: boolean; shutdowns: number; failed: boolean };

/**
 * Frees claims of stopped owners and powers down claims of idle owners. The
 * owner lookup up front only plans; each shutdown asks again under the lease,
 * because a session can resume while earlier shutdowns run.
 */
async function reapClaims(
  session: CommandSession,
  config: PoolConfig,
  devices: SimulatorDevice[],
  slots?: number[],
): Promise<ClaimPass> {
  const claims = claimedSlots(config.lockDir).filter((entry) => !slots || slots.includes(entry.slot));
  const pass: ClaimPass = { bootedKept: false, shutdowns: 0, failed: false };
  if (claims.length === 0) {
    return pass;
  }
  const idleMs = config.idleMinutes * 60_000;
  const owners = lookupOwners([...new Set(claims.map((entry) => entry.claim.owner))]);
  const now = Date.now();
  for (const { slot, claim, claimedAtMs } of claims) {
    if (session.canceled) {
      break;
    }
    const device = poolDeviceFor(devices, slot);
    const booted = device ? isBooted(device) : false;
    const verdict = claimVerdict(owners.get(claim.owner) ?? "unknown", now, idleMs, claimedAtMs);
    if (verdict === "keep" || (verdict === "power-down" && !booted)) {
      pass.bootedKept ||= booted;
      continue;
    }
    log(
      verdict === "release"
        ? `[sim-pool] reap: session ${claim.owner} is gone; freeing its ${claim.profile} claim on ${poolDeviceName(slot)}`
        : `[sim-pool] reap: session ${claim.owner} is idle; shutting down its claimed ${poolDeviceName(slot)}`,
    );
    const outcome = await shutdownPoolSlot(session, config, slot, booted ? device?.udid : undefined, "reap", {
      claimed: (state) => state.claim?.owner === claim.owner,
      confirm: (previous) =>
        claimVerdict(lookupOwners([claim.owner]).get(claim.owner) ?? "unknown", Date.now(), idleMs, lastUsedMs(previous)),
    });
    pass.failed ||= outcome === "failed";
    pass.shutdowns += outcome === "shutdown" ? 1 : 0;
    pass.bootedKept ||= booted && outcome !== "shutdown";
  }
  return pass;
}

export type ReapResult = { nextDueMs?: number; failed: boolean };

/**
 * One reaper pass: shut down idle pool simulators past the idle limit (except
 * the warm ones), then settle claims. `nextDueMs` says when another pass could
 * change something; undefined means nothing is left to watch.
 */
/** Booted pool simulators that no lease or claim holds. */
function idlePoolSlots(lockDir: string, devices: SimulatorDevice[]): IdleSlot[] {
  const idle: IdleSlot[] = [];
  for (const device of devices) {
    const slot = poolSlot(device);
    if (slot == null || !isBooted(device)) {
      continue;
    }
    const resting = restingSlot(lockDir, slot);
    if (resting.kind === "idle") {
      idle.push({ slot, udid: device.udid, lastUsedMs: resting.lastUsedMs, abandoned: resting.abandoned });
    }
  }
  return idle;
}

export async function reapOnce(config: PoolConfig, session: CommandSession): Promise<ReapResult> {
  const now = Date.now();
  const devices = await listDevices(session);
  const idle = idlePoolSlots(config.lockDir, devices);
  const plan = planIdleReap(idle, now, config.idleMinutes * 60_000, config.keepWarm);
  let failed = false;
  let retry = false;
  for (const slot of plan.expired) {
    if (session.canceled) {
      return { failed };
    }
    log(`[sim-pool] reap: ${poolDeviceName(slot.slot)} idle for ${formatAge(now - slot.lastUsedMs)}`);
    const outcome = await shutdownPoolSlot(session, config, slot.slot, slot.udid, "reap", {
      idleSince: slot.lastUsedMs,
    });
    failed ||= outcome === "failed";
    // An abandoned lease whose processes still run is skipped; try it again later.
    retry ||= outcome === "skipped" && slot.abandoned === true;
  }
  const claims = await reapClaims(session, config, devices);
  failed ||= claims.failed;
  const claimDue = claims.bootedKept ? now + CLAIM_POLL_MS : undefined;
  // A failed or deferred shutdown leaves its simulator booted; keep a watcher on it.
  const retryDue = failed || retry ? Date.now() + RETRY_MS : undefined;
  const dues = [plan.nextDueMs, claimDue, retryDue].filter((due): due is number => due !== undefined);
  return { failed, ...(dues.length > 0 ? { nextDueMs: Math.min(...dues) } : {}) };
}

/**
 * Keeps booting `targetUdid` under the booted-simulator ceiling: shuts down
 * least recently used idle pool simulators, then claims whose owner is gone
 * or idle. Simulators the pool does not manage count but are never touched;
 * when nothing can go, the boot proceeds and the log says so.
 */
export async function ensureBootCapacity(config: PoolConfig, targetUdid: string): Promise<void> {
  if (config.maxBooted === 0) {
    return;
  }
  const session = new CommandSession();
  session.installHandlers();
  try {
    const devices = await listDevices(session);
    let booted = devices.filter((device) => isBooted(device) && device.udid !== targetUdid).length;
    if (booted < config.maxBooted) {
      return;
    }
    const others = devices.filter((device) => device.udid !== targetUdid);
    const idle = idlePoolSlots(config.lockDir, others).sort((a, b) => a.lastUsedMs - b.lastUsedMs);
    const claimed: number[] = [];
    for (const device of others) {
      const slot = poolSlot(device);
      if (slot != null && isBooted(device) && restingSlot(config.lockDir, slot).kind === "claimed") {
        claimed.push(slot);
      }
    }
    const now = Date.now();
    for (const slot of idle) {
      if (booted < config.maxBooted || session.canceled) {
        break;
      }
      log(
        `[sim-pool] ${booted} simulators booted (limit ${config.maxBooted}); shutting down least recently used ${poolDeviceName(slot.slot)} (idle ${formatAge(now - slot.lastUsedMs)})`,
      );
      const outcome = await shutdownPoolSlot(session, config, slot.slot, slot.udid, "capacity", {
        idleSince: slot.lastUsedMs,
      });
      if (outcome === "shutdown") {
        booted -= 1;
      }
    }
    if (booted >= config.maxBooted && claimed.length > 0 && !session.canceled) {
      booted -= (await reapClaims(session, config, devices, claimed)).shutdowns;
    }
    if (booted >= config.maxBooted) {
      log(
        `[sim-pool] ${booted} simulators booted (limit ${config.maxBooted}) and none is idle in the pool; booting anyway`,
      );
    }
  } finally {
    await session.dispose();
  }
}

function takeReaperLock(lockDir: string): number | undefined {
  mkdirSync(lockDir, { recursive: true });
  const fd = openSync(join(lockDir, "reaper.lock"), constants.O_RDWR | constants.O_CREAT, 0o644);
  // A watcher that just decided to exit still holds the lock for a moment.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (flockFd(fd, LOCK_EX | LOCK_NB) === 0) {
      return fd;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
  }
  closeSync(fd);
  return undefined;
}

function reaperRunning(lockDir: string): boolean {
  const path = join(lockDir, "reaper.lock");
  if (!existsSync(path)) {
    return false;
  }
  const fd = openSync(path, constants.O_RDWR);
  try {
    return flockFd(fd, LOCK_EX | LOCK_NB) !== 0;
  } finally {
    closeSync(fd);
  }
}

/** Starts a detached `reap --watch`; at most one runs per lock dir. */
export function startReaperWatcher(config: PoolConfig): void {
  if (config.idleMinutes === 0) {
    return;
  }
  mkdirSync(config.lockDir, { recursive: true });
  const logPath = join(config.lockDir, "reaper.log");
  if (existsSync(logPath) && statSync(logPath).size > REAPER_LOG_MAX_BYTES) {
    truncateSync(logPath, 0);
  }
  const fd = openSync(logPath, "a");
  try {
    const child = spawn(process.execPath, [config.poolScript, "reap", "--watch"], {
      detached: true,
      stdio: ["ignore", fd, fd],
      env: simctlDeviceEnv(process.env),
    });
    child.unref();
  } finally {
    closeSync(fd);
  }
}

/** Housekeeping after a run; it never changes the run's result. */
export async function maintainAfterRun(config: PoolConfig): Promise<void> {
  if (config.idleMinutes === 0) {
    return;
  }
  const session = new CommandSession();
  session.installHandlers();
  try {
    const result = await reapOnce(config, session);
    if (result.nextDueMs !== undefined && !session.canceled) {
      startReaperWatcher(config);
    }
  } catch (error) {
    log(`[sim-pool] reap after run failed: ${error instanceof Error ? error.message : String(error)}; leaving it to the watcher`);
    startReaperWatcher(config);
  } finally {
    await session.dispose();
  }
}

export async function commandReap(config: PoolConfig, args: string[]): Promise<number> {
  const unknown = args.filter((arg) => arg !== "--watch");
  if (unknown.length > 0) {
    die(`reap: unexpected argument ${unknown[0]}`);
  }
  if (config.idleMinutes === 0) {
    log("[sim-pool] reap: OPPI_SIM_POOL_IDLE_MINUTES=0, the reaper is off");
    return 0;
  }
  if (!args.includes("--watch")) {
    const session = new CommandSession();
    session.installHandlers();
    try {
      const result = await reapOnce(config, session);
      return session.canceled ? session.cancelExitCode() : result.failed ? 1 : 0;
    } finally {
      await session.dispose();
    }
  }
  const lock = takeReaperLock(config.lockDir);
  if (lock === undefined) {
    log("[sim-pool] reap: another watcher is already running");
    return 0;
  }
  try {
    while (true) {
      log(`[sim-pool] reap ${new Date().toISOString()}`);
      const session = new CommandSession();
      session.installHandlers();
      let result: ReapResult;
      try {
        result = await reapOnce(config, session);
      } catch (error) {
        log(`[sim-pool] reap failed: ${error instanceof Error ? error.message : String(error)}`);
        result = { failed: true, nextDueMs: Date.now() + RETRY_MS };
      } finally {
        await session.dispose();
      }
      if (session.canceled) {
        return session.cancelExitCode();
      }
      if (result.nextDueMs === undefined) {
        log("[sim-pool] reap: nothing left to watch");
        return 0;
      }
      const waitMs = Math.min(Math.max(result.nextDueMs - Date.now(), 5_000), WATCH_MAX_SLEEP_MS);
      log(`[sim-pool] reap: next pass in ${Math.round(waitMs / 1000)}s`);
      await new Promise((resolve) => setTimeout(resolve, waitMs));
    }
  } finally {
    closeSync(lock);
  }
}

function parseOwnerArgs(command: string, args: string[]): { owner: string; positional: string[] } {
  let owner = process.env.OPPI_CALLER_SESSION_ID?.trim() ?? "";
  const positional: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--owner") {
      const value = args[i + 1];
      if (!value || value.startsWith("-")) {
        die("--owner requires a session id");
      }
      owner = value;
      i += 1;
    } else if (arg.startsWith("--owner=")) {
      owner = arg.slice("--owner=".length);
    } else if (arg.startsWith("-")) {
      die(`${command}: unexpected argument ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  if (!owner) {
    die(`${command} needs an owner session: run it from an Oppi session (OPPI_CALLER_SESSION_ID) or pass --owner`);
  }
  return { owner, positional };
}

function claimSlotNumbers(config: PoolConfig): number[] {
  return Array.from({ length: config.claimCount }, (_, index) => config.claimSlotStart + index);
}

function claimRange(config: PoolConfig): string {
  return poolSlotRange({ ...config, slotStart: config.claimSlotStart, count: config.claimCount });
}

export async function commandClaim(config: PoolConfig, args: string[]): Promise<number> {
  const { owner, positional } = parseOwnerArgs("claim", args);
  if (positional.length > 0) {
    die(`claim: unexpected argument ${positional[0]}`);
  }
  if (!config.profileName || config.claimCount === 0) {
    die("claim needs --device-profile (iphone, ipad, or duo)");
  }
  const profile = config.profileName;
  const slots = claimSlotNumbers(config);
  const session = new CommandSession();
  session.installHandlers();
  let acquired: AcquireSuccess | undefined;
  let done = false;
  try {
    // A session that already holds a claim gets that simulator back. If a
    // reaper or release is working on the slot, wait for it rather than
    // claiming a second one; the slot still records the claim meanwhile.
    const mine = slots.find((slot) => {
      const state = readSlotState(config.lockDir, slot);
      return state && state !== "unreadable" && state.claim?.owner === owner && state.claim.profile === profile;
    });
    if (mine !== undefined) {
      const deadline = Date.now() + config.waitSeconds * 1000;
      while (!acquired && !session.canceled) {
        const result = tryAcquireSlot({
          lockDir: config.lockDir,
          slot: mine,
          argv: ["claim", owner],
          claimed: (current) => current.claim?.owner === owner,
        });
        if (result.ok) {
          acquired = result;
        } else if (result.reason.includes("claimed by")) {
          break;
        } else if (Date.now() >= deadline) {
          die(
            `claim: ${poolDeviceName(mine)}, already claimed by session ${owner}, is still busy (${result.reason}); try again`,
          );
        } else {
          await session.waitWhileIdle(1000);
        }
      }
      if (session.canceled) {
        return session.cancelExitCode();
      }
    }
    const runtime = await resolveRuntime(session, config);
    for (let pass = 0; !acquired && pass < 2; pass += 1) {
      const devices = await listDevices(session);
      if (pass === 1) {
        // Every slot is taken: free claims whose owners are gone, then retry.
        await reapClaims(session, config, devices, slots);
      }
      for (const slot of preferredAcquireSlots(slots, devices, runtime, config.deviceType)) {
        const result = tryAcquireSlot({ lockDir: config.lockDir, slot, argv: ["claim", owner] });
        if (result.ok) {
          acquired = result;
          break;
        }
      }
    }
    if (!acquired) {
      const holders = claimedSlots(config.lockDir)
        .filter((entry) => slots.includes(entry.slot))
        .map((entry) => `${poolDeviceName(entry.slot)} by ${entry.claim.owner}`);
      die(
        `all ${slots.length} ${profile} claim slots (${claimRange(config)}) are taken${holders.length > 0 ? `: ${holders.join(", ")}` : ""}`,
      );
    }
    const owned = acquired.owned;
    // Record the claim from the first state write, so a second claim by the
    // same session waits for this boot instead of taking another slot.
    owned.claim ??= { owner, profile };
    session.onBeforeSpawn = () => {
      beginPublishing(owned);
    };
    session.onSpawned = (child) => {
      recordOwnedPgid(owned, child.pgid);
    };
    const udid = await ensureSim(session, config, owned.slot);
    await prepareSimulator(session, config, udid, "normal", () => ensureBootCapacity(config, udid));
    if (session.canceled) {
      return session.cancelExitCode();
    }
    session.onBeforeSpawn = undefined;
    session.onSpawned = undefined;
    releaseClaimed(owned, { owner, profile });
    done = true;
    log(
      `[sim-pool] ${poolDeviceName(owned.slot)} (${udid}) is claimed by session ${owner}; release it with: sim-pool.sh release ${udid}`,
    );
    process.stdout.write(`${udid}\n`);
  } finally {
    const stopped = await session.dispose();
    if (acquired && !done) {
      const previousClaim = acquired.previous?.claim;
      if (!stopped.quiescent) {
        releaseUncertain(acquired.owned, stopped.note ?? "claim ended without proven quiescence");
      } else if (previousClaim) {
        releaseClaimed(acquired.owned, previousClaim, acquired.previous?.started_at);
      } else {
        releaseReusable(acquired.owned, acquired.previous?.started_at);
      }
    }
  }
  startReaperWatcher(config);
  return 0;
}

export async function commandRelease(config: PoolConfig, args: string[]): Promise<number> {
  const { owner, positional } = parseOwnerArgs("release", args);
  if (positional.length > 1) {
    die(`release: unexpected argument ${positional[1]}`);
  }
  const target = positional[0];
  const session = new CommandSession();
  session.installHandlers();
  let status = 0;
  try {
    const devices = await listDevices(session);
    const mine = claimedSlots(config.lockDir).filter((entry) => entry.claim.owner === owner);
    const selected = target
      ? mine.filter((entry) => poolDeviceFor(devices, entry.slot)?.udid === target)
      : mine;
    if (target && selected.length === 0) {
      die(`release: ${target} is not claimed by session ${owner}`);
    }
    if (selected.length === 0) {
      log(`[sim-pool] release: session ${owner} has no claimed simulators`);
      return 0;
    }
    for (const { slot } of selected) {
      if (session.canceled) {
        break;
      }
      const device = poolDeviceFor(devices, slot);
      const outcome = await shutdownPoolSlot(session, config, slot, device?.udid, "release", {
        claimed: (state) => state.claim?.owner === owner,
        endClaim: true,
      });
      if (outcome === "failed" || outcome === "skipped") {
        status = 1;
      } else {
        log(`[sim-pool] release: freed ${poolDeviceName(slot)}${device ? ` (${device.udid})` : ""}`);
      }
    }
    if (session.canceled) {
      status = session.cancelExitCode();
    }
  } finally {
    const stopped = await session.dispose();
    if (!stopped.quiescent && status === 0) {
      status = 1;
    }
  }
  return status;
}

export function commandStatus(config: PoolConfig): number {
  const out = (line: string) => process.stdout.write(`${line}\n`);
  out(`Pool count: ${config.count}`);
  out(`Pool slot start: ${config.slotStart}`);
  out(`Pool slot range: ${poolSlotRange(config)}`);
  out(`Lock dir: ${config.lockDir}`);
  out(`Build base: ${config.buildBase}`);
  out(
    config.idleMinutes === 0
      ? "Idle reaper: off"
      : `Idle reaper: after ${config.idleMinutes}m, keeping ${config.keepWarm} warm (watcher ${reaperRunning(config.lockDir) ? "running" : "not running"})`,
  );
  out(`Booted limit: ${config.maxBooted === 0 ? "off" : config.maxBooted}`);
  out("");
  out("Locks:");
  mkdirSync(config.lockDir, { recursive: true });
  const slots = new Set<number>();
  for (const name of readdirSync(config.lockDir)) {
    const match = /^slot-([0-9]+)(?:\.lock)?$/.exec(name);
    if (match) {
      slots.add(Number(match[1]));
    }
  }
  if (slots.size === 0) {
    out("  none");
  }
  for (const slot of [...slots].sort((a, b) => a - b)) {
    const info = inspectSlot(config.lockDir, slot);
    const state = info.state && info.state !== "unreadable" ? info.state : undefined;
    const label = info.legacy
      ? "legacy"
      : info.flockHeld
        ? "live"
        : state?.claim
          ? `claimed by ${state.claim.owner} (${state.claim.profile})`
          : (state?.status ?? "idle");
    out(`  slot-${slot} ${label}`);
  }
  out("");
  out("Pool and booted simulators:");
  const listed = spawnSync("xcrun", ["simctl", "list", "devices", "-j"], { encoding: "utf8" });
  if (listed.status !== 0) {
    return 0;
  }
  const now = Date.now();
  let booted = 0;
  for (const device of parseDevicesJson(listed.stdout)) {
    const slot = poolSlot(device);
    if (isBooted(device)) {
      booted += 1;
    }
    if (slot == null && !isBooted(device)) {
      continue;
    }
    let marker = "unmanaged";
    if (slot != null) {
      const info = inspectSlot(config.lockDir, slot);
      const state = info.state && info.state !== "unreadable" ? info.state : undefined;
      if (info.flockHeld || info.legacy || info.state === "unreadable") {
        marker = "locked";
      } else if (state?.claim) {
        marker = `claimed ${state.claim.profile} ${state.claim.owner}`;
      } else if (state && state.status !== "reusable") {
        marker = "locked";
      } else {
        marker = isBooted(device) && state ? `idle ${formatAge(now - lastUsedMs(state))}` : "idle";
      }
    }
    out(`  ${device.name.padEnd(24)} ${device.state.padEnd(8)} ${marker.padEnd(10)} ${device.udid}`);
  }
  out("");
  out(`Booted: ${booted}${config.maxBooted === 0 ? "" : ` of ${config.maxBooted}`}`);
  return 0;
}
