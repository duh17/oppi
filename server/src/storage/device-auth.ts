import {
  createHash,
  createPublicKey,
  randomBytes,
  timingSafeEqual,
  verify as cryptoVerify,
  type JsonWebKey,
} from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { generateId } from "../id.js";
import type { AccessTokenRecord, DevicePublicKey, DeviceRecord } from "../types.js";
import type { ConfigStore } from "./config-store.js";

export const REFRESH_AUDIENCE = "oppi:refresh:v1";
export const ACCESS_TOKEN_TTL_MS = 10 * 60 * 1000;
export const CHALLENGE_TTL_MS = 60 * 1000;
export const CLOCK_SKEW_MS = 30 * 1000;
export const MAX_OUTSTANDING_CHALLENGES = 10_000;
export const MAX_ACTIVE_ACCESS_TOKENS_PER_DEVICE = 2;
export const MAX_REFRESHES_PER_MINUTE_PER_DEVICE = 12;

type ChallengeNonceState = { deviceId: string; expiresAt: number; used: boolean };

type PairingTokenValidation = { ok: true } | { ok: false; status: 400 | 401; error: string };

export type AccessTokenValidation =
  | { ok: true; deviceId: string; scope: DeviceRecord["scope"] }
  | { ok: false; code: "unknown_token" | "expired" | "revoked" };

export type RefreshResult =
  | { ok: true; accessToken: string; expiresAt: number }
  | {
      ok: false;
      code:
        | "unknown_device"
        | "revoked"
        | "unknown_nonce"
        | "nonce_reused"
        | "nonce_expired"
        | "bad_signature"
        | "rate_limited";
    };

export type Challenge = { nonce: string; audience: string; expiresAt: number };

export type EnrollResult = {
  deviceId: string;
  accessToken: string;
  expiresAt: number;
  refreshChallenge: Challenge;
};

function secureTokenEquals(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

function tokenHash(token: string): string {
  return `sha256:${createHash("sha256").update(token, "utf8").digest("hex")}`;
}

function isDevicePublicKey(value: unknown): value is DevicePublicKey {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return (
    record.kty === "EC" &&
    record.crv === "P-256" &&
    typeof record.x === "string" &&
    record.x.length > 0 &&
    typeof record.y === "string" &&
    record.y.length > 0
  );
}

function importDevicePublicKey(publicKey: DevicePublicKey): ReturnType<typeof createPublicKey> {
  return createPublicKey({
    key: publicKey as JsonWebKey,
    format: "jwk",
  });
}

function sameDevicePublicKey(left: DevicePublicKey, right: DevicePublicKey): boolean {
  return (
    left.kty === right.kty && left.crv === right.crv && left.x === right.x && left.y === right.y
  );
}

function derLength(length: number): Buffer {
  return length < 0x80 ? Buffer.from([length]) : Buffer.from([0x81, length]);
}

function derInteger(unsigned: Buffer): Buffer {
  let index = 0;
  while (index < unsigned.length - 1 && unsigned[index] === 0) index += 1;
  let body = unsigned.subarray(index);
  if ((body[0] ?? 0) & 0x80) body = Buffer.concat([Buffer.from([0]), body]);
  return Buffer.concat([Buffer.from([0x02]), derLength(body.length), body]);
}

function rawP1363ToDer(signature: Buffer): Buffer {
  if (signature.length !== 64) throw new Error("ECDSA signature must be 64 bytes");
  const parts = [derInteger(signature.subarray(0, 32)), derInteger(signature.subarray(32))];
  const body = Buffer.concat(parts);
  return Buffer.concat([Buffer.from([0x30]), derLength(body.length), body]);
}

function verifyDeviceSignature(
  publicKey: DevicePublicKey,
  data: Buffer,
  signature: Buffer,
): boolean {
  try {
    return cryptoVerify("sha256", data, importDevicePublicKey(publicKey), rawP1363ToDer(signature));
  } catch {
    return false;
  }
}

export class DeviceAuthStore {
  private readonly challenges = new Map<string, ChallengeNonceState>();
  private readonly refreshesByDevice = new Map<string, number[]>();

  constructor(private readonly configStore: ConfigStore) {}

  private boundedAccessTokens(records: AccessTokenRecord[], now: number): AccessTokenRecord[] {
    const byDevice = new Map<string, Array<{ record: AccessTokenRecord; index: number }>>();
    for (const [index, record] of records.entries()) {
      if (now - CLOCK_SKEW_MS > record.expiresAt) continue;
      const deviceRecords = byDevice.get(record.deviceId) ?? [];
      deviceRecords.push({ record, index });
      byDevice.set(record.deviceId, deviceRecords);
    }
    return [...byDevice.values()].flatMap((deviceRecords) =>
      deviceRecords
        .sort(
          (left, right) =>
            right.record.createdAt - left.record.createdAt || right.index - left.index,
        )
        .slice(0, MAX_ACTIVE_ACCESS_TOKENS_PER_DEVICE)
        .map(({ record }) => record),
    );
  }

  private refreshRateLimited(deviceId: string, now: number): boolean {
    const windowStart = now - 60_000;
    const recent = (this.refreshesByDevice.get(deviceId) ?? []).filter(
      (timestamp) => timestamp > windowStart,
    );
    this.refreshesByDevice.set(deviceId, recent);
    return recent.length >= MAX_REFRESHES_PER_MINUTE_PER_DEVICE;
  }

  private static generateAccessToken(): string {
    return `at_${generateId(24)}`;
  }

  private static generateDeviceId(): string {
    return `dev_${generateId(16)}`;
  }

  private static generateNonce(): string {
    return randomBytes(32).toString("base64url");
  }

  private reloadPairingFromDisk(): void {
    try {
      const path = this.configStore.getConfigPath();
      if (!existsSync(path)) return;
      const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
      const config = this.configStore.getConfig();
      if (typeof raw.pairingToken === "string") {
        config.pairingToken = raw.pairingToken;
        config.pairingTokenExpiresAt =
          typeof raw.pairingTokenExpiresAt === "number" ? raw.pairingTokenExpiresAt : undefined;
      }
    } catch {
      // Another process may be writing config; the in-memory state is safer.
    }
  }

  private validatePairingToken(candidate: string): PairingTokenValidation {
    this.reloadPairingFromDisk();
    const config = this.configStore.getConfig();
    if (!config.pairingToken || !secureTokenEquals(candidate, config.pairingToken)) {
      return { ok: false, status: 401, error: "Invalid or expired pairing token" };
    }
    if (
      typeof config.pairingTokenExpiresAt === "number" &&
      Date.now() > config.pairingTokenExpiresAt
    ) {
      return { ok: false, status: 401, error: "Invalid or expired pairing token" };
    }
    return { ok: true };
  }

  enrollViaPairing(
    candidate: string,
    deviceInput: { publicKey: unknown; name?: unknown },
  ): EnrollResult | null {
    if (!this.validatePairingToken(candidate).ok) return null;
    if (!isDevicePublicKey(deviceInput.publicKey)) return null;
    try {
      importDevicePublicKey(deviceInput.publicKey);
    } catch {
      return null;
    }

    const now = Date.now();
    const device: DeviceRecord = {
      id: DeviceAuthStore.generateDeviceId(),
      name:
        typeof deviceInput.name === "string" && deviceInput.name.trim()
          ? deviceInput.name.trim()
          : "Device",
      publicKey: deviceInput.publicKey,
      scope: "device",
      createdAt: now,
      lastUsedAt: now,
    };
    const accessToken = DeviceAuthStore.generateAccessToken();
    const access: AccessTokenRecord = {
      id: `tok_${generateId(16)}`,
      tokenHash: tokenHash(accessToken),
      deviceId: device.id,
      scope: device.scope,
      createdAt: now,
      expiresAt: now + ACCESS_TOKEN_TTL_MS,
      lastUsedAt: now,
    };
    const config = this.configStore.getConfig();
    this.configStore.updateConfig({
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
      authDevices: [...(config.authDevices ?? []), device],
      authAccessTokens: this.boundedAccessTokens([...(config.authAccessTokens ?? []), access], now),
    });
    const refreshChallenge = this.issueChallenge(device.id);
    if (!refreshChallenge) throw new Error("failed to issue refresh challenge");
    return {
      deviceId: device.id,
      accessToken,
      expiresAt: access.expiresAt,
      refreshChallenge,
    };
  }

  migrateLegacyRecords(): void {
    const config = this.configStore.getConfig();
    const existing = new Map((config.authDevices ?? []).map((device) => [device.id, device]));
    let changed = false;
    for (const token of config.authDeviceTokens ?? []) {
      const id = `dev_${tokenHash(token).slice(7, 23)}`;
      if (existing.has(id)) continue;
      existing.set(id, {
        id,
        name: "Device",
        scope: "device",
        createdAt: Date.now(),
        legacyTokenHash: tokenHash(token),
      });
      changed = true;
    }
    if (changed) this.configStore.updateConfig({ authDevices: [...existing.values()] });
  }

  migrateLegacyDevice(
    candidate: string,
    deviceInput: { publicKey: unknown; name?: unknown },
  ): EnrollResult | null {
    if (this.isMigrationFinalized()) return null;
    this.migrateLegacyRecords();
    const config = this.configStore.getConfig();
    const hash = tokenHash(candidate);
    const existing = (config.authDevices ?? []).find((device) => device.legacyTokenHash === hash);
    if (!existing || !isDevicePublicKey(deviceInput.publicKey)) return null;
    try {
      importDevicePublicKey(deviceInput.publicKey);
    } catch {
      return null;
    }
    if (existing.publicKey && !sameDevicePublicKey(existing.publicKey, deviceInput.publicKey)) {
      return null;
    }
    const device: DeviceRecord = {
      ...existing,
      publicKey: existing.publicKey ?? deviceInput.publicKey,
      name:
        typeof deviceInput.name === "string" && deviceInput.name.trim()
          ? deviceInput.name.trim()
          : existing.name,
      lastUsedAt: Date.now(),
    };
    return this.issueAndPersist(
      device,
      (config.authDevices ?? []).map((item) => (item.id === device.id ? device : item)),
    );
  }

  private issueAndPersist(device: DeviceRecord, devices: DeviceRecord[]): EnrollResult {
    const now = Date.now();
    const accessToken = DeviceAuthStore.generateAccessToken();
    const access: AccessTokenRecord = {
      id: `tok_${generateId(16)}`,
      tokenHash: tokenHash(accessToken),
      deviceId: device.id,
      scope: device.scope,
      createdAt: now,
      expiresAt: now + ACCESS_TOKEN_TTL_MS,
      lastUsedAt: now,
    };
    this.configStore.updateConfig({
      authDevices: devices,
      authAccessTokens: this.boundedAccessTokens(
        [...(this.configStore.getConfig().authAccessTokens ?? []), access],
        now,
      ),
    });
    const refreshChallenge = this.issueChallenge(device.id);
    if (!refreshChallenge) throw new Error("failed to issue refresh challenge");
    return {
      deviceId: device.id,
      accessToken,
      expiresAt: access.expiresAt,
      refreshChallenge,
    };
  }

  isMigrationFinalized(): boolean {
    return this.configStore.getConfig().authMigrationMode === "finalized";
  }

  setMigrationFinalized(finalized: boolean): void {
    this.configStore.updateConfig({ authMigrationMode: finalized ? "finalized" : "compat" });
  }

  issueChallenge(deviceId: string): Challenge | null {
    const device = (this.configStore.getConfig().authDevices ?? []).find(
      (item) => item.id === deviceId,
    );
    if (!device || device.revokedAt !== undefined || !device.publicKey) return null;

    const now = Date.now();
    for (const [nonce, state] of this.challenges) {
      if (state.used || now - CLOCK_SKEW_MS > state.expiresAt) {
        this.challenges.delete(nonce);
        continue;
      }
      if (state.deviceId === deviceId) {
        return { nonce, audience: REFRESH_AUDIENCE, expiresAt: state.expiresAt };
      }
    }

    const nonce = DeviceAuthStore.generateNonce();
    const expiresAt = now + CHALLENGE_TTL_MS;
    if (this.challenges.size >= MAX_OUTSTANDING_CHALLENGES) {
      const oldest = this.challenges.keys().next().value;
      if (oldest) this.challenges.delete(oldest);
    }
    this.challenges.set(nonce, { deviceId, expiresAt, used: false });
    return { nonce, audience: REFRESH_AUDIENCE, expiresAt };
  }

  refresh(input: { deviceId: string; nonce: string; signature: unknown }): RefreshResult {
    const config = this.configStore.getConfig();
    const device = (config.authDevices ?? []).find((item) => item.id === input.deviceId);
    if (!device) return { ok: false, code: "unknown_device" };
    if (device.revokedAt !== undefined) return { ok: false, code: "revoked" };
    if (!device.publicKey) return { ok: false, code: "unknown_device" };
    const state = this.challenges.get(input.nonce);
    if (!state || state.deviceId !== input.deviceId) return { ok: false, code: "unknown_nonce" };
    if (state.used) return { ok: false, code: "nonce_reused" };
    if (Date.now() - CLOCK_SKEW_MS > state.expiresAt) return { ok: false, code: "nonce_expired" };
    if (typeof input.signature !== "string") return { ok: false, code: "bad_signature" };
    const signature = Buffer.from(input.signature, "base64url");
    if (
      signature.length !== 64 ||
      !verifyDeviceSignature(
        device.publicKey,
        Buffer.from(`${REFRESH_AUDIENCE}.${input.nonce}`),
        signature,
      )
    ) {
      return { ok: false, code: "bad_signature" };
    }
    const now = Date.now();
    if (this.refreshRateLimited(device.id, now)) {
      return { ok: false, code: "rate_limited" };
    }
    this.challenges.set(input.nonce, { ...state, used: true });
    const accessToken = DeviceAuthStore.generateAccessToken();
    const access: AccessTokenRecord = {
      id: `tok_${generateId(16)}`,
      tokenHash: tokenHash(accessToken),
      deviceId: device.id,
      scope: device.scope,
      createdAt: now,
      expiresAt: now + ACCESS_TOKEN_TTL_MS,
      lastUsedAt: now,
    };
    this.configStore.updateConfig({
      authDevices: (config.authDevices ?? []).map((item) =>
        item.id === device.id ? { ...item, lastUsedAt: now } : item,
      ),
      authAccessTokens: this.boundedAccessTokens([...(config.authAccessTokens ?? []), access], now),
    });
    this.refreshesByDevice.set(device.id, [...(this.refreshesByDevice.get(device.id) ?? []), now]);
    return { ok: true, accessToken, expiresAt: access.expiresAt };
  }

  validateAccessToken(candidate: string): AccessTokenValidation {
    const config = this.configStore.getConfig();
    const now = Date.now();
    const existing = config.authAccessTokens ?? [];
    const bounded = this.boundedAccessTokens(existing, now);
    if (bounded.length !== existing.length) {
      this.configStore.updateConfig({ authAccessTokens: bounded });
    }
    const candidateHash = tokenHash(candidate);
    const access = existing.find((item) => secureTokenEquals(item.tokenHash, candidateHash));
    if (!access) return { ok: false, code: "unknown_token" };
    if (now - CLOCK_SKEW_MS > access.expiresAt) return { ok: false, code: "expired" };
    if (!bounded.some((item) => item.id === access.id)) {
      return { ok: false, code: "unknown_token" };
    }
    const device = (config.authDevices ?? []).find((item) => item.id === access.deviceId);
    if (!device || device.revokedAt !== undefined) return { ok: false, code: "revoked" };
    return { ok: true, deviceId: device.id, scope: device.scope };
  }

  deviceIdForAccessToken(candidate: string): string | undefined {
    const hash = tokenHash(candidate);
    return (this.configStore.getConfig().authAccessTokens ?? []).find(
      (item) => item.tokenHash === hash,
    )?.deviceId;
  }

  commitLegacyRevocation(deviceId: string): boolean {
    const config = this.configStore.getConfig();
    const target = (config.authDevices ?? []).find((device) => device.id === deviceId);
    if (!target?.legacyTokenHash) return false;
    const hash = target.legacyTokenHash;
    this.configStore.updateConfig({
      authDeviceTokens: (config.authDeviceTokens ?? []).filter(
        (token) => tokenHash(token) !== hash,
      ),
      authDevices: (config.authDevices ?? []).map((device) =>
        device.id === deviceId ? { ...device, legacyTokenHash: undefined } : device,
      ),
    });
    return true;
  }

  revokeDevice(deviceId: string): boolean {
    this.migrateLegacyRecords();
    const config = this.configStore.getConfig();
    const target = (config.authDevices ?? []).find((device) => device.id === deviceId);
    if (!target || target.revokedAt !== undefined) return false;
    const hash = target.legacyTokenHash;
    this.configStore.updateConfig({
      authDevices: (config.authDevices ?? []).map((device) =>
        device.id === deviceId ? { ...device, revokedAt: Date.now() } : device,
      ),
      authAccessTokens: (config.authAccessTokens ?? []).filter(
        (item) => item.deviceId !== deviceId,
      ),
      ...(hash
        ? {
            authDeviceTokens: (config.authDeviceTokens ?? []).filter(
              (token) => tokenHash(token) !== hash,
            ),
          }
        : {}),
    });
    return true;
  }

  listDevices(): DeviceRecord[] {
    this.migrateLegacyRecords();
    return this.configStore.getConfig().authDevices ?? [];
  }

  deviceIdForLegacyToken(candidate: string): string | undefined {
    this.migrateLegacyRecords();
    const hash = tokenHash(candidate);
    return (this.configStore.getConfig().authDevices ?? []).find(
      (device) => device.legacyTokenHash === hash,
    )?.id;
  }

  clearChallenges(): void {
    this.challenges.clear();
  }
}
