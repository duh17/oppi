import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { Storage } from "../storage.js";
import { openDatabase } from "../sqlite-compat.js";
import { SessionSqliteStore } from "./session-sqlite-store.js";
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

describe("session sqlite store", () => {
  it("uses sqlite as the runtime session backend without writing legacy JSON", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-sqlite-runtime-"));

    try {
      const storage = new Storage(dataDir);
      storage.saveSession({
        id: "runtime-sess",
        workspaceId: "ws-1",
        workspaceName: "workspace one",
        name: "runtime",
        status: "ready",
        createdAt: 1,
        lastActivity: 2,
        messageCount: 1,
        tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
        cost: 0.5,
      });

      expect(existsSync(join(dataDir, "session-state.db"))).toBe(true);
      expect(existsSync(join(dataDir, "sessions", "runtime-sess.json"))).toBe(false);
      expect(new Storage(dataDir).getSession("runtime-sess")?.name).toBe("runtime");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("keeps legacy JSON sidecars read-only and prevents deleted sessions from re-importing", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-sqlite-delete-legacy-"));

    try {
      mkdirSync(join(dataDir, "sessions"), { recursive: true });
      writeFileSync(
        join(dataDir, "sessions", "keep-me.json"),
        JSON.stringify(
          {
            session: {
              id: "keep-me",
              workspaceId: "ws-1",
              workspaceName: "workspace one",
              name: "legacy",
              status: "ready",
              createdAt: 10,
              lastActivity: 20,
              messageCount: 1,
              tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
              cost: 0.5,
            },
          },
          null,
          2,
        ),
      );
      writeFileSync(join(dataDir, "sessions", "broken.json"), "{not-json");

      const storage = new Storage(dataDir);
      expect(storage.getSession("keep-me")?.name).toBe("legacy");

      expect(storage.deleteSession("keep-me")).toBe(true);
      expect(existsSync(join(dataDir, "sessions", "keep-me.json"))).toBe(true);

      const reloaded = new Storage(dataDir);
      expect(reloaded.getSession("keep-me")).toBeUndefined();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not mark legacy session import complete until corrupt JSON is fixed", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-sqlite-corrupt-import-"));

    try {
      mkdirSync(join(dataDir, "sessions"), { recursive: true });
      const legacyPath = join(dataDir, "sessions", "sess-recovered.json");
      writeFileSync(legacyPath, "{not-json");

      expect(new Storage(dataDir).getSession("sess-recovered")).toBeUndefined();

      writeFileSync(
        legacyPath,
        JSON.stringify({
          session: {
            id: "sess-recovered",
            workspaceId: "ws-1",
            workspaceName: "workspace one",
            name: "recovered",
            status: "ready",
            createdAt: 10,
            lastActivity: 20,
            messageCount: 1,
            tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
            cost: 0.5,
          },
        }),
      );

      expect(new Storage(dataDir).getSession("sess-recovered")?.name).toBe("recovered");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("lists workspace snapshots from projected columns without parsing session_json", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-sqlite-snapshot-"));
    let sqliteStore: SessionSqliteStore | undefined;

    try {
      sqliteStore = new SessionSqliteStore(dataDir);
      sqliteStore.upsertSession({
        id: "sess-projected",
        workspaceId: "ws-1",
        workspaceName: "Workspace",
        name: "Projected",
        status: "ready",
        createdAt: 1,
        lastActivity: 10,
        lastAgentReplyAt: 11,
        messageCount: 2,
        tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
        cost: 0.25,
        contextTokens: 123,
        contextWindow: 200,
        changeStats: {
          mutatingToolCalls: 1,
          filesChanged: 1,
          changedFiles: ["src/a.ts"],
          addedLines: 2,
          removedLines: 3,
        },
      });
      sqliteStore.close();
      sqliteStore = undefined;

      const db = openDatabase(join(dataDir, "session-state.db"));
      try {
        db.prepare("UPDATE session_state_sessions SET session_json = ? WHERE id = ?").run(
          "{not-json",
          "sess-projected",
        );
      } finally {
        db.close();
      }

      sqliteStore = new SessionSqliteStore(dataDir);
      const result = sqliteStore.listWorkspaceSessionSnapshots("ws-1");

      expect(result.totalCount).toBe(1);
      expect(result.remainingCount).toBe(0);
      expect(result.sessions[0]?.id).toBe("sess-projected");
      expect(result.sessions[0]?.lastAgentReplyAt).toBe(11);
      expect(result.sessions[0]?.contextTokens).toBe(123);
      expect(result.sessions[0]?.changeStats?.changedFiles).toEqual(["src/a.ts"]);
    } finally {
      sqliteStore?.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe("workspace session snapshots", () => {
  function baseSession(id: string, workspaceId: string, lastActivity: number): Session {
    return {
      id,
      workspaceId,
      status: "stopped",
      createdAt: lastActivity,
      lastActivity,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
  }

  it("filters recent stopped sessions while keeping old active sessions", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-snapshot-"));

    try {
      const now = 1_700_000_000_000;
      const old = now - 10 * 86_400_000;
      const recent = now - 60_000;
      const storage = new Storage(dataDir);
      storage.saveSession({ ...baseSession("old-busy", "ws-1", old), status: "busy" });
      storage.saveSession(baseSession("recent-stopped", "ws-1", recent));
      storage.saveSession(baseSession("old-stopped", "ws-1", old));
      storage.saveSession(baseSession("other-workspace", "ws-2", recent));

      const result = storage.listWorkspaceSessionSnapshots("ws-1", { recentDays: 3, nowMs: now });

      expect(result.totalCount).toBe(3);
      expect(result.filteredCount).toBe(2);
      expect(result.sessions.map((session) => session.id)).toEqual(["recent-stopped", "old-busy"]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("uses deterministic stopped pagination cursors", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-snapshot-page-"));

    try {
      const storage = new Storage(dataDir);
      storage.saveSession(baseSession("a", "ws-1", 300));
      storage.saveSession(baseSession("b", "ws-1", 200));
      storage.saveSession(baseSession("c", "ws-1", 200));
      storage.saveSession(baseSession("d", "ws-1", 100));

      const result = storage.listWorkspaceSessionSnapshots("ws-1", {
        status: "stopped",
        beforeLastActivity: 200,
        beforeSessionId: "b",
        limit: 1,
      });

      expect(result.totalCount).toBe(4);
      expect(result.filteredCount).toBe(2);
      expect(result.remainingCount).toBe(1);
      expect(result.sessions.map((session) => session.id)).toEqual(["c"]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("includes ancestors for returned child rows", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-snapshot-ancestors-"));

    try {
      const now = 1_700_000_000_000;
      const old = now - 10 * 86_400_000;
      const storage = new Storage(dataDir);
      storage.saveSession(baseSession("parent", "ws-1", old));
      storage.saveSession({
        ...baseSession("child", "ws-1", now),
        status: "busy",
        parentSessionId: "parent",
      });

      const result = storage.listWorkspaceSessionSnapshots("ws-1", { recentDays: 3, nowMs: now });

      expect(result.sessions.map((session) => session.id)).toEqual(["child", "parent"]);
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

      expect(reloaded?.workspaceId).toBeUndefined();
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
