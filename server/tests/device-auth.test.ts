import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Storage } from "../src/storage.js";
import { redactLogString } from "../src/log-redact.js";
import {
  ACCESS_TOKEN_TTL_MS,
  CLOCK_SKEW_MS,
  MAX_ACTIVE_ACCESS_TOKENS_PER_DEVICE,
  REFRESH_AUDIENCE,
} from "../src/storage/device-auth.js";
import type { DevicePublicKey } from "../src/types.js";

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-device-auth-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

type DeviceKey = {
  publicKeyJwk: DevicePublicKey;
  sign: (data: Buffer) => string;
};

function makeDeviceKey(): DeviceKey {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return {
    publicKeyJwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    sign: (data: Buffer) =>
      cryptoSign("sha256", data, { key: privateKey, dsaEncoding: "ieee-p1363" }).toString(
        "base64url",
      ),
  };
}

function signChallenge(key: DeviceKey, nonce: string): string {
  return key.sign(Buffer.from(`${REFRESH_AUDIENCE}.${nonce}`, "utf8"));
}

function enroll(key: DeviceKey = makeDeviceKey()) {
  const pairingToken = storage.issuePairingToken(60_000);
  const result = storage.enrollViaPairing(
    pairingToken,
    { publicKey: key.publicKeyJwk, name: "iPhone" },
  );
  if (!result) throw new Error("enrollment failed");
  return result;
}
describe("device-auth refresh", () => {
  it("refreshes one device and prunes older refresh history", () => {
    const key = makeDeviceKey();
    const enrolled = enroll(key);
    const issued = [enrolled.accessToken];

    for (let index = 0; index < MAX_ACTIVE_ACCESS_TOKENS_PER_DEVICE + 3; index += 1) {
      const challenge = storage.issueChallenge(enrolled.deviceId);
      if (!challenge) throw new Error("no challenge");
      const result = storage.refresh({
        deviceId: enrolled.deviceId,
        nonce: challenge.nonce,
        signature: signChallenge(key, challenge.nonce),
      });
      if (!result.ok) throw new Error(`refresh failed: ${result.code}`);
      issued.push(result.accessToken);
    }

    const retained = storage.getConfig().authAccessTokens?.filter(
      (token) => token.deviceId === enrolled.deviceId,
    ) ?? [];
    expect(retained).toHaveLength(MAX_ACTIVE_ACCESS_TOKENS_PER_DEVICE);
    expect(storage.validateAccessToken(issued.at(-1) as string).ok).toBe(true);
    expect(storage.validateAccessToken(issued[0])).toEqual({
      ok: false,
      code: "unknown_token",
    });
  });

  it("rejects a replayed nonce", () => {
    const key = makeDeviceKey();
    const enrolled = enroll(key);
    const challenge = storage.issueChallenge(enrolled.deviceId);
    if (!challenge) throw new Error("no challenge");

    const signature = signChallenge(key, challenge.nonce);
    const first = storage.refresh({
      deviceId: enrolled.deviceId,
      nonce: challenge.nonce,
      signature,
    });
    expect(first.ok).toBe(true);

    const replay = storage.refresh({
      deviceId: enrolled.deviceId,
      nonce: challenge.nonce,
      signature,
    });
    expect(replay).toEqual({ ok: false, code: "nonce_reused" });
  });

  it("rejects a bad signature", () => {
    const key = makeDeviceKey();
    const enrolled = enroll(key);
    const challenge = storage.issueChallenge(enrolled.deviceId);
    if (!challenge) throw new Error("no challenge");

    const otherKey = makeDeviceKey();
    const result = storage.refresh({
      deviceId: enrolled.deviceId,
      nonce: challenge.nonce,
      signature: signChallenge(otherKey, challenge.nonce),
    });
    expect(result).toEqual({ ok: false, code: "bad_signature" });
  });

  it("rejects an unknown or expired nonce (server restart clears nonces)", () => {
    const key = makeDeviceKey();
    const enrolled = enroll(key);
    const result = storage.refresh({
      deviceId: enrolled.deviceId,
      nonce: "stale-nonce",
      signature: signChallenge(key, "stale-nonce"),
    });
    expect(result).toEqual({ ok: false, code: "unknown_nonce" });
  });

  it("rejects refresh for a revoked device", () => {
    const key = makeDeviceKey();
    const enrolled = enroll(key);
    const challenge = storage.issueChallenge(enrolled.deviceId);
    if (!challenge) throw new Error("no challenge");
    storage.revokeDevice(enrolled.deviceId);

    const result = storage.refresh({
      deviceId: enrolled.deviceId,
      nonce: challenge.nonce,
      signature: signChallenge(key, challenge.nonce),
    });
    expect(result).toEqual({ ok: false, code: "revoked" });
  });

});

describe("access-token validation", () => {
  it("expires access tokens after the TTL plus skew window", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
      const enrolled = enroll();
      expect(storage.validateAccessToken(enrolled.accessToken).ok).toBe(true);

      vi.setSystemTime(new Date(Date.now() + ACCESS_TOKEN_TTL_MS + CLOCK_SKEW_MS + 1));
      expect(storage.validateAccessToken(enrolled.accessToken)).toEqual({
        ok: false,
        code: "expired",
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("accepts tokens within the clock-skew window", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
      const enrolled = enroll();
      vi.setSystemTime(new Date(Date.now() + ACCESS_TOKEN_TTL_MS + CLOCK_SKEW_MS - 1));
      expect(storage.validateAccessToken(enrolled.accessToken).ok).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects unknown tokens and owner sk_ tokens", () => {
    expect(storage.validateAccessToken("at_nonexistent")).toEqual({
      ok: false,
      code: "unknown_token",
    });
    // The owner token is never an access token.
    storage.ensurePaired();
    expect(storage.validateAccessToken(storage.getToken() as string)).toEqual({
      ok: false,
      code: "unknown_token",
    });
  });

  it("rejects access tokens after device revocation", () => {
    const enrolled = enroll();
    expect(storage.validateAccessToken(enrolled.accessToken).ok).toBe(true);
    storage.revokeDevice(enrolled.deviceId);
    // Revocation prunes the device's access tokens; the token no longer exists.
    expect(storage.validateAccessToken(enrolled.accessToken)).toEqual({
      ok: false,
      code: "unknown_token",
    });
  });
});

describe("per-device revocation", () => {
  it("revokes one device without invalidating another", () => {
    const first = enroll();
    const second = enroll();

    expect(storage.revokeDevice(first.deviceId)).toBe(true);
    expect(storage.validateAccessToken(first.accessToken)).toEqual({
      ok: false,
      code: "unknown_token",
    });
    expect(storage.validateAccessToken(second.accessToken).ok).toBe(true);
    expect(storage.revokeDevice(first.deviceId)).toBe(false); // idempotent
  });
});

describe("legacy dt_ migration", () => {
  function seedLegacyDevice(token: string) {
    storage.updateConfig({ authDeviceTokens: [token] });
  }

  it("atomically upgrades a legacy dt_ to a device key, idempotently", () => {
    const legacyToken = "dt_legacy_secret_token";
    seedLegacyDevice(legacyToken);
    const key = makeDeviceKey();

    const first = storage.migrateLegacyDevice(legacyToken, {
      publicKey: key.publicKeyJwk,
      name: "Migrated iPhone",
    });
    expect(first).not.toBeNull();
    if (!first) return;
    expect(first.deviceId).toMatch(/^dev_/);
    expect(first.accessToken).toMatch(/^at_/);

    const devices = storage.listDevices();
    const migrated = devices.find((d) => d.id === first.deviceId);
    expect(migrated?.publicKey).toEqual(key.publicKeyJwk);
    expect(migrated?.legacyTokenHash).toBeTruthy();
    // Legacy token still usable until the access token is proven.
    expect(storage.getAuthDeviceTokens()).toContain(legacyToken);

    // Idempotent: same dt_ returns the same device id.
    const second = storage.migrateLegacyDevice(legacyToken, {
      publicKey: key.publicKeyJwk,
      name: "Migrated iPhone",
    });
    expect(second?.deviceId).toBe(first.deviceId);
    expect(storage.listDevices().filter((d) => d.publicKey)).toHaveLength(1);
  });

  it("commits legacy revocation only after the replacement access token is used", () => {
    const legacyToken = "dt_legacy_secret_token";
    seedLegacyDevice(legacyToken);
    const key = makeDeviceKey();
    const migrated = storage.migrateLegacyDevice(legacyToken, {
      publicKey: key.publicKeyJwk,
      name: "Migrated iPhone",
    });
    if (!migrated) throw new Error("migration failed");

    expect(storage.getAuthDeviceTokens()).toContain(legacyToken);

    // First authenticated use commits the revocation.
    expect(storage.validateAccessToken(migrated.accessToken).ok).toBe(true);
    storage.commitLegacyRevocation(migrated.deviceId);
    expect(storage.getAuthDeviceTokens()).not.toContain(legacyToken);

    // Legacy token no longer usable after commit.
    const postCommit = storage.migrateLegacyDevice(legacyToken, {
      publicKey: makeDeviceKey().publicKeyJwk,
      name: "Attacker",
    });
    expect(postCommit).toBeNull();
  });

  it("rejects migration once finalized", () => {
    const legacyToken = "dt_legacy_secret_token";
    seedLegacyDevice(legacyToken);
    storage.setMigrationFinalized(true);

    const result = storage.migrateLegacyDevice(legacyToken, {
      publicKey: makeDeviceKey().publicKeyJwk,
      name: "Late device",
    });
    expect(result).toBeNull();
    expect(storage.isMigrationFinalized()).toBe(true);
  });

  it("rejects migration with an unknown legacy token", () => {
    const result = storage.migrateLegacyDevice("dt_not_a_real_token", {
      publicKey: makeDeviceKey().publicKeyJwk,
      name: "Unknown",
    });
    expect(result).toBeNull();
  });
});

describe("owner credential persistence", () => {
  it("does not publish rotated in-memory state when persistence fails", () => {
    const enrolled = enroll();
    const oldOwner = storage.ensurePaired();
    const configPath = storage.getConfigPath();

    rmSync(configPath);
    mkdirSync(configPath);

    expect(() => storage.rotateToken()).toThrow();
    expect(storage.getToken()).toBe(oldOwner);
    expect(storage.validateAccessToken(enrolled.accessToken).ok).toBe(true);
  });
});

describe("redaction", () => {
  it("redacts access tokens and legacy device tokens from log strings", () => {
    const secret = "at_abcdefghijklmnopqrstuvwxyz";
    const redacted = redactLogString(`Bearer ${secret} failed`, 4096);
    expect(redacted).not.toContain(secret);
    expect(redacted).toContain("[REDACTED]");

    const dt = "dt_abcdefghijklmnopqrstuvwxyz";
    expect(redactLogString(`token=${dt}`, 4096)).not.toContain(dt);

    const sk = "sk_abcdefghijklmnopqrstuvwxyz";
    expect(redactLogString(`Authorization: Bearer ${sk}`, 4096)).not.toContain(sk);
  });
});
