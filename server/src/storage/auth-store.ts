import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { PushDeviceToken, PushTokenType } from "../types.js";
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

  rotateToken(): string {
    const token = AuthStore.generateOwnerToken();
    const revokedAt = Date.now();
    this.configStore.mutate((config) => ({
      token,
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      authDevices: (config.authDevices ?? []).map((device) => ({ ...device, revokedAt })),
      authAccessTokens: [],
      pushDeviceTokens: [],
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

  getPushDeviceTokens(tokenType: PushTokenType): PushDeviceToken[] {
    return (this.configStore.getConfig().pushDeviceTokens ?? []).filter(
      (entry) => entry.tokenType === tokenType,
    );
  }

  /**
   * Store a device's token of one type, replacing its previous one. The token value moves
   * off any other device (a re-paired install keeps its APNs token). Returns false, storing
   * nothing, when the device is unknown or revoked by the time the write runs.
   */
  registerPushDeviceToken(registration: Omit<PushDeviceToken, "registeredAt">): boolean {
    let stored = false;
    this.configStore.mutate((config) => {
      const device = (config.authDevices ?? []).find((item) => item.id === registration.deviceId);
      if (!device || device.revokedAt !== undefined) return {};
      stored = true;
      const kept = (config.pushDeviceTokens ?? []).filter(
        (entry) =>
          entry.token !== registration.token &&
          !(entry.deviceId === registration.deviceId && entry.tokenType === registration.tokenType),
      );
      return { pushDeviceTokens: [...kept, { ...registration, registeredAt: Date.now() }] };
    });
    return stored;
  }

  /** Drop a token APNs rejected or a finished Live Activity no longer uses. */
  removePushDeviceToken(token: string): boolean {
    let removed = false;
    this.configStore.mutate((config) => {
      const tokens = config.pushDeviceTokens ?? [];
      const kept = tokens.filter((entry) => entry.token !== token);
      if (kept.length === tokens.length) return {};
      removed = true;
      return { pushDeviceTokens: kept };
    });
    return removed;
  }
}
