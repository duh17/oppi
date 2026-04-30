import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { Storage } from "../storage.js";
import type { Session } from "../types.js";

describe("SessionStore trace context repair", () => {
  it("backfills codex spark cost from stored aggregate tokens", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-store-"));

    try {
      const storage = new Storage(dataDir);
      const session: Session = {
        id: "sess-cost",
        status: "ready",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        model: "openai-codex/gpt-5.3-codex-spark",
        messageCount: 1,
        tokens: { input: 1000, output: 100, cacheRead: 10000, cacheWrite: 0 },
        cost: 0,
      };

      storage.saveSession(session);

      const reloaded = new Storage(dataDir).getSession("sess-cost");
      expect(reloaded?.cost).toBeCloseTo(0.0049);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

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

describe("legacy workspace session migration", () => {
  it("assigns old sessions to an existing workspace by JSONL cwd", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-migration-"));
    const projectDir = join(dataDir, "project");
    const nestedDir = join(projectDir, "server");

    try {
      mkdirSync(nestedDir, { recursive: true });
      const tracePath = join(dataDir, "legacy.jsonl");
      writeFileSync(
        tracePath,
        JSON.stringify({ type: "session", id: "pi-1", cwd: nestedDir, timestamp: "now" }) + "\n",
      );

      const storage = new Storage(dataDir);
      const workspace = storage.createWorkspace({
        name: "project",
        skills: [],
        hostMount: projectDir,
      });
      storage.saveSession({
        id: "legacy-1",
        status: "ready",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        piSessionFile: tracePath,
      });

      const reloaded = new Storage(dataDir).getSession("legacy-1");
      expect(reloaded?.workspaceId).toBe(workspace.id);
      expect(reloaded?.workspaceName).toBe("project");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("leaves legacy sessions orphaned when no existing hostMount matches", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-migration-"));
    const projectDir = join(dataDir, "orphan-project");

    try {
      mkdirSync(projectDir, { recursive: true });
      mkdirSync(join(dataDir, "sessions"), { recursive: true });
      const tracePath = join(dataDir, "legacy.jsonl");
      writeFileSync(
        tracePath,
        JSON.stringify({ type: "session", id: "pi-1", cwd: projectDir, timestamp: "now" }) + "\n",
      );
      writeFileSync(
        join(dataDir, "sessions", "legacy-1.json"),
        JSON.stringify(
          {
            session: {
              id: "legacy-1",
              workspaceId: null,
              status: "ready",
              createdAt: Date.now(),
              lastActivity: Date.now(),
              messageCount: 0,
              tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              cost: 0,
              piSessionFile: tracePath,
            },
          },
          null,
          2,
        ),
      );

      const reloadedStorage = new Storage(dataDir);
      const reloaded = reloadedStorage.getSession("legacy-1");

      expect(reloaded?.workspaceId).toBeNull();
      expect(reloadedStorage.listWorkspaces()).toEqual([]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("leaves legacy sessions orphaned when matching hostMounts are ambiguous", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-migration-"));
    const projectDir = join(dataDir, "project");

    try {
      mkdirSync(projectDir, { recursive: true });
      const tracePath = join(dataDir, "legacy.jsonl");
      writeFileSync(
        tracePath,
        JSON.stringify({ type: "session", id: "pi-1", cwd: projectDir, timestamp: "now" }) + "\n",
      );

      const storage = new Storage(dataDir);
      storage.createWorkspace({ name: "project-a", skills: [], hostMount: projectDir });
      storage.createWorkspace({ name: "project-b", skills: [], hostMount: projectDir });
      storage.saveSession({
        id: "legacy-1",
        status: "ready",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        piSessionFile: tracePath,
      });

      const reloaded = new Storage(dataDir).getSession("legacy-1");
      expect(reloaded?.workspaceId).toBeUndefined();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
