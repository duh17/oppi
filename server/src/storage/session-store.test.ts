import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { Storage } from "../storage.js";
import type { Session } from "../types.js";

describe("SessionStore trace context repair", () => {
  it("recovers the last non-zero context snapshot from the trace tail", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-store-"));

    try {
      const tracePath = join(dataDir, "session.jsonl");
      writeFileSync(
        tracePath,
        [
          JSON.stringify({
            type: "message",
            message: {
              role: "assistant",
              usage: { input: 120, output: 30, cacheRead: 400, cacheWrite: 0 },
            },
          }),
          JSON.stringify({
            type: "message",
            message: {
              role: "assistant",
              content: [],
              usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              stopReason: "aborted",
              errorMessage: "Request was aborted",
            },
          }),
        ].join("\n") + "\n",
      );

      const storage = new Storage(dataDir);
      const session: Session = {
        id: "sess-1",
        status: "stopped",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        model: "openai-codex/gpt-5.4",
        messageCount: 2,
        tokens: { input: 120, output: 30, cacheRead: 400, cacheWrite: 0 },
        cost: 0.12,
        contextTokens: 0,
        contextWindow: 272000,
        piSessionFile: tracePath,
      };

      storage.saveSession(session);

      const reloaded = new Storage(dataDir).listSessions()[0];
      expect(reloaded?.contextTokens).toBe(550);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
