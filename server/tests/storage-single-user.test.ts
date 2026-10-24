import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { generateKeyPairSync } from "node:crypto";
import { Storage } from "../src/storage.js";

describe("Storage pairing", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-storage-pairing-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("starts unpaired", () => {
    const storage = new Storage(dir);
    expect(storage.isPaired()).toBe(false);
    expect(storage.getToken()).toBeUndefined();
    // getOwnerName always returns hostname, regardless of pairing state
    expect(storage.getOwnerName()).toBeTruthy();
  });

  it("ensurePaired generates an owner token without pairing a device", () => {
    const storage = new Storage(dir);
    const token = storage.ensurePaired();
    expect(token).toMatch(/^sk_/);
    expect(storage.isPaired()).toBe(false);
    expect(storage.hasOwnerToken()).toBe(true);
    expect(storage.getToken()).toBe(token);
  });

  it("is paired only while a non-revoked device is enrolled", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();
    const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const enrollment = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: publicKey.export({ format: "jwk" }),
      name: "Phone",
    });
    if (!enrollment) throw new Error("pairing failed");
    expect(storage.isPaired()).toBe(true);

    expect(storage.revokeDevice(storage.listDevices()[0]!.id)).toBe(true);
    expect(storage.isPaired()).toBe(false);
    expect(storage.hasOwnerToken()).toBe(true);
  });

  it("ensurePaired is idempotent", () => {
    const storage = new Storage(dir);
    const token1 = storage.ensurePaired();
    const token2 = storage.ensurePaired();
    expect(token1).toBe(token2);
  });

  it("ensurePaired is idempotent (returns same token)", () => {
    const storage = new Storage(dir);
    const t1 = storage.ensurePaired();
    const t2 = storage.ensurePaired();
    expect(t1).toBe(t2);
  });

  it("rotates token and persists", () => {
    const storage = new Storage(dir);
    const original = storage.ensurePaired();
    const rotated = storage.rotateToken();
    expect(rotated).not.toBe(original);
    expect(rotated).toMatch(/^sk_/);

    // Persisted
    const reloaded = new Storage(dir);
    expect(reloaded.getToken()).toBe(rotated);
  });

  it("owner rotation invalidates paired, pairing, and push credentials", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();
    storage.updateConfig({
      pairingToken: "pt_rotation-fixture-secret",
      pairingTokenExpiresAt: Date.now() + 60_000,
      pushRegistrations: [
        {
          deviceId: "dev_rotation_fixture",
          keyId: "rotation-key-id",
          publicKey: "rotation-public-key",
          sendToken: "push-rotation-fixture-secret",
          registeredAt: 1,
          events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
        },
      ],
    });

    storage.rotateToken();

    const config = storage.getConfig();
    expect(config.pairingToken).toBeUndefined();
    expect(config.pairingTokenExpiresAt).toBeUndefined();
    expect(config.authAccessTokens).toEqual([]);
    expect(config.pushRegistrations).toEqual([]);
  });

  it("token persisted in config.json not users.json", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();
    expect(existsSync(join(dir, "users.json"))).toBe(false);

    const config = JSON.parse(readFileSync(join(dir, "config.json"), "utf-8"));
    expect(config.token).toMatch(/^sk_/);
  });

  it("ignores stale users.json (migration removed)", () => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "users.json"), JSON.stringify({ token: "old" }), { mode: 0o600 });

    // users.json is ignored — no migration runs
    const storage = new Storage(dir);
    expect(storage.hasOwnerToken()).toBe(false);
    expect(existsSync(join(dir, "users.json"))).toBe(true);
  });
});
