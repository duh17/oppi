/**
 * In-memory relay store for the Node adapter, optionally persisted to one JSON file.
 * Node runs JavaScript on one thread and no method awaits between reading and writing a
 * record, so each operation is atomic per registration.
 */

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import {
  applyAddPermission,
  applyAssertionCounter,
  applyAuthorizePush,
  applyDeletePermission,
  DEFAULT_QUOTA_LIMITS,
  type AddPermissionResult,
  type PermissionRecord,
  type PushAuthorization,
  type QuotaLimits,
  type RegistrationRecord,
  type RelayStore,
} from "../core/store.js";

interface Snapshot {
  registrations: RegistrationRecord[];
}

export class MemoryRelayStore implements RelayStore {
  private readonly challenges = new Map<string, number>();
  private readonly registrations = new Map<string, RegistrationRecord>();

  constructor(
    private readonly options: { persistPath?: string; limits?: QuotaLimits } = {},
  ) {
    if (options.persistPath) {
      try {
        const snapshot = JSON.parse(readFileSync(options.persistPath, "utf8")) as Snapshot;
        for (const record of snapshot.registrations) this.registrations.set(record.id, record);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
  }

  /** Everything the store holds, for inspection: what a relay operator could read. */
  dump(): string {
    return JSON.stringify({
      challenges: [...this.challenges.entries()],
      registrations: [...this.registrations.values()],
    });
  }

  private persist(): void {
    if (!this.options.persistPath) return;
    const snapshot: Snapshot = { registrations: [...this.registrations.values()] };
    const temp = `${this.options.persistPath}.tmp`;
    writeFileSync(temp, JSON.stringify(snapshot), { mode: 0o600 });
    renameSync(temp, this.options.persistPath);
  }

  async putChallenge(challenge: string, expiresAt: number): Promise<void> {
    this.challenges.set(challenge, expiresAt);
  }

  async consumeChallenge(challenge: string, now: number): Promise<boolean> {
    for (const [key, expiresAt] of this.challenges) {
      if (expiresAt < now) this.challenges.delete(key);
    }
    const expiresAt = this.challenges.get(challenge);
    this.challenges.delete(challenge);
    return expiresAt !== undefined && expiresAt >= now;
  }

  async createRegistration(record: RegistrationRecord): Promise<void> {
    this.registrations.set(record.id, structuredClone(record));
    this.persist();
  }

  async getRegistration(id: string): Promise<RegistrationRecord | null> {
    const record = this.registrations.get(id);
    return record ? structuredClone(record) : null;
  }

  async deleteRegistration(id: string): Promise<void> {
    if (this.registrations.delete(id)) this.persist();
  }

  async advanceAssertionCounter(id: string, counter: number): Promise<boolean> {
    const record = this.registrations.get(id);
    if (!record || !applyAssertionCounter(record, counter)) return false;
    this.persist();
    return true;
  }

  async addPermission(id: string, permission: PermissionRecord): Promise<AddPermissionResult> {
    const record = this.registrations.get(id);
    if (!record) return "gone";
    const result = applyAddPermission(record, permission);
    if (result === "ok") this.persist();
    return result;
  }

  async deletePermission(id: string, permissionId: string): Promise<void> {
    const record = this.registrations.get(id);
    if (!record) return;
    applyDeletePermission(record, permissionId);
    this.persist();
  }

  async authorizePush(
    id: string,
    permissionId: string,
    secretHash: string,
    now: number,
  ): Promise<PushAuthorization> {
    const record = this.registrations.get(id);
    if (!record) return { ok: false, reason: "gone" };
    const result = applyAuthorizePush(
      record,
      permissionId,
      secretHash,
      now,
      this.options.limits ?? DEFAULT_QUOTA_LIMITS,
    );
    if (result.ok) this.persist();
    return result;
  }
}
