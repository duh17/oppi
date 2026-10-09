/**
 * Simulator lifecycle for the pool: idle reaping, the booted-simulator ceiling,
 * and session-owned claims. Every shutdown happens under the slot's flock
 * lease, so a run, a claim owner, and a reaper never race on one simulator.
 *
 * Reaping runs only inside a pool command (after run, claim, release; before a
 * boot; `reap`), right after that command used its lock dir. There is no
 * background watcher: a detached process can outlive the lock dir and PATH it
 * was started with and then reap the wrong simulators against an empty ledger.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync } from "node:fs";
import {
  beginPublishing,
  inspectSlot,
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
  type SimulatorDevice,
} from "./sim-pool-simctl";
import { CommandSession } from "./sim-pool-supervise";

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

export type IdleSlot = { slot: number; udid: string; lastUsedMs: number };

type RestingSlot =
  | { kind: "idle"; lastUsedMs: number }
  | { kind: "claimed"; claim: SlotClaim; claimedAtMs: number }
  | { kind: "busy" };

/**
 * What a slot is while no lease holds it: idle, claimed, or busy (held now,
 * legacy, unreadable). A claim on an `uncertain` or dead `in-flight` record
 * still counts as a claim, so the reaper and `release` can finish it; without
 * a claim such a record is idle, and `tryAcquireSlot` takes it back once its
 * processes are gone.
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
  return { kind: "idle", lastUsedMs: lastUsedMs(state) };
}

/**
 * Idle booted pool simulators to shut down now. The `keepWarm` most recently
 * used stay booted no matter how long they idle; the rest go once idle for
 * `idleMs`.
 */
export function planIdleReap(idle: IdleSlot[], nowMs: number, idleMs: number, keepWarm: number): IdleSlot[] {
  return [...idle]
    .sort((a, b) => b.lastUsedMs - a.lastUsedMs)
    .slice(keepWarm)
    .filter((slot) => slot.lastUsedMs + idleMs <= nowMs);
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

type ClaimPass = { shutdowns: number; failed: boolean };

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
  const pass: ClaimPass = { shutdowns: 0, failed: false };
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
  }
  return pass;
}

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
      idle.push({ slot, udid: device.udid, lastUsedMs: resting.lastUsedMs });
    }
  }
  return idle;
}

/**
 * One reaper pass: shut down idle pool simulators past the idle limit (except
 * the warm ones), then settle claims. Anything it cannot shut down now (a
 * failed shutdown, a lease whose processes still run) is picked up by the
 * next pool command's pass. Returns whether any shutdown failed.
 */
export async function reapOnce(config: PoolConfig, session: CommandSession): Promise<boolean> {
  const now = Date.now();
  const devices = await listDevices(session);
  const expired = planIdleReap(idlePoolSlots(config.lockDir, devices), now, config.idleMinutes * 60_000, config.keepWarm);
  let failed = false;
  for (const slot of expired) {
    if (session.canceled) {
      return failed;
    }
    log(`[sim-pool] reap: ${poolDeviceName(slot.slot)} idle for ${formatAge(now - slot.lastUsedMs)}`);
    const outcome = await shutdownPoolSlot(session, config, slot.slot, slot.udid, "reap", {
      idleSince: slot.lastUsedMs,
    });
    failed ||= outcome === "failed";
  }
  return (await reapClaims(session, config, devices)).failed || failed;
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

/**
 * Reap pass at the end of a pool command (run, claim, release). Housekeeping
 * only: a failure is logged and never changes the command's result.
 */
export async function reapAfterCommand(config: PoolConfig): Promise<void> {
  if (config.idleMinutes === 0) {
    return;
  }
  const session = new CommandSession();
  session.installHandlers();
  try {
    await reapOnce(config, session);
  } catch (error) {
    log(`[sim-pool] reap failed: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    await session.dispose();
  }
}

export async function commandReap(config: PoolConfig, args: string[]): Promise<number> {
  if (args.length > 0) {
    die(`reap: unexpected argument ${args[0]}`);
  }
  if (config.idleMinutes === 0) {
    log("[sim-pool] reap: OPPI_SIM_POOL_IDLE_MINUTES=0, the reaper is off");
    return 0;
  }
  const session = new CommandSession();
  session.installHandlers();
  try {
    const failed = await reapOnce(config, session);
    return session.canceled ? session.cancelExitCode() : failed ? 1 : 0;
  } finally {
    await session.dispose();
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
  await reapAfterCommand(config);
  return 0;
}

export async function commandRelease(config: PoolConfig, args: string[]): Promise<number> {
  const status = await releaseClaims(config, args);
  if (status !== 130 && status !== 143) {
    await reapAfterCommand(config);
  }
  return status;
}

async function releaseClaims(config: PoolConfig, args: string[]): Promise<number> {
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
    const isTarget = (slot: number) => !target || poolDeviceFor(devices, slot)?.udid === target;
    const selected = claimedSlots(config.lockDir).filter(
      (entry) => entry.claim.owner === owner && isTarget(entry.slot),
    );
    // Claims of this owner that a reaper or claim holds right now cannot be
    // released yet; say so instead of reporting that nothing is claimed.
    const held = [...slotStates(config.lockDir)]
      .filter(([slot, state]) => state.claim?.owner === owner && isTarget(slot))
      .map(([slot]) => slot)
      .filter((slot) => restingSlot(config.lockDir, slot).kind === "busy");
    for (const slot of held) {
      log(`[sim-pool] release: ${poolDeviceName(slot)} is busy with another sim-pool command; try again`);
      status = 1;
    }
    if (target && selected.length === 0 && held.length === 0) {
      die(`release: ${target} is not claimed by session ${owner}`);
    }
    if (selected.length === 0) {
      if (held.length === 0) {
        log(`[sim-pool] release: session ${owner} has no claimed simulators`);
      }
      return status;
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
      : `Idle reaper: after ${config.idleMinutes}m, keeping ${config.keepWarm} warm`,
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
