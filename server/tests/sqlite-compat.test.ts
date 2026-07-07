import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { openDatabase } from "../src/sqlite-compat.js";

let root: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "oppi-sqlite-compat-"));
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("openDatabase", () => {
  it("returns undefined for missing rows", () => {
    const db = openDatabase(join(root, "state.db"));
    try {
      db.exec("CREATE TABLE items (id TEXT PRIMARY KEY)");

      expect(db.prepare("SELECT id FROM items WHERE id = ?").get("missing")).toBeUndefined();
    } finally {
      db.close();
    }
  });

  it("sets a busy timeout on every connection", () => {
    const db = openDatabase(join(root, "state.db"));
    try {
      const row = db.prepare("PRAGMA busy_timeout").get() as { timeout?: unknown } | undefined;

      expect(row?.timeout).toBe(5000);
    } finally {
      db.close();
    }
  });
});
