import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

import type { PersistedVoiceCall, VoiceCallPersistence } from "./continuous-voice-call.js";
import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "voice_call_store" } });

const STORE_VERSION = 1;
const MAX_PERSISTED_CALLS = 256;

export function voiceCallStorePath(dataDir: string): string {
  return join(dataDir, "voice-calls.json");
}

/**
 * Durable snapshot of in-memory voice-call controller state.
 *
 * Frontends are not stored. A new process must fence restored active calls and wait for
 * the paired device to attach again.
 */
export class FileVoiceCallStore implements VoiceCallPersistence {
  constructor(private readonly path: string) {}

  load(): PersistedVoiceCall[] {
    if (!existsSync(this.path)) return [];
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(this.path, "utf8"));
    } catch {
      throw new Error("Voice call store is unreadable");
    }
    return parsePersistedVoiceCallFile(parsed);
  }

  /**
   * Keeps the unusable file as `voice-calls.json.corrupt-<ms>` for inspection. The next save
   * writes a fresh store, so a failed rename cannot make the server keep tripping on it.
   */
  quarantine(reason: unknown): void {
    const asidePath = `${this.path}.corrupt-${Date.now()}`;
    const error = reason instanceof Error ? reason.message : String(reason);
    try {
      renameSync(this.path, asidePath);
      log.error("voice_call_store.corrupt", { path: this.path, movedTo: asidePath, error });
    } catch (renameError) {
      log.error("voice_call_store.corrupt_not_moved", {
        path: this.path,
        error,
        renameError: renameError instanceof Error ? renameError.message : String(renameError),
      });
    }
  }

  save(calls: readonly PersistedVoiceCall[]): void {
    const directory = dirname(this.path);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const payload = `${JSON.stringify({ version: STORE_VERSION, calls }, null, 2)}\n`;
    const temporaryPath = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
    writeFileSync(temporaryPath, payload, { mode: 0o600, flag: "wx", flush: true });
    try {
      renameSync(temporaryPath, this.path);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  }
}

export function parsePersistedVoiceCallFile(value: unknown): PersistedVoiceCall[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Voice call store must be an object");
  }
  const record = value as { version?: unknown; calls?: unknown };
  if (record.version !== STORE_VERSION) {
    throw new Error("Voice call store version is unsupported");
  }
  if (!Array.isArray(record.calls)) {
    throw new Error("Voice call store calls must be an array");
  }
  if (record.calls.length > MAX_PERSISTED_CALLS) {
    throw new Error("Voice call capacity is reached");
  }
  return record.calls.map((entry, index) => parsePersistedVoiceCall(entry, index));
}

function parsePersistedVoiceCall(value: unknown, index: number): PersistedVoiceCall {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Voice call store entry ${index} must be an object`);
  }
  const record = value as Record<string, unknown>;
  if (typeof record.callId !== "string")
    throw new Error(`Voice call store entry ${index} is invalid`);
  if (typeof record.controlSessionId !== "string") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.clientCallId !== "string") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.ownerDeviceId !== "string") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (record.lifecycle !== "active" && record.lifecycle !== "ended") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.controllerLeaseEpoch !== "number") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.controllerLeaseExpiresAt !== "number") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.eventSeq !== "number") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (typeof record.startedAt !== "number" || typeof record.updatedAt !== "number") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (record.detachedAt !== undefined && typeof record.detachedAt !== "number") {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  if (!Array.isArray(record.delegations) || !Array.isArray(record.events)) {
    throw new Error(`Voice call store entry ${index} is invalid`);
  }
  return record as unknown as PersistedVoiceCall;
}
