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

  it("migrates legacy {session,messages} record on getSession", () => {
    const storage = new Storage(dir);
    const now = Date.now();

    const legacySession = {
      id: "legacy-s1",
      status: "ready",
      createdAt: now,
      lastActivity: now,
      model: "openai/gpt-test",
      messageCount: 1,
      tokens: { input: 1, output: 2 },
      cost: 0,
    };

    const sessionPath = join(dir, "sessions", "legacy-s1.json");
    writeFileSync(
      sessionPath,
      JSON.stringify(
        {
          session: legacySession,
          messages: [
            {
              id: "m1",
              sessionId: "legacy-s1",
              role: "assistant",
              content: "legacy",
              timestamp: now,
            },
          ],
        },
        null,
        2,
      ),
    );

    const loaded = storage.getSession("legacy-s1");
    expect(loaded?.id).toBe("legacy-s1");

    const migrated = JSON.parse(readFileSync(sessionPath, "utf-8")) as {
      session?: { id: string };
      messages?: unknown;
    };

    expect(migrated.session?.id).toBe("legacy-s1");
    expect("messages" in migrated).toBe(false);
  });

  it("keeps addSessionMessage as non-persisting compatibility shim", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("shim", "anthropic/claude-sonnet-4-0");

    const added = storage.addSessionMessage(session.id, {
      role: "assistant",
      content: "hello",
      timestamp: Date.now(),
    });

    expect(added.id).toBeTruthy();
    expect(added.sessionId).toBe(session.id);

    const sessionPath = join(dir, "sessions", `${session.id}.json`);
    const payload = JSON.parse(readFileSync(sessionPath, "utf-8")) as {
      messages?: unknown;
    };

    expect("messages" in payload).toBe(false);
  });
});
