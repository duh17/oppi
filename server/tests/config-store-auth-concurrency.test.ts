import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AuthStore } from "../src/storage/auth-store.js";
import { ConfigStore } from "../src/storage/config-store.js";
import { DeviceAuthStore } from "../src/storage/device-auth.js";
import type { DevicePublicKey, ServerConfig } from "../src/types.js";

function devicePublicKey(): DevicePublicKey {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

function configFingerprint(configPath: string): string {
  const stat = statSync(configPath);
  return `${stat.ino}:${stat.mtimeNs}:${stat.size}`;
}

function stripConfigVersion(configPath: string): void {
  const raw = JSON.parse(readFileSync(configPath, "utf8")) as Record<string, unknown>;
  delete raw.configVersion;
  writeFileSync(configPath, JSON.stringify(raw, null, 2));
}

type RewriteLoadedConfig = (config: ServerConfig) => ServerConfig;

function withConstructorRewriteHook(hook: () => void): () => void {
  const proto = ConfigStore.prototype as unknown as { rewriteLoadedConfig: RewriteLoadedConfig };
  const original = proto.rewriteLoadedConfig;
  proto.rewriteLoadedConfig = function (this: ConfigStore, config: ServerConfig): ServerConfig {
    hook();
    return original.call(this, config);
  };
  return () => {
    proto.rewriteLoadedConfig = original;
  };
}

describe("config store auth concurrency", () => {
  let dataDir: string;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-config-auth-race-"));
  });

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("does not let a stale pairing writer restore pre-rotation auth", () => {
    const pairingStore = new ConfigStore(dataDir);
    const pairingAuth = new AuthStore(pairingStore);
    const pairingDevices = new DeviceAuthStore(pairingStore);
    const ownerBefore = pairingAuth.ensurePaired();
    const pairingToken = pairingAuth.issuePairingToken(60_000);
    const enrolled = pairingDevices.enrollViaPairing(pairingToken, {
      publicKey: devicePublicKey(),
      name: "Phone",
    });
    if (!enrolled) throw new Error("enrollment failed");

    const liveStore = new ConfigStore(dataDir);
    const liveAuth = new AuthStore(liveStore);
    const rotated = liveAuth.rotateToken();
    expect(rotated).not.toBe(ownerBefore);

    pairingAuth.issuePairingToken(60_000);

    const disk = new ConfigStore(dataDir).getConfig();
    expect(disk.token).toBe(rotated);
    expect(disk.token).not.toBe(ownerBefore);
    expect(disk.authDevices?.every((device) => device.revokedAt !== undefined)).toBe(true);
    expect(disk.authAccessTokens ?? []).toEqual([]);
    expect(disk.pairingToken).toMatch(/^pt_/);
  });

  it("keeps a live rotation when a stale config set writes an unrelated field", () => {
    const stale = new ConfigStore(dataDir);
    const staleAuth = new AuthStore(stale);
    staleAuth.ensurePaired();
    const originalToken = stale.getConfig().token;

    const live = new ConfigStore(dataDir);
    const rotated = new AuthStore(live).rotateToken();

    stale.updateConfig({ host: "0.0.0.0" });

    const disk = new ConfigStore(dataDir).getConfig();
    expect(disk.token).toBe(rotated);
    expect(disk.token).not.toBe(originalToken);
    expect(disk.host).toBe("0.0.0.0");
  });

  it("does not let a sparse constructor backfill restore pre-rotation auth", () => {
    const pairingStore = new ConfigStore(dataDir);
    const pairingAuth = new AuthStore(pairingStore);
    const pairingDevices = new DeviceAuthStore(pairingStore);
    const ownerBefore = pairingAuth.ensurePaired();
    const pairingToken = pairingAuth.issuePairingToken(60_000);
    const enrolled = pairingDevices.enrollViaPairing(pairingToken, {
      publicKey: devicePublicKey(),
      name: "Phone",
    });
    if (!enrolled) throw new Error("enrollment failed");

    const liveStore = new ConfigStore(dataDir);
    const liveAuth = new AuthStore(liveStore);
    stripConfigVersion(pairingStore.getConfigPath());

    let rotated = "";
    const restore = withConstructorRewriteHook(() => {
      rotated = liveAuth.rotateToken();
    });
    try {
      new ConfigStore(dataDir);
    } finally {
      restore();
    }

    expect(rotated).toMatch(/^sk_/);
    expect(rotated).not.toBe(ownerBefore);

    const reopened = new ConfigStore(dataDir);
    const disk = reopened.getConfig();
    expect(disk.token).toBe(rotated);
    expect(disk.token).not.toBe(ownerBefore);
    expect(disk.authDevices?.every((device) => device.revokedAt !== undefined)).toBe(true);
    expect(disk.authAccessTokens ?? []).toEqual([]);
    expect(new DeviceAuthStore(reopened).validateAccessToken(enrolled.accessToken).ok).toBe(false);
  });

  it("aborts a config write when authoritative disk cannot be parsed", () => {
    const store = new ConfigStore(dataDir);
    const auth = new AuthStore(store);
    const owner = auth.ensurePaired();
    const configPath = store.getConfigPath();
    writeFileSync(configPath, "{not-json");

    expect(() => store.updateConfig({ host: "10.0.0.1" })).toThrow(/authoritative/i);
    expect(readFileSync(configPath, "utf8")).toBe("{not-json");
    expect(store.getConfig().token).toBe(owner);
    expect(store.getConfig().host).not.toBe("10.0.0.1");
  });

  it("does not steal a lock directory that still names a dead pid", () => {
    const store = new ConfigStore(dataDir);
    const auth = new AuthStore(store);
    const owner = auth.ensurePaired();
    const lockPath = `${store.getConfigPath()}.lock`;
    mkdirSync(lockPath);
    writeFileSync(`${lockPath}/pid`, "999999999\n");

    expect(() => auth.rotateToken()).toThrow(/stale config lock/i);
    const disk = new ConfigStore(dataDir).getConfig();
    expect(disk.token).toBe(owner);
    expect(readFileSync(`${lockPath}/pid`, "utf8")).toBe("999999999\n");
  });

  it("recovers only an empty stale lock directory", () => {
    const store = new ConfigStore(dataDir);
    const auth = new AuthStore(store);
    auth.ensurePaired();
    const lockPath = `${store.getConfigPath()}.lock`;
    mkdirSync(lockPath);
    const aged = (Date.now() - 5_000) / 1000;
    utimesSync(lockPath, aged, aged);
    const rotated = auth.rotateToken();
    expect(new ConfigStore(dataDir).getConfig().token).toBe(rotated);
  });

  it("does not persist invalid or no-op legacy migration and revocation", () => {
    const store = new ConfigStore(dataDir);
    const devices = new DeviceAuthStore(store);
    new AuthStore(store).ensurePaired();
    const pairingToken = new AuthStore(store).issuePairingToken(60_000);
    const enrolled = devices.enrollViaPairing(pairingToken, {
      publicKey: devicePublicKey(),
      name: "Phone",
    });
    if (!enrolled) throw new Error("enrollment failed");

    const configPath = store.getConfigPath();
    const before = configFingerprint(configPath);

    expect(
      devices.migrateLegacyDevice("not-a-credential", {
        publicKey: {},
        name: "Attacker",
      }),
    ).toBeNull();
    expect(configFingerprint(configPath)).toBe(before);

    devices.migrateLegacyRecords();
    expect(configFingerprint(configPath)).toBe(before);

    expect(devices.commitLegacyRevocation(enrolled.deviceId)).toBe(false);
    expect(configFingerprint(configPath)).toBe(before);
  });

  it("still persists real migration, revocation, and rotation", () => {
    const store = new ConfigStore(dataDir);
    const auth = new AuthStore(store);
    const devices = new DeviceAuthStore(store);
    auth.ensurePaired();
    const configPath = store.getConfigPath();

    store.updateConfig({ authDeviceTokens: ["dt_legacy_secret_token"] });
    let fingerprint = configFingerprint(configPath);
    const migrated = devices.migrateLegacyDevice("dt_legacy_secret_token", {
      publicKey: devicePublicKey(),
      name: "Phone",
    });
    expect(migrated).not.toBeNull();
    if (!migrated) throw new Error("migration failed");
    expect(configFingerprint(configPath)).not.toBe(fingerprint);

    fingerprint = configFingerprint(configPath);
    expect(devices.commitLegacyRevocation(migrated.deviceId)).toBe(true);
    expect(configFingerprint(configPath)).not.toBe(fingerprint);

    fingerprint = configFingerprint(configPath);
    const rotated = auth.rotateToken();
    expect(configFingerprint(configPath)).not.toBe(fingerprint);
    expect(new ConfigStore(dataDir).getConfig().token).toBe(rotated);
  });
});
