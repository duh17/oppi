import { timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { ConfigStore } from "./config-store.js";

export type IssuedDeviceCredential = {
  deviceToken: string;
};

function secureTokenEquals(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

export class AuthStore {
  constructor(private readonly configStore: ConfigStore) {}

  private static generateOwnerToken(): string {
    return `sk_${generateId(24)}`;
  }

  private static generateAuthDeviceToken(): string {
    return `dt_${generateId(24)}`;
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
    const token = this.configStore.getConfig().token;
    if (token) return token;
    const next = AuthStore.generateOwnerToken();
    this.configStore.updateConfig({ token: next });
    return next;
  }

  rotateToken(): string {
    const token = AuthStore.generateOwnerToken();
    const config = this.configStore.getConfig();
    const revokedAt = Date.now();
    this.configStore.updateConfig({
      token,
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      authDeviceTokens: [],
      authDevices: (config.authDevices ?? []).map((device) => ({ ...device, revokedAt })),
      authAccessTokens: [],
      pushDeviceTokens: [],
      liveActivityToken: undefined,
    });
    return token;
  }

  issuePairingToken(ttlMs: number = 90_000): string {
    const pairingToken = AuthStore.generatePairingToken();
    this.configStore.updateConfig({
      pairingToken,
      pairingTokenExpiresAt: Date.now() + Math.max(1_000, ttlMs),
    });
    return pairingToken;
  }

  private reloadPairingFromDisk(): void {
    try {
      const configPath = this.configStore.getConfigPath();
      if (!existsSync(configPath)) return;
      const raw = JSON.parse(readFileSync(configPath, "utf-8")) as Record<string, unknown>;
      const config = this.configStore.getConfig();
      if (typeof raw.pairingToken === "string") {
        config.pairingToken = raw.pairingToken;
        config.pairingTokenExpiresAt =
          typeof raw.pairingTokenExpiresAt === "number" ? raw.pairingTokenExpiresAt : undefined;
      }
    } catch {
      // Disk read failed — proceed with in-memory state.
    }
  }

  /**
   * Compatibility helper for persisted pre-device-key pairing callers. New
   * pairing goes through DeviceAuthStore and always issues HTTPS credentials.
   */
  consumePairingToken(candidate: string): IssuedDeviceCredential | null {
    this.reloadPairingFromDisk();
    const config = this.configStore.getConfig();
    if (!config.pairingToken || !secureTokenEquals(candidate, config.pairingToken)) {
      return null;
    }
    if (
      typeof config.pairingTokenExpiresAt === "number" &&
      Date.now() > config.pairingTokenExpiresAt
    ) {
      this.configStore.updateConfig({ pairingToken: undefined, pairingTokenExpiresAt: undefined });
      return null;
    }

    let deviceToken = AuthStore.generateAuthDeviceToken();
    const existing = new Set(config.authDeviceTokens ?? []);
    while (existing.has(deviceToken)) deviceToken = AuthStore.generateAuthDeviceToken();
    this.configStore.updateConfig({
      authDeviceTokens: [...existing, deviceToken],
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
    });
    return { deviceToken };
  }

  hasAuthToken(candidate: string): boolean {
    const owner = this.getToken();
    if (owner && secureTokenEquals(owner, candidate)) return true;
    return this.getAuthDeviceTokens().some((token) => secureTokenEquals(token, candidate));
  }

  getOwnerName(): string {
    return hostname().split(".")[0] || "owner";
  }

  getAuthDeviceTokens(): string[] {
    return this.configStore.getConfig().authDeviceTokens || [];
  }

  getPushDeviceTokens(): string[] {
    return this.configStore.getConfig().pushDeviceTokens || [];
  }

  addPushDeviceToken(token: string): void {
    const tokens = this.getPushDeviceTokens();
    if (!tokens.includes(token))
      this.configStore.updateConfig({ pushDeviceTokens: [...tokens, token] });
  }

  setLiveActivityToken(token: string | null): void {
    this.configStore.updateConfig({ liveActivityToken: token || undefined });
  }

  getLiveActivityToken(): string | undefined {
    return this.configStore.getConfig().liveActivityToken;
  }
}
