import { timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { hostname } from "node:os";
import { generateId } from "../id.js";
import type { AuthTransport } from "../types.js";
import type { ConfigStore } from "./config-store.js";

type PairingTokenOptions = {
  allowedTransports?: AuthTransport[];
};

type ConsumePairingTokenOptions = {
  irohClientNodeId?: string;
  allowedTransports?: AuthTransport[];
};

export type IrohTokenValidationResult =
  | { ok: true }
  | {
      ok: false;
      code: "unknown_token" | "forbidden_transport" | "binding_missing" | "binding_mismatch";
    };

const IROH_LAST_SEEN_WRITE_INTERVAL_MS = 5 * 60_000;

function secureTokenEquals(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

function normalizeAuthTransports(value: unknown): AuthTransport[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const transports = value.filter(
    (transport): transport is AuthTransport => transport === "http" || transport === "iroh",
  );
  return transports.length > 0 ? [...new Set(transports)] : undefined;
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

  /** Rotate owner auth and invalidate every client credential derived from pairing. */
  rotateToken(): string {
    const token = AuthStore.generateOwnerToken();
    this.configStore.updateConfig({
      token,
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      pairingTokenAllowedTransports: undefined,
      authDeviceTokens: [],
      irohDeviceTokenBindings: [],
      pushDeviceTokens: [],
      liveActivityToken: undefined,
    });
    return token;
  }

  /** Issue a one-time short-lived pairing token used by POST /pair. */
  issuePairingToken(ttlMs: number = 90_000, options?: PairingTokenOptions): string {
    const pairingToken = AuthStore.generatePairingToken();
    const expiresAt = Date.now() + Math.max(1_000, ttlMs);
    this.configStore.updateConfig({
      pairingToken,
      pairingTokenExpiresAt: expiresAt,
      pairingTokenAllowedTransports: normalizeAuthTransports(options?.allowedTransports),
    });
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

      if (typeof raw.pairingToken === "string") {
        config.pairingToken = raw.pairingToken;
        config.pairingTokenExpiresAt =
          typeof raw.pairingTokenExpiresAt === "number" ? raw.pairingTokenExpiresAt : undefined;
        config.pairingTokenAllowedTransports = normalizeAuthTransports(
          raw.pairingTokenAllowedTransports,
        );
      }
    } catch {
      // Disk read failed — proceed with in-memory state.
    }
  }

  /** Consume pairing token atomically and issue a long-lived auth device token. */
  consumePairingToken(candidate: string, options?: ConsumePairingTokenOptions): string | null {
    // Reload from disk in case `oppi pair` wrote a token in another process.
    this.reloadPairingFromDisk();

    const config = this.configStore.getConfig();
    const pairingToken = config.pairingToken;
    const expiresAt = config.pairingTokenExpiresAt;

    if (!pairingToken || !secureTokenEquals(candidate, pairingToken)) {
      return null;
    }

    if (typeof expiresAt === "number" && Date.now() > expiresAt) {
      this.configStore.updateConfig({
        pairingToken: undefined,
        pairingTokenExpiresAt: undefined,
        pairingTokenAllowedTransports: undefined,
      });
      return null;
    }

    const requestedTransport: AuthTransport = options?.irohClientNodeId ? "iroh" : "http";
    const pairingAllowedTransports = normalizeAuthTransports(config.pairingTokenAllowedTransports);
    if (pairingAllowedTransports && !pairingAllowedTransports.includes(requestedTransport)) {
      return null;
    }

    let deviceToken = AuthStore.generateAuthDeviceToken();
    const existing = new Set(config.authDeviceTokens || []);
    while (existing.has(deviceToken)) {
      deviceToken = AuthStore.generateAuthDeviceToken();
    }

    const updates = {
      authDeviceTokens: [...existing, deviceToken],
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      pairingTokenAllowedTransports: undefined,
    };

    if (options?.irohClientNodeId) {
      const allowedTransports = pairingAllowedTransports ??
        normalizeAuthTransports(options.allowedTransports) ?? ["iroh", "http"];

      const existingBindings = config.irohDeviceTokenBindings || [];
      this.configStore.updateConfig({
        ...updates,
        irohDeviceTokenBindings: [
          ...existingBindings.filter((binding) => binding.token !== deviceToken),
          {
            token: deviceToken,
            clientNodeId: options.irohClientNodeId,
            allowedTransports,
            createdAt: Date.now(),
          },
        ],
      });
    } else {
      this.configStore.updateConfig(updates);
    }

    return deviceToken;
  }

  hasAuthToken(candidate: string): boolean {
    return this.hasAuthTokenForTransport(candidate, "http");
  }

  hasAuthTokenForTransport(candidate: string, transport: AuthTransport): boolean {
    const configToken = this.getToken();
    if (configToken && secureTokenEquals(configToken, candidate)) return true;

    if (!this.getAuthDeviceTokens().some((token) => secureTokenEquals(token, candidate))) {
      return false;
    }

    const binding = (this.configStore.getConfig().irohDeviceTokenBindings || []).find(
      (candidateBinding) => secureTokenEquals(candidateBinding.token, candidate),
    );
    if (!binding) {
      return transport === "http";
    }

    return binding.allowedTransports.includes(transport);
  }

  validateIrohDeviceToken(candidate: string, clientNodeId: string): IrohTokenValidationResult {
    if (!this.getAuthDeviceTokens().some((token) => secureTokenEquals(token, candidate))) {
      return { ok: false, code: "unknown_token" };
    }

    const bindings = this.configStore.getConfig().irohDeviceTokenBindings || [];
    const binding = bindings.find((candidateBinding) =>
      secureTokenEquals(candidateBinding.token, candidate),
    );
    if (!binding) {
      return { ok: false, code: "binding_missing" };
    }
    if (!binding.allowedTransports.includes("iroh")) {
      return { ok: false, code: "forbidden_transport" };
    }
    if (!secureTokenEquals(binding.clientNodeId, clientNodeId)) {
      return { ok: false, code: "binding_mismatch" };
    }

    const now = Date.now();
    if (
      binding.lastSeenAt === undefined ||
      now - binding.lastSeenAt >= IROH_LAST_SEEN_WRITE_INTERVAL_MS
    ) {
      this.configStore.updateConfig({
        irohDeviceTokenBindings: bindings.map((candidateBinding) =>
          secureTokenEquals(candidateBinding.token, candidate)
            ? { ...candidateBinding, lastSeenAt: now }
            : candidateBinding,
        ),
      });
    }

    return { ok: true };
  }

  /** Owner display name derived from hostname. */
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
    const tokens = this.configStore.getConfig().pushDeviceTokens || [];
    if (!tokens.includes(token)) {
      this.configStore.updateConfig({ pushDeviceTokens: [...tokens, token] });
    }
  }

  setLiveActivityToken(token: string | null): void {
    this.configStore.updateConfig({ liveActivityToken: token || undefined });
  }

  getLiveActivityToken(): string | undefined {
    return this.configStore.getConfig().liveActivityToken;
  }
}
