import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  it("writes metadata-only session files", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("metadata", "anthropic/claude-sonnet-4-0");

    const sessionPath = join(dir, "sessions", `${session.id}.json`);
    const payload = JSON.parse(readFileSync(sessionPath, "utf-8")) as {
      session?: { id: string };
      messages?: unknown;
    };

    expect(payload.session?.id).toBe(session.id);
    expect("messages" in payload).toBe(false);
  });

  it("reads session metadata from disk", () => {
    const storage = new Storage(dir);
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

    const sessionPath = join(dir, "sessions", "s1.json");
    writeFileSync(sessionPath, JSON.stringify({ session: sessionRecord }, null, 2));

    const loaded = storage.getSession("s1");
    expect(loaded?.id).toBe("s1");
  });
});
