import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type { Session } from "../src/types.js";

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

  it("deletes legacy JSON sidecars and prevents deleted sessions from re-importing", () => {
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
      expect(existsSync(join(dataDir, "sessions", "keep-me.json"))).toBe(false);

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
      const sessions = sqliteStore.listWorkspaceTimeRangeSessionSnapshots(
        "ws-1",
        0,
        Number.MAX_SAFE_INTEGER,
      );

      expect(sessions[0]?.id).toBe("sess-projected");
      expect(sessions[0]?.lastAgentReplyAt).toBe(11);
      expect(sessions[0]?.contextTokens).toBe(123);
      expect(sessions[0]?.changeStats?.changedFiles).toEqual(["src/a.ts"]);
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

      const sessions = storage.listRecentWorkspaceSessionSnapshots("ws-1", 3, now);

      expect(sessions.map((session) => session.id)).toEqual(["recent-stopped", "old-busy"]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("filters stopped sessions by explicit time range while keeping active sessions", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-snapshot-range-"));

    try {
      const now = new Date(2026, 4, 13, 12, 0, 0).getTime();
      const rangeSince = now - 3 * 86_400_000;
      const rangeUntil = now + 1_000;
      const storage = new Storage(dataDir);
      storage.saveSession({
        ...baseSession("old-busy", "ws-1", now - 20 * 86_400_000),
        status: "busy",
      });
      storage.saveSession(baseSession("recent-stopped", "ws-1", now - 60_000));
      storage.saveSession(baseSession("old-stopped", "ws-1", now - 10 * 86_400_000));

      const sessions = storage.listWorkspaceTimeRangeSessionSnapshots(
        "ws-1",
        rangeSince,
        rangeUntil,
      );

      expect(sessions.map((session) => session.id)).toEqual(["recent-stopped", "old-busy"]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe("workspace session summary snapshots", () => {
  function summarySession(
    id: string,
    workspaceId: string,
    status: Session["status"],
    lastActivity: number,
  ): Session {
    return {
      id,
      workspaceId,
      status,
      createdAt: lastActivity,
      lastActivity,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
  }

  it("counts workspace sessions and preserves latest activity", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-workspace-summary-"));

    try {
      const storage = new Storage(dataDir);
      storage.saveSession(summarySession("stopped", "ws-1", "stopped", 100));
      storage.saveSession(summarySession("error", "ws-1", "error", 500));
      storage.saveSession(summarySession("ready", "ws-1", "ready", 300));

      const summaries = storage.listWorkspaceSessionSummarySnapshots();
      expect(summaries).toEqual([
        {
          workspaceId: "ws-1",
          activeCount: 2,
          stoppedCount: 1,
          hasErrorRoot: true,
          latestActivity: 500,
        },
      ]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("flags root error sessions in summaries", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-workspace-summary-error-"));

    try {
      const storage = new Storage(dataDir);
      storage.saveSession(summarySession("root-error", "ws-1", "error", 200));
      storage.saveSession(summarySession("other-root-stopped", "ws-1", "stopped", 100));

      const summaries = storage.listWorkspaceSessionSummarySnapshots();
      expect(summaries).toEqual([
        {
          workspaceId: "ws-1",
          activeCount: 1,
          stoppedCount: 1,
          hasErrorRoot: true,
          latestActivity: 200,
        },
      ]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe("workspace stopped time buckets", () => {
  function bucketSession(id: string, workspaceId: string, lastActivity: number): Session {
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

  it("groups older stopped sessions into day and month buckets", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-buckets-"));

    try {
      const now = new Date(2026, 4, 13, 12, 0, 0).getTime();
      const storage = new Storage(dataDir);
      storage.saveSession(bucketSession("recent-day", "ws-1", now - 10 * 86_400_000));
      storage.saveSession(bucketSession("old-month-a", "ws-1", now - 60 * 86_400_000));
      storage.saveSession(bucketSession("old-month-b", "ws-1", now - 65 * 86_400_000));

      const buckets = storage.listWorkspaceStoppedTimeBuckets("ws-1", now - 3 * 86_400_000, now);

      expect(buckets.map((bucket) => [bucket.bucketKind, bucket.itemCount])).toEqual([
        ["day", 1],
        ["month", 2],
      ]);
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
