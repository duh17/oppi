import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("storage session metadata format", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-session-metadata-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("writes runtime session metadata to sqlite only", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("metadata", "anthropic/claude-sonnet-4-0");

    const sessionPath = join(dir, "sessions", `${session.id}.json`);

    expect(existsSync(join(dir, "session-state.db"))).toBe(true);
    expect(existsSync(sessionPath)).toBe(false);
    expect(new Storage(dir).getSession(session.id)?.status).toBe("ready");
  });

  it("imports legacy session metadata from disk", () => {
    const now = Date.now();

    const sessionRecord = {
      id: "s1",
      status: "ready",
      createdAt: now,
      lastActivity: now,
      model: "openai/gpt-test",
      messageCount: 1,
      tokens: { input: 1, output: 2 },
      cost: 0,
    };

    mkdirSync(join(dir, "sessions"), { recursive: true });
    const sessionPath = join(dir, "sessions", "s1.json");
    writeFileSync(sessionPath, JSON.stringify({ session: sessionRecord }, null, 2));

    const loaded = new Storage(dir).getSession("s1");
    expect(loaded?.id).toBe("s1");
    expect(loaded?.tokens.cacheRead).toBe(0);
  });
});
