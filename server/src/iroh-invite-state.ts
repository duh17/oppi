import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

import type { IrohInviteState, IrohInviteTransport } from "./types.js";

export const IROH_INVITE_STATE_VERSION = 2;
export const IROH_PAIR_ALPN_TEXT = "oppi/pair/1";

const IROH_DATA_DIR = "iroh";
const IROH_INVITE_STATE_FILE = "invite.json";

export function irohDataDir(dataDir: string): string {
  return join(dataDir, IROH_DATA_DIR);
}

export function irohInviteStatePath(dataDir: string): string {
  return join(irohDataDir(dataDir), IROH_INVITE_STATE_FILE);
}

function ensurePrivateIrohDir(dataDir: string): string {
  const dir = irohDataDir(dataDir);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  try {
    chmodSync(dir, 0o700);
  } catch {
    // Best effort: permission repair should not prevent reads on filesystems
    // that do not support POSIX modes.
  }
  return dir;
}

function clampPrivateFileMode(path: string): void {
  try {
    chmodSync(path, 0o600);
  } catch {
    // Best effort for non-POSIX filesystems.
  }
}

function writePrivateJsonFile(path: string, value: unknown): void {
  const tempPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  const bytes = `${JSON.stringify(value, null, 2)}\n`;
  try {
    writeFileSync(tempPath, bytes, { mode: 0o600, flag: "wx" });
    clampPrivateFileMode(tempPath);
    renameSync(tempPath, path);
    clampPrivateFileMode(path);
  } catch (error) {
    rmSync(tempPath, { force: true });
    throw error;
  }
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(isNonEmptyString);
}

function normalizeIrohInviteState(value: unknown): IrohInviteState | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  const record = value as Record<string, unknown>;
  if (record.version !== IROH_INVITE_STATE_VERSION) {
    return undefined;
  }
  if (!isNonEmptyString(record.nodeId)) {
    return undefined;
  }
  if (!isStringArray(record.alpns) || !record.alpns.includes(IROH_PAIR_ALPN_TEXT)) {
    return undefined;
  }
  if (record.addressMode !== "node-id" && record.addressMode !== "ticket") {
    return undefined;
  }
  if (record.ticket !== undefined && !isNonEmptyString(record.ticket)) {
    return undefined;
  }
  if (record.addressMode === "ticket" && !isNonEmptyString(record.ticket)) {
    return undefined;
  }
  if (!isNonEmptyString(record.readinessId)) {
    return undefined;
  }
  if (
    typeof record.processId !== "number" ||
    !Number.isSafeInteger(record.processId) ||
    record.processId <= 0
  ) {
    return undefined;
  }

  return {
    version: IROH_INVITE_STATE_VERSION,
    nodeId: record.nodeId,
    alpns: [...record.alpns],
    addressMode: record.addressMode,
    ...(record.ticket ? { ticket: record.ticket } : {}),
    readinessId: record.readinessId,
    processId: record.processId,
  };
}

export function irohInviteTransportFromState(
  state: IrohInviteState | unknown,
): IrohInviteTransport | undefined {
  const normalized = normalizeIrohInviteState(state);
  if (!normalized) return undefined;
  return {
    version: normalized.version,
    nodeId: normalized.nodeId,
    alpns: normalized.alpns,
    addressMode: normalized.addressMode,
    ...(normalized.ticket ? { ticket: normalized.ticket } : {}),
  };
}

export function isIrohInviteStateReady(
  state: IrohInviteState | undefined,
  readinessId: string | undefined,
): boolean {
  if (!state || !readinessId || state.readinessId !== readinessId) return false;
  try {
    process.kill(state.processId, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

export function clearIrohInviteState(dataDir: string): void {
  rmSync(irohInviteStatePath(dataDir), { force: true });
}

export function readIrohInviteState(dataDir: string): IrohInviteState | undefined {
  const path = irohInviteStatePath(dataDir);
  if (!existsSync(path)) {
    return undefined;
  }

  clampPrivateFileMode(path);

  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    return normalizeIrohInviteState(parsed);
  } catch {
    return undefined;
  }
}

export function writeIrohInviteState(dataDir: string, state: IrohInviteState): void {
  const normalized = normalizeIrohInviteState(state);
  if (!normalized) {
    throw new Error(`Iroh invite state must advertise ${IROH_PAIR_ALPN_TEXT}`);
  }

  const dir = ensurePrivateIrohDir(dataDir);
  writePrivateJsonFile(join(dir, IROH_INVITE_STATE_FILE), normalized);
}
