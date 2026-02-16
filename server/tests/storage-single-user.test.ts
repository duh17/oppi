import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
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

  it("ensurePaired generates a token", () => {
    const storage = new Storage(dir);
    const token = storage.ensurePaired();
    expect(token).toMatch(/^sk_/);
    expect(storage.isPaired()).toBe(true);
    expect(storage.getToken()).toBe(token);
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

  it("token persisted in config.json not users.json", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();
    expect(existsSync(join(dir, "users.json"))).toBe(false);

    const config = JSON.parse(readFileSync(join(dir, "config.json"), "utf-8"));
    expect(config.token).toMatch(/^sk_/);
  });

  it("migrates legacy users.json into config.json", () => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "users.json"),
      JSON.stringify({
        id: "old-id",
        name: "Bob",
        token: "sk_legacy_token_123",
        createdAt: Date.now(),
        deviceTokens: ["apns-hex-1"],
        thinkingLevelByModel: { "anthropic/claude-sonnet-4-20250514": "high" },
      }),
      { mode: 0o600 },
    );

    const storage = new Storage(dir);

    // users.json should be gone (renamed to .migrated)
    expect(existsSync(join(dir, "users.json"))).toBe(false);
    expect(existsSync(join(dir, "users.json.migrated"))).toBe(true);

    // Token migrated
    expect(storage.getToken()).toBe("sk_legacy_token_123");
    expect(storage.isPaired()).toBe(true);

    // State migrated
    expect(storage.getDeviceTokens()).toEqual(["apns-hex-1"]);
    expect(storage.getModelThinkingLevelPreference("anthropic/claude-sonnet-4-20250514")).toBe("high");
  });

  it("ignores malformed users.json gracefully", () => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "users.json"), "[1,2,3]", { mode: 0o600 });

    // Should not crash
    const storage = new Storage(dir);
    expect(storage.isPaired()).toBe(false);
  });
});
