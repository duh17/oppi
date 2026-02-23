import { existsSync, readFileSync } from "node:fs";
import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { ConfigStore } from "./config-store.js";

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

  /** Whether the server has been paired (has a bearer token). */
  isPaired(): boolean {
    return !!this.configStore.getConfig().token;
  }

  /** Get the bearer token (undefined if not paired). */
  getToken(): string | undefined {
    return this.configStore.getConfig().token;
  }

  /** Generate a new token and save to config. Returns the token. */
  ensurePaired(): string {
    const token = this.configStore.getConfig().token;
    if (token) return token;

    const next = AuthStore.generateOwnerToken();
    this.configStore.updateConfig({ token: next });
    return next;
  }

  /** Rotate the bearer token. Existing clients will need to re-pair. */
  rotateToken(): string {
    const token = AuthStore.generateOwnerToken();
    this.configStore.updateConfig({ token });
    return token;
  }

  /** Issue a one-time short-lived pairing token used by POST /pair. */
  issuePairingToken(ttlMs: number = 90_000): string {
    const pairingToken = AuthStore.generatePairingToken();
    const expiresAt = Date.now() + Math.max(1_000, ttlMs);
    this.configStore.updateConfig({ pairingToken, pairingTokenExpiresAt: expiresAt });
    return pairingToken;
  }

  /**
   * Reload pairing-related fields from disk.
   *
   * The `oppi pair` CLI runs in a separate process and writes a fresh
   * pairingToken + expiry to config.json. The running server must pick
   * those up so that POST /pair succeeds without a restart.
   *
   * Only pairing fields are merged — everything else stays in-memory to
   * avoid clobbering runtime state (auth tokens, push tokens, etc.).
   */
  private reloadPairingFromDisk(): void {
    try {
      const configPath = this.configStore.getConfigPath();
      if (!existsSync(configPath)) return;

      const raw = JSON.parse(readFileSync(configPath, "utf-8")) as Record<string, unknown>;
      const config = this.configStore.getConfig();

      if (typeof raw.pairingToken === "string" && raw.pairingToken !== config.pairingToken) {
        config.pairingToken = raw.pairingToken;
        config.pairingTokenExpiresAt =
          typeof raw.pairingTokenExpiresAt === "number" ? raw.pairingTokenExpiresAt : undefined;
      }
    } catch {
      // Disk read failed — proceed with in-memory state.
    }
  }

  /** Consume pairing token atomically and issue a long-lived auth device token. */
  consumePairingToken(candidate: string): string | null {
    // Reload from disk in case `oppi pair` wrote a token in another process.
    this.reloadPairingFromDisk();

    const config = this.configStore.getConfig();
    const pairingToken = config.pairingToken;
    const expiresAt = config.pairingTokenExpiresAt;

    if (!pairingToken || candidate !== pairingToken) {
      return null;
    }

    if (typeof expiresAt === "number" && Date.now() > expiresAt) {
      this.configStore.updateConfig({ pairingToken: undefined, pairingTokenExpiresAt: undefined });
      return null;
    }

    let deviceToken = AuthStore.generateAuthDeviceToken();
    const existing = new Set(config.authDeviceTokens || []);
    while (existing.has(deviceToken)) {
      deviceToken = AuthStore.generateAuthDeviceToken();
    }

    this.configStore.updateConfig({
      authDeviceTokens: [...existing, deviceToken],
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
    });

    return deviceToken;
  }

  /** Owner display name derived from hostname. */
  getOwnerName(): string {
    return hostname().split(".")[0] || "owner";
  }

  addAuthDeviceToken(token: string): void {
    const tokens = this.configStore.getConfig().authDeviceTokens || [];
    if (!tokens.includes(token)) {
      this.configStore.updateConfig({ authDeviceTokens: [...tokens, token] });
    }
  }

  removeAuthDeviceToken(token: string): void {
    const tokens = this.configStore.getConfig().authDeviceTokens || [];
    this.configStore.updateConfig({ authDeviceTokens: tokens.filter((t) => t !== token) });
  }

  getAuthDeviceTokens(): string[] {
    return this.configStore.getConfig().authDeviceTokens || [];
  }

  addPushDeviceToken(token: string): void {
    const tokens = this.configStore.getConfig().pushDeviceTokens || [];
    if (!tokens.includes(token)) {
      this.configStore.updateConfig({ pushDeviceTokens: [...tokens, token] });
    }
  }

  removePushDeviceToken(token: string): void {
    const tokens = this.configStore.getConfig().pushDeviceTokens || [];
    this.configStore.updateConfig({ pushDeviceTokens: tokens.filter((t) => t !== token) });
  }

  getPushDeviceTokens(): string[] {
    return this.configStore.getConfig().pushDeviceTokens || [];
  }

  setLiveActivityToken(token: string | null): void {
    this.configStore.updateConfig({ liveActivityToken: token || undefined });
  }

  getLiveActivityToken(): string | undefined {
    return this.configStore.getConfig().liveActivityToken;
  }
}
