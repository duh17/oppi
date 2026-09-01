import { randomUUID } from "node:crypto";
import {
  chmodSync,
  rmSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeFileSync,
  mkdtempSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { SearchIndex } from "../src/search-index.js";
import { openDatabase } from "../src/sqlite-compat.js";
import type { Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    name: "Search test session",
    status: "stopped",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function writeJsonl(path: string, userText: string, assistantText: string): void {
  const lines = [
    JSON.stringify({
      type: "session",
      id: randomUUID(),
      cwd: "/tmp/search-test",
      timestamp: new Date().toISOString(),
    }),
    JSON.stringify({
      type: "message",
      id: "u1",
      parentId: null,
      timestamp: new Date().toISOString(),
      message: { role: "user", content: [{ type: "text", text: userText }] },
    }),
    JSON.stringify({
      type: "message",
      id: "a1",
      parentId: "u1",
      timestamp: new Date().toISOString(),
      message: { role: "assistant", content: [{ type: "text", text: assistantText }] },
    }),
  ];
  writeFileSync(path, lines.join("\n") + "\n");
}

function writeRawJsonl(path: string, lines: string[], trailingNewline = true): void {
  writeFileSync(path, lines.join("\n") + (trailingNewline ? "\n" : ""));
}

function writeSummary(baseDir: string, piSessionId: string, body: Record<string, unknown>): string {
  const path = join(baseDir, `${piSessionId}.summary.json`);
  writeFileSync(path, JSON.stringify(body, null, 2) + "\n");
  return path;
}

function makeFileSession(
  dataDir: string,
  id: string,
  userText: string,
  assistantText: string,
  overrides: Partial<Session> = {},
): Session {
  const jsonlPath = join(dataDir, `${id}.jsonl`);
  writeJsonl(jsonlPath, userText, assistantText);
  return makeSession({ id, piSessionFile: jsonlPath, ...overrides });
}

function cloneSession(session: Session): Session {
  return { ...session, tokens: { ...session.tokens } };
}

const cleanupPaths = new Set<string>();

afterEach(() => {
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
});

describe("SearchIndex file modes", () => {
  it("creates session-search.db as owner-only", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-mode-"));
    cleanupPaths.add(dataDir);
    const index = new SearchIndex(dataDir, () => undefined);
    cleanupPaths.add(join(dataDir, "session-search.db"));
    try {
      expect(statSync(join(dataDir, "session-search.db")).mode & 0o777).toBe(0o600);
    } finally {
      index.close();
    }
  });

  it("leaves permissions on an existing session-search.db", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-mode-existing-"));
    cleanupPaths.add(dataDir);
    const dbPath = join(dataDir, "session-search.db");
    const seed = openDatabase(dbPath);
    seed.close();
    chmodSync(dbPath, 0o660);
    const index = new SearchIndex(dataDir, () => undefined);
    cleanupPaths.add(dbPath);
    try {
      expect(statSync(dbPath).mode & 0o777).toBe(0o660);
    } finally {
      index.close();
    }
  });
});

describe("SearchIndex indexes transcript content only", () => {
  it("ignores sidecar summary-only text and indexes transcript content", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const piSessionId = randomUUID();
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(
      jsonlPath,
      "Investigate search ranking",
      "The transcript mentions zebra transcript clue but not the external blocker phrase.",
    );

    const summaryPath = writeSummary(dataDir, piSessionId, {
      title: "Search summary indexing",
      thread: "Memory discovery",
      goal: "Make sidecar summaries searchable",
      status: "blocked",
      blockers: ["walrus token blocker in sidecar summary"],
    });
    cleanupPaths.add(summaryPath);

    const session = makeSession({ id: "sess-summary", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      index.sync([session]);

      const transcriptResults = index.search("zebra transcript clue", "ws-1", 10);
      expect(transcriptResults).toHaveLength(1);
      expect(transcriptResults[0]?.sessionId).toBe(session.id);

      const summaryOnlyResults = index.search("walrus token blocker", "ws-1", 10);
      expect(summaryOnlyResults).toHaveLength(0);
    } finally {
      index.close();
    }
  });

  it("does not reindex when only an ignored sidecar summary changes", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const piSessionId = randomUUID();
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(
      jsonlPath,
      "Keep transcript stable",
      "This transcript never mentions the changing blocker keywords.",
    );

    const summaryPath = writeSummary(dataDir, piSessionId, {
      title: "Initial blocker",
      goal: "Prove sidecar summary is ignored by core index",
      status: "blocked",
      blockers: ["otter blocker"],
    });
    cleanupPaths.add(summaryPath);

    const session = makeSession({ id: "sess-reindex", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const first = index.sync([session]);
      expect(first.added).toBe(1);
      expect(index.search("otter blocker", "ws-1", 10)).toHaveLength(0);

      writeSummary(dataDir, piSessionId, {
        title: "Updated blocker",
        goal: "Prove sidecar summary is ignored by core index",
        status: "blocked",
        blockers: ["penguin blocker"],
      });
      const future = new Date(Date.now() + 5_000);
      utimesSync(summaryPath, future, future);

      const second = index.sync([session]);
      expect(second.reindexed).toBe(0);
      expect(second.skipped).toBe(1);
      expect(index.search("penguin blocker", "ws-1", 10)).toHaveLength(0);
    } finally {
      index.close();
    }
  });

  it("reindexes when session metadata changes even if transcript file is unchanged", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "keep transcript stable", "assistant transcript content");

    const session = makeSession({
      id: "sess-metadata",
      name: "oldtitletoken",
      piSessionFile: jsonlPath,
    });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const first = index.sync([session]);
      expect(first.added).toBe(1);
      expect(first.transcriptsRead).toBe(1);
      expect(first.transcriptBytesRead).toBeGreaterThan(0);
      expect(index.search("oldtitletoken", "ws-1", 10)).toHaveLength(1);

      session.name = "newtitletoken";

      const second = index.sync([session]);
      expect(second.reindexed).toBe(1);
      expect(second.skipped).toBe(0);
      expect(second.transcriptsRead).toBe(0);
      expect(second.transcriptBytesRead).toBe(0);
      expect(second.reusedIndexedTranscript).toBe(1);
      expect(index.search("newtitletoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("oldtitletoken", "ws-1", 10)).toHaveLength(0);
    } finally {
      index.close();
    }
  });

  it("indexes only visible post-compaction trace content", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const jsonlPath = join(dataDir, "compacted-session.jsonl");
    writeRawJsonl(jsonlPath, [
      JSON.stringify({
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "user", content: "hiddencompacttoken old user text" },
      }),
      JSON.stringify({
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "hiddenassistantcompacttoken" }],
        },
      }),
      JSON.stringify({
        type: "message",
        id: "u2",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:03Z",
        message: { role: "user", content: "keptcompacttoken visible user text" },
      }),
      JSON.stringify({
        type: "message",
        id: "a2",
        parentId: "u2",
        timestamp: "2026-01-01T00:00:04Z",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "keptassistantcompacttoken" }],
        },
      }),
      JSON.stringify({
        type: "compaction",
        id: "c1",
        parentId: "a2",
        timestamp: "2026-01-01T00:00:05Z",
        summary: "summarycompacttoken should not become indexed assistant text",
        firstKeptEntryId: "u2",
        tokensBefore: 12345,
      }),
      JSON.stringify({
        type: "message",
        id: "u3",
        parentId: "c1",
        timestamp: "2026-01-01T00:00:06Z",
        message: { role: "user", content: "postcompacttoken visible follow-up" },
      }),
      JSON.stringify({
        type: "message",
        id: "a3",
        parentId: "u3",
        timestamp: "2026-01-01T00:00:07Z",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "postassistantcompacttoken" }],
        },
      }),
    ]);

    const session = makeSession({ id: "sess-compacted", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(1);
      expect(result.transcriptBytesRead).toBeGreaterThan(0);

      expect(index.search("hiddencompacttoken", "ws-1", 10)).toHaveLength(0);
      expect(index.search("hiddenassistantcompacttoken", "ws-1", 10)).toHaveLength(0);
      expect(index.search("summarycompacttoken", "ws-1", 10)).toHaveLength(0);
      expect(index.search("keptcompacttoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("keptassistantcompacttoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("postcompacttoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("postassistantcompacttoken", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("indexes only the active latest branch in trace content", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const jsonlPath = join(dataDir, "branched-session.jsonl");
    writeRawJsonl(jsonlPath, [
      JSON.stringify({
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "user", content: "sharedbranchroot" },
      }),
      JSON.stringify({
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: { role: "assistant", content: [{ type: "text", text: "sharedbranchanswer" }] },
      }),
      JSON.stringify({
        type: "message",
        id: "u2-inactive",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:03Z",
        message: { role: "user", content: "inactivebranchtoken stale branch text" },
      }),
      JSON.stringify({
        type: "message",
        id: "u2-active",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:04Z",
        message: { role: "user", content: "activebranchtoken latest branch text" },
      }),
      JSON.stringify({
        type: "message",
        id: "a2-active",
        parentId: "u2-active",
        timestamp: "2026-01-01T00:00:05Z",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "activeassistantbranchtoken" }],
        },
      }),
    ]);

    const session = makeSession({ id: "sess-branched", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(1);
      expect(result.transcriptBytesRead).toBeGreaterThan(0);

      expect(index.search("inactivebranchtoken", "ws-1", 10)).toHaveLength(0);
      expect(index.search("activebranchtoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("activeassistantbranchtoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("sharedbranchroot", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("reindexes changed transcript content and updates search results", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "old-query-token", "assistant old answer token");

    const session = makeSession({ id: "sess-content", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const first = index.sync([session]);
      expect(first.added).toBe(1);
      expect(first.transcriptsRead).toBe(1);
      expect(index.search("old-query-token", "ws-1", 10)).toHaveLength(1);

      writeJsonl(jsonlPath, "new-query-token", "assistant new answer token");
      const future = new Date(Date.now() + 5_000);
      utimesSync(jsonlPath, future, future);

      const second = index.sync([session]);
      expect(second.reindexed).toBe(1);
      expect(second.transcriptsRead).toBe(1);
      expect(second.transcriptBytesRead).toBeGreaterThan(0);
      expect(second.reusedIndexedTranscript).toBe(0);
      expect(index.search("new-query-token", "ws-1", 10)).toHaveLength(1);
      expect(index.search("old-query-token", "ws-1", 10)).toHaveLength(0);
    } finally {
      index.close();
    }
  });

  it("parses large JSONL files incrementally and keeps the final line without newline", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const jsonlPath = join(dataDir, "session.jsonl");
    const hugeIgnoredLine = JSON.stringify({
      type: "session",
      id: randomUUID(),
      cwd: "/tmp/search-test",
      note: "x".repeat(200_000),
    });
    writeRawJsonl(
      jsonlPath,
      [
        hugeIgnoredLine,
        "not valid json",
        JSON.stringify({
          type: "message",
          id: "a1",
          timestamp: new Date().toISOString(),
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "tc-1", name: "late_tool_token", arguments: {} }],
          },
        }),
      ],
      false,
    );

    const session = makeSession({ id: "sess-streamed", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(1);
      expect(result.transcriptBytesRead).toBeGreaterThan(200_000);
      expect(index.search("late_tool_token", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("filters by trace mtime and lists date ranges newest first without a query", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const oldPath = join(dataDir, "old.jsonl");
    const newPath = join(dataDir, "new.jsonl");
    writeJsonl(oldPath, "date filter token", "old answer");
    writeJsonl(newPath, "date filter token", "new answer");

    const oldTime = new Date("2026-01-01T12:00:00Z");
    const newTime = new Date("2026-01-03T12:00:00Z");
    utimesSync(oldPath, oldTime, oldTime);
    utimesSync(newPath, newTime, newTime);

    const oldSession = makeSession({ id: "sess-old-date", piSessionFile: oldPath });
    const newSession = makeSession({ id: "sess-new-date", piSessionFile: newPath });
    const sessions = new Map([
      [oldSession.id, oldSession],
      [newSession.id, newSession],
    ]);

    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      index.sync([oldSession, newSession]);

      const queried = index.search("date filter token", "ws-1", 10, {
        sinceMs: Date.parse("2026-01-02T00:00:00Z"),
      });
      expect(queried.map((result) => result.sessionId)).toEqual(["sess-new-date"]);

      const recent = index.search("", "ws-1", 10, {
        sinceMs: Date.parse("2026-01-01T00:00:00Z"),
        untilMs: Date.parse("2026-01-04T00:00:00Z"),
      });
      expect(recent.map((result) => result.sessionId)).toEqual(["sess-new-date", "sess-old-date"]);
    } finally {
      index.close();
    }
  });

  it("propagates no-query date listing database errors", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const index = new SearchIndex(dataDir, () => undefined);
    cleanupPaths.add(join(dataDir, "session-search.db"));
    index.close();

    expect(() => index.search("", undefined, 10, { sinceMs: 0 })).toThrow();
  });

  it("boosts newer sessions for equal-relevance query matches", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const oldPath = join(dataDir, "old.jsonl");
    const newPath = join(dataDir, "new.jsonl");
    writeJsonl(oldPath, "recency boost token", "same relevance baseline");
    writeJsonl(newPath, "recency boost token", "same relevance baseline");

    const oldTime = new Date(Date.now() - 14 * 86_400_000);
    const newTime = new Date(Date.now() - 60_000);
    utimesSync(oldPath, oldTime, oldTime);
    utimesSync(newPath, newTime, newTime);

    const oldSession = makeSession({ id: "sess-old", piSessionFile: oldPath });
    const newSession = makeSession({ id: "sess-new", piSessionFile: newPath });
    const sessions = new Map([
      [oldSession.id, oldSession],
      [newSession.id, newSession],
    ]);

    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      index.sync([oldSession, newSession]);
      const results = index.search("recency boost token", "ws-1", 10);
      expect(results.map((r) => r.sessionId)).toEqual(["sess-new", "sess-old"]);
    } finally {
      index.close();
    }
  });

  it("reopens an intact index and skips unchanged transcript work", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-reopen-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "durable reopen token", "durable assistant token");
    const session = makeSession({ id: "sess-reopen", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);

    const firstIndex = new SearchIndex(dataDir, (id) => sessions.get(id));
    expect(firstIndex.sync([session])).toMatchObject({ added: 1, transcriptsRead: 1 });
    firstIndex.close();

    const reopened = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      expect(reopened.search("durable reopen token", "ws-1", 10)).toHaveLength(1);
      expect(reopened.sync([session])).toMatchObject({
        added: 0,
        reindexed: 0,
        skipped: 1,
        transcriptsRead: 0,
        transcriptBytesRead: 0,
      });
    } finally {
      reopened.close();
    }
  });

  it("rebuilds an interrupted schema upgrade and repopulates idempotently", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-schema-rebuild-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "schema rebuild token", "recovered index content");
    const session = makeSession({ id: "sess-schema-rebuild", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);

    const firstIndex = new SearchIndex(dataDir, (id) => sessions.get(id));
    firstIndex.sync([session]);
    firstIndex.close();

    const db = openDatabase(join(dataDir, "session-search.db"));
    try {
      db.prepare("UPDATE fts_schema SET value = ? WHERE key = 'version'").run("2");
    } finally {
      db.close();
    }

    const rebuilt = new SearchIndex(dataDir, (id) => sessions.get(id));
    expect(rebuilt.search("schema rebuild token", "ws-1", 10)).toEqual([]);
    expect(rebuilt.sync([session])).toMatchObject({ added: 1, reindexed: 0 });
    expect(rebuilt.search("schema rebuild token", "ws-1", 10)).toHaveLength(1);
    rebuilt.close();

    const reopened = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      expect(reopened.sync([session])).toMatchObject({ added: 0, reindexed: 0, skipped: 1 });
      expect(reopened.search("schema rebuild token", "ws-1", 10)).toHaveLength(1);
    } finally {
      reopened.close();
    }
  });

  it("migrates v3 fts_meta identity columns without rebuilding FTS", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-schema-v4-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "v4 migrate token", "kept transcript content");
    const session = makeSession({
      id: "sess-v4-migrate",
      name: "Original title token",
      piSessionFile: jsonlPath,
    });
    const sessions = new Map([[session.id, session]]);

    const firstIndex = new SearchIndex(dataDir, (id) => sessions.get(id));
    firstIndex.sync([session]);
    firstIndex.close();

    const db = openDatabase(join(dataDir, "session-search.db"));
    const ftsCountBefore = (
      db.prepare("SELECT COUNT(*) AS n FROM session_fts").get() as {
        n: number;
      }
    ).n;
    try {
      db.exec(`
        CREATE TABLE fts_meta_v3 (
          session_id TEXT PRIMARY KEY,
          jsonl_path TEXT,
          jsonl_mtime_ms INTEGER,
          jsonl_size INTEGER,
          indexed_at INTEGER
        );
        INSERT INTO fts_meta_v3
          SELECT session_id, jsonl_path, jsonl_mtime_ms, jsonl_size, indexed_at
          FROM fts_meta;
        DROP TABLE fts_meta;
        ALTER TABLE fts_meta_v3 RENAME TO fts_meta;
        UPDATE fts_schema SET value = '3' WHERE key = 'version';
      `);
    } finally {
      db.close();
    }

    const migrated = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      expect(migrated.search("v4 migrate token", "ws-1", 10)).toHaveLength(1);
      expect(migrated.sync([session])).toMatchObject({
        added: 0,
        reindexed: 0,
        skipped: 1,
        transcriptsRead: 0,
      });
    } finally {
      migrated.close();
    }

    const after = openDatabase(join(dataDir, "session-search.db"));
    try {
      const version = after.prepare("SELECT value FROM fts_schema WHERE key = 'version'").get() as {
        value: string;
      };
      const columns = (
        after.prepare("PRAGMA table_info(fts_meta)").all() as Array<{ name: string }>
      ).map((row) => row.name);
      const ftsCountAfter = (
        after.prepare("SELECT COUNT(*) AS n FROM session_fts").get() as { n: number }
      ).n;
      const meta = after
        .prepare("SELECT workspace_id, title FROM fts_meta WHERE session_id = ?")
        .get(session.id) as { workspace_id: string; title: string };
      expect(version.value).toBe("4");
      expect(columns).toEqual(
        expect.arrayContaining(["workspace_id", "title", "jsonl_path", "jsonl_mtime_ms"]),
      );
      expect(ftsCountAfter).toBe(ftsCountBefore);
      expect(meta.workspace_id).toBe("ws-1");
      expect(meta.title).toContain("Original title token");
    } finally {
      after.close();
    }
  });

  it("reindexes a title change from fts_meta without rereading the transcript", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-title-reuse-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonl(jsonlPath, "stable transcript token", "unchanged assistant token");
    const session = makeSession({
      id: "sess-title-reuse",
      name: "Old title token",
      piSessionFile: jsonlPath,
    });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));

    try {
      expect(index.sync([session])).toMatchObject({ added: 1, transcriptsRead: 1 });
      sessions.set(session.id, { ...session, name: "New title token" });
      expect(index.sync([session])).toMatchObject({
        added: 0,
        reindexed: 1,
        skipped: 0,
        reusedIndexedTranscript: 1,
        transcriptsRead: 0,
      });
      expect(index.search("stable transcript token", "ws-1", 10)).toHaveLength(1);
      expect(index.search("New title token", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("repairs interrupted FTS/meta pairs and removes orphan rows", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-pair-repair-"));
    cleanupPaths.add(dataDir);
    const firstPath = join(dataDir, "first.jsonl");
    const secondPath = join(dataDir, "second.jsonl");
    writeJsonl(firstPath, "meta-only repair token", "first");
    writeJsonl(secondPath, "fts-only repair token", "second");
    const first = makeSession({ id: "sess-meta-only", piSessionFile: firstPath });
    const second = makeSession({ id: "sess-fts-only", piSessionFile: secondPath });
    const orphan = makeSession({ id: "sess-orphan", name: "orphan cleanup token" });
    const sessions = new Map([
      [first.id, first],
      [second.id, second],
      [orphan.id, orphan],
    ]);

    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    index.sync([first, second, orphan]);
    index.close();

    const db = openDatabase(join(dataDir, "session-search.db"));
    try {
      db.prepare("DELETE FROM session_fts WHERE session_id = ?").run(first.id);
      db.prepare("DELETE FROM fts_meta WHERE session_id = ?").run(second.id);
    } finally {
      db.close();
    }
    sessions.delete(orphan.id);

    const repaired = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      const result = repaired.sync([first, second]);
      expect(result).toMatchObject({ added: 1, reindexed: 1, removed: 1 });
      expect(repaired.search("meta-only repair token", "ws-1", 10)).toHaveLength(1);
      expect(repaired.search("fts-only repair token", "ws-1", 10)).toHaveLength(1);
      expect(repaired.search("orphan cleanup token", "ws-1", 10)).toEqual([]);
    } finally {
      repaired.close();
    }
  });

  it("supports explicit OR in quoted phrase queries", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-"));
    cleanupPaths.add(dataDir);

    const bugPath = join(dataDir, "bug.jsonl");
    const architecturePath = join(dataDir, "arch.jsonl");
    writeJsonl(bugPath, "bug hunt findings", "fixed flaky search behavior");
    writeJsonl(architecturePath, "architecture doc outline", "notes on leaky abstractions");

    const bugSession = makeSession({ id: "sess-bug", piSessionFile: bugPath });
    const architectureSession = makeSession({ id: "sess-arch", piSessionFile: architecturePath });
    const sessions = new Map([
      [bugSession.id, bugSession],
      [architectureSession.id, architectureSession],
    ]);

    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    cleanupPaths.add(join(dataDir, "session-search.db"));

    try {
      index.sync([bugSession, architectureSession]);
      const results = index.search('"bug hunt" OR "architecture doc"', "ws-1", 10);
      expect(results.map((result) => result.sessionId).sort()).toEqual(["sess-arch", "sess-bug"]);

      const lowercaseResults = index.search('"bug hunt" or "architecture doc"', "ws-1", 10);
      expect(lowercaseResults.map((result) => result.sessionId).sort()).toEqual([
        "sess-arch",
        "sess-bug",
      ]);
    } finally {
      index.close();
    }
  });
});

describe("SearchIndex background sync", () => {
  it("uses the live session when storage replaces a snapshot during warming", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-live-replacement-"));
    cleanupPaths.add(dataDir);

    const snapshotFirst = makeFileSession(
      dataDir,
      "live-replacement-first",
      "first warming token",
      "first answer",
    );
    const snapshotPath = join(dataDir, "live-replacement-snapshot.jsonl");
    const livePath = join(dataDir, "live-replacement-live.jsonl");
    writeJsonl(snapshotPath, "snapshot old content token", "snapshot old answer");
    writeJsonl(livePath, "live updated content token", "live updated answer");
    const snapshotTarget = makeSession({
      id: "live-replacement-target",
      workspaceId: "ws-snapshot",
      name: "snapshot title token",
      firstMessage: "snapshot first message",
      piSessionFile: snapshotPath,
    });
    const liveTargetBeforeReplacement = cloneSession(snapshotTarget);
    const liveSessions = new Map<string, Session>([
      [snapshotFirst.id, cloneSession(snapshotFirst)],
      [snapshotTarget.id, liveTargetBeforeReplacement],
    ]);
    expect(liveSessions.get(snapshotTarget.id)).not.toBe(snapshotTarget);

    const index = new SearchIndex(dataDir, (id) => liveSessions.get(id));
    let releaseYield: (() => void) | undefined;
    let notifyYield!: () => void;
    const yieldStarted = new Promise<void>((resolve) => {
      notifyYield = resolve;
    });
    const yieldGate = new Promise<void>((resolve) => {
      releaseYield = resolve;
    });

    try {
      const syncPromise = index.startBackgroundSync([snapshotFirst, snapshotTarget], {
        batchSize: 1,
        yieldToEventLoop: async () => {
          notifyYield();
          await yieldGate;
        },
      });

      await yieldStarted;
      liveSessions.set(snapshotTarget.id, {
        ...liveTargetBeforeReplacement,
        workspaceId: "ws-live",
        name: "live title token",
        firstMessage: "live first message",
        piSessionFile: livePath,
      });
      releaseYield?.();

      const result = await syncPromise;
      expect(result).toMatchObject({ added: 2, sessionsChecked: 2, cancelled: false });

      expect(index.search("live updated content token", "ws-live", 10)).toMatchObject([
        {
          sessionId: snapshotTarget.id,
          workspaceId: "ws-live",
          title: "live title token live first message",
        },
      ]);
      expect(index.search("snapshot old content token", "ws-snapshot", 10)).toEqual([]);

      const db = openDatabase(join(dataDir, "session-search.db"));
      try {
        const metadata = db
          .prepare("SELECT jsonl_path FROM fts_meta WHERE session_id = ?")
          .get(snapshotTarget.id) as { jsonl_path: string } | undefined;
        expect(metadata?.jsonl_path).toBe(livePath);
      } finally {
        db.close();
      }
    } finally {
      releaseYield?.();
      index.close();
    }
  });

  it("yields between bounded batches", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-yield-"));
    cleanupPaths.add(dataDir);

    const sessions = [
      makeFileSession(dataDir, "background-yield-1", "yieldone", "answerone"),
      makeFileSession(dataDir, "background-yield-2", "yieldtwo", "answertwo"),
      makeFileSession(dataDir, "background-yield-3", "yieldthree", "answerthree"),
    ];
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    try {
      let yieldCount = 0;
      const result = await index.startBackgroundSync(sessions, {
        batchSize: 1,
        yieldToEventLoop: async () => {
          yieldCount++;
        },
      });

      expect(yieldCount).toBe(2);
      expect(result).toMatchObject({
        added: 3,
        sessionsChecked: 3,
        cancelled: false,
      });
      expect(result.maxBatchMs).toBeGreaterThanOrEqual(0);
    } finally {
      index.close();
    }
  });

  it("lets other event-loop work run before background sync completes", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-event-loop-"));
    cleanupPaths.add(dataDir);

    const sessions = [
      makeFileSession(dataDir, "event-loop-1", "eventloopone", "answerone"),
      makeFileSession(dataDir, "event-loop-2", "eventlooptwo", "answertwo"),
      makeFileSession(dataDir, "event-loop-3", "eventloopthree", "answerthree"),
    ];
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    try {
      let syncComplete = false;
      const otherWork = new Promise<boolean>((resolve) => {
        setImmediate(() => resolve(!syncComplete));
      });

      const syncPromise = index.startBackgroundSync(sessions, { batchSize: 1 });
      expect(await otherWork).toBe(true);
      await syncPromise;
      syncComplete = true;
    } finally {
      index.close();
    }
  });

  it("matches blocking sync for added, updated, and deleted sessions", async () => {
    const blockingDir = mkdtempSync(join(tmpdir(), "search-index-background-blocking-"));
    const backgroundDir = mkdtempSync(join(tmpdir(), "search-index-background-equivalent-"));
    cleanupPaths.add(blockingDir);
    cleanupPaths.add(backgroundDir);

    const buildFixture = (dataDir: string) => {
      const updatedSeed = makeFileSession(
        dataDir,
        "equivalent-updated",
        "oldcontenttoken",
        "oldassistanttoken",
        { name: "oldtitletoken" },
      );
      const unchangedSeed = makeFileSession(
        dataDir,
        "equivalent-unchanged",
        "unchangedcontenttoken",
        "unchangedassistanttoken",
      );
      const deletedSeed = makeFileSession(
        dataDir,
        "equivalent-deleted",
        "deletedcontenttoken",
        "deletedassistanttoken",
      );
      const addedSeed = makeFileSession(
        dataDir,
        "equivalent-added",
        "addedcontenttoken",
        "addedassistanttoken",
        { name: "newtitletoken" },
      );
      const updated = cloneSession(updatedSeed);
      const unchanged = cloneSession(unchangedSeed);
      const deleted = cloneSession(deletedSeed);
      const added = cloneSession(addedSeed);
      return {
        updated,
        deleted,
        initial: [
          cloneSession(updatedSeed),
          cloneSession(unchangedSeed),
          cloneSession(deletedSeed),
        ],
        current: [cloneSession(updatedSeed), cloneSession(unchangedSeed), cloneSession(addedSeed)],
        liveSessions: new Map(
          [updated, unchanged, deleted, added].map((session) => [session.id, session]),
        ),
      };
    };

    const blockingFixture = buildFixture(blockingDir);
    const backgroundFixture = buildFixture(backgroundDir);
    expect(blockingFixture.initial[0]).not.toBe(blockingFixture.current[0]);
    expect(blockingFixture.current[0]).not.toBe(blockingFixture.updated);
    const blockingMap = blockingFixture.liveSessions;
    const backgroundMap = backgroundFixture.liveSessions;
    const blocking = new SearchIndex(blockingDir, (id) => blockingMap.get(id));
    const background = new SearchIndex(backgroundDir, (id) => backgroundMap.get(id));

    try {
      blocking.sync(blockingFixture.initial);
      background.sync(backgroundFixture.initial);

      blockingFixture.updated.name = "newupdatedtitletoken";
      backgroundFixture.updated.name = "newupdatedtitletoken";
      writeJsonl(blockingFixture.updated.piSessionFile!, "newcontenttoken", "newassistanttoken");
      writeJsonl(backgroundFixture.updated.piSessionFile!, "newcontenttoken", "newassistanttoken");
      const future = new Date(Date.now() + 5_000);
      utimesSync(blockingFixture.updated.piSessionFile!, future, future);
      utimesSync(backgroundFixture.updated.piSessionFile!, future, future);

      // Real deletes remove the session from storage before the next sync snapshot.
      // Keep the mock maps honest so background orphan checks match production.
      blockingMap.delete(blockingFixture.deleted.id);
      backgroundMap.delete(backgroundFixture.deleted.id);

      const blockingResult = blocking.sync(blockingFixture.current);
      const backgroundResult = await background.startBackgroundSync(backgroundFixture.current, {
        batchSize: 1,
      });

      expect(backgroundResult).toMatchObject({
        added: blockingResult.added,
        reindexed: blockingResult.reindexed,
        removed: blockingResult.removed,
        skipped: blockingResult.skipped,
        transcriptsRead: blockingResult.transcriptsRead,
        transcriptBytesRead: blockingResult.transcriptBytesRead,
        reusedIndexedTranscript: blockingResult.reusedIndexedTranscript,
        transcriptsReindexed: blockingResult.transcriptsReindexed,
        sessionsChecked: 3,
        cancelled: false,
      });

      for (const query of [
        "newcontenttoken",
        "newupdatedtitletoken",
        "addedcontenttoken",
        "deletedcontenttoken",
      ]) {
        const blockingResults = blocking
          .search(query, "ws-1", 10)
          .map(({ sessionId, workspaceId, title }) => ({ sessionId, workspaceId, title }));
        const backgroundResults = background
          .search(query, "ws-1", 10)
          .map(({ sessionId, workspaceId, title }) => ({ sessionId, workspaceId, title }));
        expect(backgroundResults).toEqual(blockingResults);
      }
      expect(background.search("deletedcontenttoken", "ws-1", 10)).toEqual([]);
    } finally {
      blocking.close();
      background.close();
    }
  });

  it("cancels after close without continuing later batches or throwing", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-cancel-"));
    cleanupPaths.add(dataDir);

    const sessions = [
      makeFileSession(dataDir, "cancel-first", "cancelfirsttoken", "firstanswer"),
      makeFileSession(dataDir, "cancel-second", "cancelsecondtoken", "secondanswer"),
      makeFileSession(dataDir, "cancel-third", "cancelthirdtoken", "thirdanswer"),
    ];
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    let releaseYield!: () => void;
    let notifyYield!: () => void;
    const yieldStarted = new Promise<void>((resolve) => {
      notifyYield = resolve;
    });
    const yieldGate = new Promise<void>((resolve) => {
      releaseYield = resolve;
    });

    const syncPromise = index.startBackgroundSync(sessions, {
      batchSize: 1,
      yieldToEventLoop: async () => {
        notifyYield();
        await yieldGate;
      },
    });

    await yieldStarted;
    index.close();
    releaseYield();

    const result = await syncPromise;
    expect(result).toMatchObject({
      cancelled: true,
      sessionsChecked: 1,
    });

    const reopened = new SearchIndex(dataDir, (id) => sessionMap.get(id));
    try {
      expect(reopened.search("cancelfirsttoken", "ws-1", 10)).toHaveLength(1);
      expect(reopened.search("cancelsecondtoken", "ws-1", 10)).toEqual([]);
      expect(reopened.search("cancelthirdtoken", "ws-1", 10)).toEqual([]);
    } finally {
      reopened.close();
    }
  });

  it("keeps sessions indexed live during warming out of the orphan sweep", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-live-orphan-"));
    cleanupPaths.add(dataDir);

    const snapshotSessions = [
      makeFileSession(dataDir, "live-orphan-a", "liveorphana", "answera"),
      makeFileSession(dataDir, "live-orphan-b", "liveorphanb", "answerb"),
    ];
    // Seed a true orphan so the sweep still has something real to remove.
    const staleOrphan = makeFileSession(
      dataDir,
      "live-orphan-stale",
      "liveorphanstale",
      "answerstale",
    );
    const sessionMap = new Map(
      [...snapshotSessions, staleOrphan].map((session) => [session.id, session]),
    );
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    let releaseYield!: () => void;
    let notifyYield!: () => void;
    const yieldStarted = new Promise<void>((resolve) => {
      notifyYield = resolve;
    });
    const yieldGate = new Promise<void>((resolve) => {
      releaseYield = resolve;
    });

    try {
      index.sync([...snapshotSessions, staleOrphan]);
      sessionMap.delete(staleOrphan.id);
      if (staleOrphan.piSessionFile) unlinkSync(staleOrphan.piSessionFile);

      const syncPromise = index.startBackgroundSync(snapshotSessions, {
        batchSize: 1,
        yieldToEventLoop: async () => {
          notifyYield();
          await yieldGate;
        },
      });

      await yieldStarted;

      // Simulate agent_end for a session created after the startup snapshot.
      const liveCreated = makeFileSession(
        dataDir,
        "live-orphan-new",
        "liveorphannewtoken",
        "answernew",
        { name: "live new session title" },
      );
      sessionMap.set(liveCreated.id, liveCreated);
      index.indexSession(liveCreated.id);

      expect(index.search("liveorphannewtoken", "ws-1", 10)).toHaveLength(1);

      releaseYield();
      const result = await syncPromise;

      expect(result.cancelled).toBe(false);
      expect(result.removed).toBe(1);
      expect(index.search("liveorphannewtoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("liveorphanstale", "ws-1", 10)).toEqual([]);
      expect(index.search("liveorphana", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("does not delete a session recreated after orphan discovery", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-recreated-orphan-"));
    cleanupPaths.add(dataDir);

    const orphan = makeFileSession(
      dataDir,
      "recreated-orphan",
      "orphan content token",
      "orphan answer",
      { name: "orphan title token" },
    );
    const liveSessions = new Map([[orphan.id, orphan]]);
    const index = new SearchIndex(dataDir, (id) => liveSessions.get(id));

    try {
      index.sync([orphan]);
      liveSessions.delete(orphan.id);
      const recreated = makeFileSession(
        dataDir,
        orphan.id,
        "recreated content token",
        "recreated answer",
        { name: "recreated title token" },
      );

      const result = await index.startBackgroundSync([], {
        yieldToEventLoop: async () => {
          liveSessions.set(recreated.id, recreated);
          index.indexSession(recreated.id);
        },
      });

      expect(result).toMatchObject({ removed: 0, sessionsChecked: 0, cancelled: false });
      expect(index.search("recreated content token", "ws-1", 10)).toMatchObject([
        { sessionId: recreated.id, title: "recreated title token" },
      ]);
    } finally {
      index.close();
    }
  });

  it("does not resurrect a session deleted while background sync is yielding", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-delete-ghost-"));
    cleanupPaths.add(dataDir);

    const keep = makeFileSession(dataDir, "ghost-keep", "ghostkeeptoken", "keepanswer", {
      name: "keep title token",
    });
    const doomed = makeFileSession(dataDir, "ghost-doomed", "ghostdoomedtoken", "doomedanswer", {
      name: "doomed title token",
    });
    const sessionMap = new Map([keep, doomed].map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    let releaseYield!: () => void;
    let notifyYield!: () => void;
    const yieldStarted = new Promise<void>((resolve) => {
      notifyYield = resolve;
    });
    const yieldGate = new Promise<void>((resolve) => {
      releaseYield = resolve;
    });

    try {
      index.sync([keep, doomed]);
      expect(index.search("doomed title token", "ws-1", 10)).toHaveLength(1);

      const syncPromise = index.startBackgroundSync([keep, doomed], {
        batchSize: 1,
        yieldToEventLoop: async () => {
          notifyYield();
          await yieldGate;
        },
      });

      await yieldStarted;

      // Lifecycle delete: remove file + storage + index row while warming still holds doomed.
      if (doomed.piSessionFile) unlinkSync(doomed.piSessionFile);
      sessionMap.delete(doomed.id);
      index.deleteSession(doomed.id);
      expect(index.search("doomed title token", "ws-1", 10)).toEqual([]);
      expect(index.search("ghostdoomedtoken", "ws-1", 10)).toEqual([]);

      releaseYield();
      const result = await syncPromise;

      expect(result.cancelled).toBe(false);
      expect(index.search("doomed title token", "ws-1", 10)).toEqual([]);
      expect(index.search("ghostdoomedtoken", "ws-1", 10)).toEqual([]);
      expect(index.search("ghostkeeptoken", "ws-1", 10)).toHaveLength(1);

      const db = openDatabase(join(dataDir, "session-search.db"));
      try {
        const fts = db
          .prepare("SELECT session_id FROM session_fts WHERE session_id = ?")
          .all(doomed.id) as { session_id: string }[];
        const meta = db
          .prepare("SELECT session_id FROM fts_meta WHERE session_id = ?")
          .all(doomed.id) as { session_id: string }[];
        expect(fts).toEqual([]);
        expect(meta).toEqual([]);
      } finally {
        db.close();
      }
    } finally {
      index.close();
    }
  });

  it("returns the in-flight promise when startBackgroundSync is called twice", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-double-start-"));
    cleanupPaths.add(dataDir);

    const sessions = [
      makeFileSession(dataDir, "double-a", "doubleatoken", "answera"),
      makeFileSession(dataDir, "double-b", "doublebtoken", "answerb"),
    ];
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    let releaseYield!: () => void;
    let notifyYield!: () => void;
    let yieldCount = 0;
    const yieldStarted = new Promise<void>((resolve) => {
      notifyYield = resolve;
    });
    const yieldGate = new Promise<void>((resolve) => {
      releaseYield = resolve;
    });

    try {
      const first = index.startBackgroundSync(sessions, {
        batchSize: 1,
        yieldToEventLoop: async () => {
          yieldCount++;
          notifyYield();
          await yieldGate;
        },
      });
      const second = index.startBackgroundSync(
        [makeFileSession(dataDir, "double-ignored", "ignoredtoken", "ignored")],
        { batchSize: 1 },
      );

      expect(second).toBe(first);

      await yieldStarted;
      releaseYield();
      const result = await first;

      expect(result).toMatchObject({
        added: 2,
        sessionsChecked: 2,
        cancelled: false,
      });
      expect(yieldCount).toBe(1);
      expect(index.search("doubleatoken", "ws-1", 10)).toHaveLength(1);
      expect(index.search("ignoredtoken", "ws-1", 10)).toEqual([]);
    } finally {
      index.close();
    }
  });

  it("resolves cancelled when startBackgroundSync is called after close", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-after-close-"));
    cleanupPaths.add(dataDir);

    const session = makeFileSession(dataDir, "after-close", "afterclosetoken", "answer");
    const sessionMap = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));
    index.close();

    const result = await index.startBackgroundSync([session], { batchSize: 1 });
    expect(result).toEqual({
      reindexed: 0,
      added: 0,
      removed: 0,
      skipped: 0,
      transcriptsRead: 0,
      transcriptBytesRead: 0,
      reusedIndexedTranscript: 0,
      transcriptsReindexed: 0,
      cancelled: true,
      sessionsChecked: 0,
      maxBatchMs: 0,
    });
  });

  it("still processes one session per batch when budgetMs is 0", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-budget-zero-"));
    cleanupPaths.add(dataDir);

    const sessions = [
      makeFileSession(dataDir, "budget-zero-1", "budgetzeroone", "answerone"),
      makeFileSession(dataDir, "budget-zero-2", "budgetzerotwo", "answertwo"),
    ];
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    try {
      let yieldCount = 0;
      const result = await index.startBackgroundSync(sessions, {
        batchSize: 10,
        budgetMs: 0,
        yieldToEventLoop: async () => {
          yieldCount++;
        },
      });

      expect(yieldCount).toBe(1);
      expect(result).toMatchObject({
        added: 2,
        sessionsChecked: 2,
        cancelled: false,
      });
      expect(index.search("budgetzeroone", "ws-1", 10)).toHaveLength(1);
      expect(index.search("budgetzerotwo", "ws-1", 10)).toHaveLength(1);
    } finally {
      index.close();
    }
  });

  it("skips an already-indexed set in one turn and does not log each batch", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-index-background-skip-only-"));
    cleanupPaths.add(dataDir);

    const sessions = Array.from({ length: 24 }, (_, index) =>
      makeFileSession(
        dataDir,
        `skip-only-${index}`,
        `skiponlytoken${index}`,
        `skiponlyanswer${index}`,
      ),
    );
    const sessionMap = new Map(sessions.map((session) => [session.id, session]));
    const index = new SearchIndex(dataDir, (id) => sessionMap.get(id));

    const stderrChunks: string[] = [];
    const originalWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = ((chunk: unknown, ...args: unknown[]) => {
      stderrChunks.push(String(chunk));
      return (originalWrite as (chunk: unknown, ...args: unknown[]) => boolean)(chunk, ...args);
    }) as typeof process.stderr.write;

    try {
      await index.startBackgroundSync(sessions);
      stderrChunks.length = 0;

      let yieldCount = 0;
      const result = await index.startBackgroundSync(sessions, {
        yieldToEventLoop: async () => {
          yieldCount++;
        },
      });

      expect(result).toMatchObject({
        skipped: 24,
        added: 0,
        reindexed: 0,
        sessionsChecked: 24,
        cancelled: false,
      });
      expect(yieldCount).toBe(0);
      expect(stderrChunks.some((chunk) => chunk.includes("search_index.sync_batch"))).toBe(false);
    } finally {
      process.stderr.write = originalWrite;
      index.close();
    }
  });
});
