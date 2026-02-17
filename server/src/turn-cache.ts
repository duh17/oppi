/**
 * Turn deduplication cache — idempotent prompt/steer/follow_up retries.
 *
 * Tracks client-assigned turn IDs with LRU eviction and TTL expiry.
 * Prevents duplicate pi RPC dispatches when the iOS app retries on
 * reconnect or network blips.
 */

import { createHash } from "node:crypto";
import type { TurnAckStage, TurnCommand } from "./types.js";

export interface TurnDedupeRecord {
  command: TurnCommand;
  payloadHash: string;
  stage: TurnAckStage;
  acceptedAt: number;
  updatedAt: number;
}

interface TurnDedupeEntry {
  record: TurnDedupeRecord;
  expiresAt: number;
}

const TURN_STAGE_ORDER: Record<TurnAckStage, number> = {
  accepted: 1,
  dispatched: 2,
  started: 3,
};

export class TurnDedupeCache {
  private entries: Map<string, TurnDedupeEntry> = new Map();

  constructor(
    private readonly capacity = 256,
    private readonly ttlMs = 15 * 60_000,
  ) {}

  get(clientTurnId: string, now = Date.now()): TurnDedupeRecord | null {
    this.purgeExpired(now);
    const entry = this.entries.get(clientTurnId);
    if (!entry) {
      return null;
    }

    if (entry.expiresAt <= now) {
      this.entries.delete(clientTurnId);
      return null;
    }

    this.entries.delete(clientTurnId);
    entry.expiresAt = now + this.ttlMs;
    this.entries.set(clientTurnId, entry);
    return entry.record;
  }

  set(clientTurnId: string, record: TurnDedupeRecord, now = Date.now()): void {
    this.purgeExpired(now);
    this.entries.delete(clientTurnId);
    this.entries.set(clientTurnId, {
      record,
      expiresAt: now + this.ttlMs,
    });
    this.trimToCapacity();
  }

  updateStage(
    clientTurnId: string,
    stage: TurnAckStage,
    now = Date.now(),
  ): TurnDedupeRecord | null {
    const entry = this.entries.get(clientTurnId);
    if (!entry) {
      return null;
    }

    if (entry.expiresAt <= now) {
      this.entries.delete(clientTurnId);
      return null;
    }

    if (TURN_STAGE_ORDER[stage] > TURN_STAGE_ORDER[entry.record.stage]) {
      entry.record.stage = stage;
    }
    entry.record.updatedAt = now;

    this.entries.delete(clientTurnId);
    entry.expiresAt = now + this.ttlMs;
    this.entries.set(clientTurnId, entry);
    return entry.record;
  }

  size(now = Date.now()): number {
    this.purgeExpired(now);
    return this.entries.size;
  }

  private purgeExpired(now: number): void {
    for (const [key, entry] of this.entries) {
      if (entry.expiresAt <= now) {
        this.entries.delete(key);
      }
    }
  }

  private trimToCapacity(): void {
    while (this.entries.size > this.capacity) {
      const oldest = this.entries.keys().next().value;
      if (!oldest) {
        break;
      }
      this.entries.delete(oldest);
    }
  }
}

export function computeTurnPayloadHash(command: TurnCommand, payload: unknown): string {
  return createHash("sha1")
    .update(command)
    .update(":")
    .update(JSON.stringify(payload))
    .digest("hex");
}
