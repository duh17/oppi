import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { PushRegistration } from "../types.js";
import type { ConfigStore } from "./config-store.js";

/** Longest pairing invite life. Bounds how long a leaked single-use link can pair a device. */
export const MAX_PAIRING_TOKEN_TTL_MS = 30 * 86_400_000;

export class AuthStore {
  constructor(private readonly configStore: ConfigStore) {}

  private static generateOwnerToken(): string {
    return `sk_${generateId(24)}`;
  }

  private static generatePairingToken(): string {
    return `pt_${generateId(24)}`;
  }

  isPaired(): boolean {
    return !!this.configStore.getConfig().token;
  }

  getToken(): string | undefined {
    return this.configStore.getConfig().token;
  }

  ensurePaired(): string {
    const config = this.configStore.mutate((current) => {
      if (current.token) return {};
      return { token: AuthStore.generateOwnerToken() };
    });
    if (!config.token) throw new Error("Failed to ensure owner token");
    return config.token;
  }

  /** New owner token; every paired device is revoked and loses its push registration. */
  rotateToken(): string {
    const token = AuthStore.generateOwnerToken();
    const revokedAt = Date.now();
    this.configStore.mutate((config) => ({
      token,
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      authDevices: (config.authDevices ?? []).map((device) => ({ ...device, revokedAt })),
      authAccessTokens: [],
      pushRegistrations: [],
    }));
    return token;
  }

  issuePairingToken(ttlMs: number = 90_000): string {
    // Reject before writing: an invalid ttl must not replace the outstanding invite.
    if (!Number.isFinite(ttlMs) || ttlMs > MAX_PAIRING_TOKEN_TTL_MS) {
      throw new Error("Pairing token ttl must be finite and at most 30d");
    }
    const pairingToken = AuthStore.generatePairingToken();
    this.configStore.updateConfig({
      pairingToken,
      pairingTokenExpiresAt: Date.now() + Math.max(1_000, ttlMs),
    });
    return pairingToken;
  }

  /** Invalidate the outstanding pairing invite without issuing a replacement. */
  clearPairingToken(): void {
    this.configStore.updateConfig({
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
    });
  }

  getOwnerName(): string {
    return hostname().split(".")[0] || "owner";
  }

  getPushRegistrations(): PushRegistration[] {
    return this.configStore.getConfig().pushRegistrations ?? [];
  }

  /**
   * Store a device's push registration, replacing its previous one. Sequence numbers start
   * at 1 for a new key and continue for the same key. Returns the replaced registration when
   * its send token differs (the caller releases it at the relay), `null` when there was none,
   * and `false`, storing nothing, when the device is unknown or revoked when the write runs.
   */
  setPushRegistration(
    registration: Omit<PushRegistration, "registeredAt" | "nextSeq">,
  ): PushRegistration | null | false {
    let result: PushRegistration | null | false = false;
    this.configStore.mutate((config) => {
      const device = (config.authDevices ?? []).find((item) => item.id === registration.deviceId);
      if (!device || device.revokedAt !== undefined) return {};
      const existing = (config.pushRegistrations ?? []).find(
        (entry) => entry.deviceId === registration.deviceId,
      );
      result = existing && existing.sendToken !== registration.sendToken ? existing : null;
      const nextSeq = existing?.keyId === registration.keyId ? existing.nextSeq : 1;
      const kept = (config.pushRegistrations ?? []).filter(
        (entry) => entry.deviceId !== registration.deviceId,
      );
      return {
        pushRegistrations: [...kept, { ...registration, registeredAt: Date.now(), nextSeq }],
      };
    });
    return result;
  }

  /**
   * Reserve the next sequence number for a device's current key, persisted before the push
   * is sealed so a restart never reuses one. Null when the device has no registration for
   * that key any more.
   */
  takePushSequence(deviceId: string, keyId: string): number | null {
    let seq: number | null = null;
    this.configStore.mutate((config) => {
      const registrations = config.pushRegistrations ?? [];
      const current = registrations.find(
        (entry) => entry.deviceId === deviceId && entry.keyId === keyId,
      );
      if (!current) return {};
      seq = current.nextSeq;
      return {
        pushRegistrations: registrations.map((entry) =>
          entry === current ? { ...entry, nextSeq: entry.nextSeq + 1 } : entry,
        ),
      };
    });
    return seq;
  }

  /**
   * Forget a device's registration. With `sendToken`, only when it still holds that token, so
   * a stale relay `410` cannot remove a newer registration. Returns the removed registration.
   */
  removePushRegistration(deviceId: string, sendToken?: string): PushRegistration | null {
    let removed: PushRegistration | null = null;
    this.configStore.mutate((config) => {
      const registrations = config.pushRegistrations ?? [];
      const match = registrations.find(
        (entry) =>
          entry.deviceId === deviceId && (sendToken === undefined || entry.sendToken === sendToken),
      );
      if (!match) return {};
      removed = match;
      return { pushRegistrations: registrations.filter((entry) => entry !== match) };
    });
    return removed;
  }
}
