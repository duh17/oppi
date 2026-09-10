import { dlopen, FFIType, suffix } from "bun:ffi";
import { randomUUID } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { queryProcessGroup } from "./sim-pool-supervise";

export const LOCK_SH = 1;
export const LOCK_EX = 2;
export const LOCK_NB = 4;
export const LOCK_UN = 8;

const libc = dlopen(`libc.${suffix}`, {
  flock: {
    args: [FFIType.i32, FFIType.i32],
    returns: FFIType.i32,
  },
});

export function flockFd(fd: number, op: number): number {
  const flock = libc.symbols.flock;
  if (typeof flock !== "function") {
    throw new Error("libc flock is unavailable");
  }
  return flock(fd, op);
}

export type SlotStatus = "reusable" | "in-flight" | "uncertain";
export type SlotFormat = "flock-v1" | "flock-v2";
export type LeaseProtocol = "ungated" | "gated-v1";

export type SlotState = {
  format: SlotFormat;
  protocol: LeaseProtocol;
  status: SlotStatus;
  pid: number;
  nonce: string;
  argv: string[];
  started_at: string;
  note?: string;
  pgids: number[];
  publishing: boolean;
  publishedCount: number;
};

export type OwnedSlot = {
  slot: number;
  fd: number;
  lockPath: string;
  statePath: string;
  nonce: string;
  argv: string[];
  closed: boolean;
  pgids: number[];
  protocol: LeaseProtocol;
  format: SlotFormat;
  publishing: boolean;
  publishedCount: number;
};

export type AcquireFailure = {
  ok: false;
  reason: string;
};

export type AcquireSuccess = {
  ok: true;
  owned: OwnedSlot;
};

export type AcquireResult = AcquireSuccess | AcquireFailure;

export function lockPath(lockDir: string, slot: number): string {
  return join(lockDir, `slot-${slot}.lock`);
}

export function statePath(lockDir: string, slot: number): string {
  return join(lockDir, `slot-${slot}.state.json`);
}

export function legacyDirPath(lockDir: string, slot: number): string {
  return join(lockDir, `slot-${slot}`);
}

export function readSlotState(lockDir: string, slot: number): SlotState | "unreadable" | null {
  const path = statePath(lockDir, slot);
  if (!existsSync(path)) {
    return null;
  }
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<SlotState> & { format?: string };
    if (parsed.format !== "flock-v1" && parsed.format !== "flock-v2") {
      return "unreadable";
    }
    if (parsed.status !== "reusable" && parsed.status !== "in-flight" && parsed.status !== "uncertain") {
      return "unreadable";
    }
    const protocol: LeaseProtocol =
      parsed.format === "flock-v2" && parsed.protocol === "gated-v1" ? "gated-v1" : "ungated";
    if (parsed.format === "flock-v2" && protocol !== "gated-v1") {
      return "unreadable";
    }
    const pgids = Array.isArray(parsed.pgids)
      ? parsed.pgids.map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0)
      : [];
    const publishedCount = Number(parsed.publishedCount);
    return {
      format: parsed.format,
      protocol,
      status: parsed.status,
      pid: Number(parsed.pid) || 0,
      nonce: String(parsed.nonce ?? ""),
      argv: Array.isArray(parsed.argv) ? parsed.argv.map(String) : [],
      started_at: String(parsed.started_at ?? ""),
      pgids,
      publishing: Boolean(parsed.publishing),
      publishedCount: Number.isInteger(publishedCount) && publishedCount >= 0 ? publishedCount : 0,
      ...(parsed.note ? { note: String(parsed.note) } : {}),
    };
  } catch {
    return "unreadable";
  }
}

function writeState(owned: OwnedSlot, status: SlotStatus, note?: string): void {
  const payload: SlotState = {
    format: owned.format,
    protocol: owned.protocol,
    status,
    pid: process.pid,
    nonce: owned.nonce,
    argv: owned.argv,
    started_at: new Date().toISOString(),
    pgids: [...owned.pgids],
    publishing: owned.publishing,
    publishedCount: owned.publishedCount,
    ...(note ? { note } : {}),
  };
  const tempPath = `${owned.statePath}.${process.pid}.tmp`;
  writeFileSync(tempPath, `${JSON.stringify(payload, null, 2)}\n`);
  renameSync(tempPath, owned.statePath);
}

function isLegacyDir(lockDir: string, slot: number): boolean {
  const path = legacyDirPath(lockDir, slot);
  if (!existsSync(path)) {
    return false;
  }
  try {
    return statSync(path).isDirectory();
  } catch {
    return true;
  }
}

export function tryAcquireSlot(input: {
  lockDir: string;
  slot: number;
  argv: string[];
  pid?: number;
}): AcquireResult {
  const { lockDir, slot, argv } = input;
  if (!Number.isInteger(slot) || slot < 0) {
    return { ok: false, reason: `invalid slot ${slot}` };
  }
  mkdirSync(lockDir, { recursive: true });
  if (isLegacyDir(lockDir, slot)) {
    return { ok: false, reason: `legacy slot directory present for slot ${slot}` };
  }

  const owned: OwnedSlot = {
    slot,
    fd: -1,
    lockPath: lockPath(lockDir, slot),
    statePath: statePath(lockDir, slot),
    nonce: randomUUID(),
    argv: [...argv],
    closed: false,
    pgids: [],
    format: "flock-v2",
    protocol: "gated-v1",
    publishing: false,
    publishedCount: 0,
  };

  let fd: number;
  try {
    fd = openSync(owned.lockPath, constants.O_RDWR | constants.O_CREAT, 0o644);
  } catch (error) {
    return { ok: false, reason: `open lock failed for slot ${slot}: ${error}` };
  }

  owned.fd = fd;
  const rc = flockFd(fd, LOCK_EX | LOCK_NB);
  if (rc !== 0) {
    closeSync(fd);
    owned.fd = -1;
    return { ok: false, reason: `slot ${slot} busy` };
  }

  const state = readSlotState(lockDir, slot);
  if (state === "unreadable") {
    closeSync(fd);
    owned.fd = -1;
    return { ok: false, reason: `slot ${slot} uncertain (unreadable state)` };
  }
  if (state && state.status !== "reusable") {
    if (!canReclaimAbandoned(state)) {
      const reason = `slot ${slot} ${state.status}${state.note ? `: ${state.note}` : ""}`;
      closeSync(fd);
      owned.fd = -1;
      return { ok: false, reason };
    }
  }

  try {
    writeState(owned, "in-flight");
  } catch (error) {
    closeSync(fd);
    owned.fd = -1;
    owned.closed = true;
    return { ok: false, reason: `slot ${slot} state write failed: ${error}` };
  }
  return { ok: true, owned };
}

export function closeOwned(owned: OwnedSlot): void {
  if (owned.closed) {
    return;
  }
  if (owned.fd >= 0) {
    closeSync(owned.fd);
    owned.fd = -1;
  }
  owned.closed = true;
}

export function recordedGroupsIdle(state: SlotState): boolean {
  if (state.pgids.length === 0) {
    return false;
  }
  for (const pgid of state.pgids) {
    const query = queryProcessGroup(pgid);
    if (!query.ok || query.pids.length > 0) {
      return false;
    }
  }
  return true;
}

export function canReclaimAbandoned(state: SlotState): boolean {
  if (state.status !== "in-flight" && state.status !== "uncertain") {
    return false;
  }
  const gated = state.format === "flock-v2" && state.protocol === "gated-v1";
  if (!gated) {
    return state.status === "uncertain" && recordedGroupsIdle(state);
  }
  if (state.publishing) {
    return false;
  }
  if (state.pgids.length > 0) {
    return recordedGroupsIdle(state);
  }
  return state.publishedCount === 0;
}

export function beginPublishing(owned: OwnedSlot): void {
  if (owned.closed || owned.fd < 0) {
    throw new Error("cannot publish on a closed slot");
  }
  owned.publishing = true;
  writeState(owned, "in-flight");
}

export function recordOwnedPgid(owned: OwnedSlot, pgid: number): void {
  if (owned.closed || owned.fd < 0) {
    throw new Error("cannot publish pgid on a closed slot");
  }
  if (!Number.isInteger(pgid) || pgid <= 0) {
    throw new Error(`invalid pgid ${pgid}`);
  }
  if (!owned.pgids.includes(pgid)) {
    owned.pgids.push(pgid);
  }
  owned.publishing = false;
  owned.publishedCount = owned.pgids.length;
  writeState(owned, "in-flight");
}

export function releaseReusable(owned: OwnedSlot): void {
  if (owned.closed || owned.fd < 0) {
    return;
  }
  writeState(owned, "reusable");
  closeOwned(owned);
}

export function releaseUncertain(owned: OwnedSlot, note: string): void {
  if (owned.closed || owned.fd < 0) {
    return;
  }
  writeState(owned, "uncertain", note);
  closeOwned(owned);
}

export type SlotInspection = {
  slot: number;
  legacy: boolean;
  flockHeld: boolean;
  state: SlotState | "unreadable" | null;
};

export function inspectSlot(lockDir: string, slot: number): SlotInspection {
  if (isLegacyDir(lockDir, slot)) {
    return { slot, legacy: true, flockHeld: false, state: null };
  }
  const path = lockPath(lockDir, slot);
  if (!existsSync(path)) {
    return { slot, legacy: false, flockHeld: false, state: readSlotState(lockDir, slot) };
  }
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDWR);
  } catch {
    return { slot, legacy: false, flockHeld: true, state: readSlotState(lockDir, slot) };
  }
  const rc = flockFd(fd, LOCK_EX | LOCK_NB);
  const state = readSlotState(lockDir, slot);
  if (rc === 0) {
    flockFd(fd, LOCK_UN);
    closeSync(fd);
    return { slot, legacy: false, flockHeld: false, state };
  }
  closeSync(fd);
  return { slot, legacy: false, flockHeld: true, state };
}
