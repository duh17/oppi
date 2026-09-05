import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { ConfigStore } from "./config-store.js";

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
      authDeviceTokens: [],
      authDevices: (config.authDevices ?? []).map((device) => ({ ...device, revokedAt })),
      authAccessTokens: [],
      pushDeviceTokens: [],
      liveActivityToken: undefined,
    }));
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
    this.configStore.mutate((config) => {
      const tokens = config.pushDeviceTokens || [];
      if (tokens.includes(token)) return {};
      return { pushDeviceTokens: [...tokens, token] };
    });
  }

  setLiveActivityToken(token: string | null): void {
    this.configStore.updateConfig({ liveActivityToken: token || undefined });
  }

  getLiveActivityToken(): string | undefined {
    return this.configStore.getConfig().liveActivityToken;
  }
}
