import { randomUUID } from "node:crypto";
import { rmSync, utimesSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { SearchIndex } from "../src/search-index.js";
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

const cleanupPaths = new Set<string>();

afterEach(() => {
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
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

    const session = makeSession({ id: "sess-summary", piSessionId, piSessionFile: jsonlPath });
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

    const session = makeSession({ id: "sess-reindex", piSessionId, piSessionFile: jsonlPath });
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
