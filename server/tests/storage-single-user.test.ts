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

  it("ignores stale users.json (migration removed)", () => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "users.json"), JSON.stringify({ token: "old" }), { mode: 0o600 });

    // users.json is ignored — no migration runs
    const storage = new Storage(dir);
    expect(storage.isPaired()).toBe(false);
    expect(existsSync(join(dir, "users.json"))).toBe(true);
  });
});
