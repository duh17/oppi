import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("Storage single-user mode", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-storage-single-user-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("allows creating exactly one owner user", () => {
    const storage = new Storage(dir);

    const user = storage.createUser("Bob");

    expect(storage.getOwnerUser()?.id).toBe(user.id);
    expect(storage.hasInvalidOwnerData()).toBe(false);
  });

  it("rejects creating a second user", () => {
    const storage = new Storage(dir);

    const owner = storage.createUser("Bob");

    expect(() => storage.createUser("Other")).toThrowError(/Single-user mode/);
    expect(storage.getOwnerUser()?.id).toBe(owner.id);
  });

  it("rotates owner token and persists it", () => {
    const storage = new Storage(dir);
    const owner = storage.createUser("Bob");

    const rotated = storage.rotateOwnerToken();

    expect(rotated.id).toBe(owner.id);
    expect(rotated.token).not.toBe(owner.token);

    const reloaded = new Storage(dir).getOwnerUser();
    expect(reloaded?.token).toBe(rotated.token);
  });

  it("rejects token rotation when owner is not paired", () => {
    const storage = new Storage(dir);
    expect(() => storage.rotateOwnerToken()).toThrowError(/Owner not paired/);
  });

  it("marks legacy users-array data as invalid", () => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "users.json"),
      JSON.stringify(
        [
          { id: "u1", name: "A", token: "sk_a", createdAt: Date.now() },
          { id: "u2", name: "B", token: "sk_b", createdAt: Date.now() },
        ],
        null,
        2,
      ),
      { mode: 0o600 },
    );

    const storage = new Storage(dir);

    expect(storage.getOwnerUser()).toBeUndefined();
    expect(storage.hasInvalidOwnerData()).toBe(true);
  });
});
