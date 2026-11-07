import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { SearchIndex } from "../src/search-index.js";
import { openDatabase } from "../src/sqlite-compat.js";
import {
  extractSearchTranscriptAddition,
  extractSearchTranscriptFromEntries,
  mergeSearchTranscript,
  readSearchTranscriptFile,
  SearchAdditionJoiner,
} from "../src/search-transcript.js";
import { readSessionTraceFromFile, type SessionEntry } from "../src/trace.js";
import type { Session } from "../src/types.js";

const USER_MESSAGE_CAP = 50_000;
const ASSISTANT_MESSAGE_CAP = 100_000;

const cleanupPaths = new Set<string>();

afterEach(() => {
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
});

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-search-extract",
    workspaceId: "ws-1",
    name: "Search extract session",
    status: "stopped",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

/** Mobile text renders inline media as data URIs; search never indexes them. */
const INLINE_MEDIA = /\n?data:[a-z0-9.+-]+\/[a-z0-9.+-]+;base64,[a-z0-9+/=_-]*/gi;

/**
 * Oracle: search fields after mobile TraceEvent construction + filter over the full current
 * branch, minus inline media. A field over its cap keeps its newest characters. (The fixtures
 * here cut only inside unbroken runs, where the extractor keeps the exact cut.)
 */
function searchableFieldsFromMobileTrace(jsonlPath: string): {
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
} | null {
  const events = readSessionTraceFromFile(jsonlPath, { view: "full" });
  if (!events) return null;

  const userParts: string[] = [];
  const assistantParts: string[] = [];
  const toolNameSet = new Set<string>();

  for (const event of events) {
    const text = event.text?.replace(INLINE_MEDIA, "");
    if (event.type === "user" && text) {
      userParts.push(text);
    } else if (event.type === "assistant" && text) {
      assistantParts.push(text);
    } else if (event.type === "toolCall" && event.tool) {
      toolNameSet.add(event.tool);
    }
  }

  const newest = (parts: string[], cap: number): string => {
    const joined = parts.join("\n");
    return joined.length > cap ? joined.slice(-cap) : joined;
  };
  return {
    userMessages: newest(userParts, USER_MESSAGE_CAP),
    assistantMessages: newest(assistantParts, ASSISTANT_MESSAGE_CAP),
    toolNames: [...toolNameSet].join(" "),
  };
}

function readIndexedFields(
  dataDir: string,
  sessionId: string,
): {
  title: string;
  user_messages: string;
  assistant_messages: string;
  tool_names: string;
} {
  const db = openDatabase(join(dataDir, "session-search.db"));
  try {
    const row = db
      .prepare(
        "SELECT title, user_messages, assistant_messages, tool_names FROM session_fts WHERE session_id = ?",
      )
      .get(sessionId) as
      | {
          title: string;
          user_messages: string;
          assistant_messages: string;
          tool_names: string;
        }
      | undefined;
    if (!row) {
      throw new Error(`missing FTS row for ${sessionId}`);
    }
    return row;
  } finally {
    db.close();
  }
}

function writeJsonlEntries(jsonlPath: string, entries: unknown[]): void {
  writeFileSync(jsonlPath, entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
}

function writeSearchFixture(jsonlPath: string): {
  discardedTokens: string[];
  retainedTokens: string[];
} {
  const hiddenResult = `${"result-hidden-".repeat(400)}secrethiddentoolresulttoken`;
  const keptResult = `${"result-kept-".repeat(400)}secretkepttoolresulttoken`;
  const postResult = `${"result-post-".repeat(400)}secretposttoolresulttoken`;
  const userImageData = "iVBORw0KGgoAAAANS";

  const lines = [
    {
      type: "session",
      id: randomUUID(),
      cwd: "/tmp/search-extract",
      timestamp: "2026-01-01T00:00:00Z",
    },
    {
      type: "message",
      id: "u-hidden",
      parentId: null,
      timestamp: "2026-01-01T00:00:01Z",
      message: { role: "user", content: "hiddencompacttoken old user text" },
    },
    {
      type: "message",
      id: "a-hidden",
      parentId: "u-hidden",
      timestamp: "2026-01-01T00:00:02Z",
      message: {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "secretthinkingtoken should not be indexed" },
          { type: "text", text: "hiddenassistantcompacttoken" },
          { type: "toolCall", id: "tc-hidden", name: "hidden_tool_token", arguments: { q: "no" } },
        ],
      },
    },
    {
      type: "message",
      id: "r-hidden",
      parentId: "a-hidden",
      timestamp: "2026-01-01T00:00:03Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-hidden",
        toolName: "hidden_tool_token",
        content: hiddenResult,
      },
    },
    {
      type: "message",
      id: "u-kept",
      parentId: "r-hidden",
      timestamp: "2026-01-01T00:00:04Z",
      message: {
        role: "user",
        content: [
          { type: "text", text: "keptcompacttoken visible user text" },
          { type: "image", mimeType: "image/png", data: userImageData },
        ],
      },
    },
    {
      type: "message",
      id: "a-kept",
      parentId: "u-kept",
      timestamp: "2026-01-01T00:00:05Z",
      message: {
        role: "assistant",
        content: [
          { type: "output_text", text: "keptassistantcompacttoken" },
          { type: "toolCall", id: "tc-kept", name: "bash", arguments: { command: "ls" } },
          { type: "toolCall", id: "tc-kept-2", name: "", arguments: {} },
        ],
      },
    },
    {
      type: "message",
      id: "r-kept",
      parentId: "a-kept",
      timestamp: "2026-01-01T00:00:06Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-kept",
        toolName: "bash",
        content: [
          { type: "text", text: keptResult },
          { type: "image", mimeType: "image/gif", data: "R0lGODlhAQABAIAAAP" },
        ],
      },
    },
    {
      type: "message",
      id: "u-inactive",
      parentId: "a-kept",
      timestamp: "2026-01-01T00:00:07Z",
      message: { role: "user", content: "inactivebranchtoken stale branch text" },
    },
    {
      type: "compaction",
      id: "c1",
      parentId: "r-kept",
      timestamp: "2026-01-01T00:00:08Z",
      summary: "summarycompacttoken should not become indexed assistant text",
      firstKeptEntryId: "u-kept",
      tokensBefore: 12345,
    },
    {
      type: "message",
      id: "u-post",
      parentId: "c1",
      timestamp: "2026-01-01T00:00:09Z",
      message: {
        role: "user",
        content: `postcompacttoken visible follow-up broken \uD83D... ok 😀`,
      },
    },
    {
      type: "message",
      id: "a-post",
      parentId: "u-post",
      timestamp: "2026-01-01T00:00:10Z",
      message: {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "moresecretthinkingtoken" },
          { type: "text", text: "postassistantcompacttoken" },
          { type: "toolCall", id: "tc-post", name: "read", arguments: { path: "/tmp/x" } },
        ],
      },
    },
    {
      type: "message",
      id: "r-post",
      parentId: "a-post",
      timestamp: "2026-01-01T00:00:11Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-post",
        toolName: "read",
        content: postResult,
      },
    },
    {
      type: "custom_message",
      id: "custom-1",
      parentId: "r-post",
      timestamp: "2026-01-01T00:00:12Z",
      display: true,
      content: "customcardtoken should not be indexed",
    },
    {
      type: "thinking_level_change",
      id: "tl-1",
      parentId: "custom-1",
      timestamp: "2026-01-01T00:00:13Z",
      thinkingLevel: "high",
    },
  ];

  writeFileSync(jsonlPath, lines.map((line) => JSON.stringify(line)).join("\n") + "\n");

  return {
    discardedTokens: [
      "secretthinkingtoken",
      "moresecretthinkingtoken",
      "secrethiddentoolresulttoken",
      "secretkepttoolresulttoken",
      "secretposttoolresulttoken",
      "summarycompacttoken",
      "inactivebranchtoken",
      "customcardtoken",
      "R0lGODlhAQABAIAAAP",
      "iVBORw0KGgoAAAANS",
      "base64",
    ],
    retainedTokens: [
      // From before the compaction: search covers the whole current branch.
      "hiddencompacttoken",
      "hiddenassistantcompacttoken",
      "hidden_tool_token",
      "keptcompacttoken",
      "keptassistantcompacttoken",
      "postcompacttoken",
      "postassistantcompacttoken",
    ],
  };
}

describe("search transcript extraction fields", () => {
  it("indexes the same user, assistant, and tool fields the mobile trace filter would keep", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    const { discardedTokens, retainedTokens } = writeSearchFixture(jsonlPath);

    const oracle = searchableFieldsFromMobileTrace(jsonlPath);
    expect(oracle).not.toBeNull();
    if (!oracle) return;

    expect(readSearchTranscriptFile(jsonlPath)?.transcript ?? null).toEqual(oracle);

    const session = makeSession({ piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(1);

      const indexed = readIndexedFields(dataDir, session.id);
      expect(indexed.user_messages).toBe(oracle.userMessages);
      expect(indexed.assistant_messages).toBe(oracle.assistantMessages);
      expect(indexed.tool_names).toBe(oracle.toolNames);

      expect(oracle.toolNames.split(" ").sort()).toEqual([
        "bash",
        "hidden_tool_token",
        "read",
        "unknown",
      ]);
      expect(oracle.userMessages).toContain("broken \uFFFD... ok 😀");
      expect(oracle.userMessages).not.toContain("\uD83D...");
      expect(oracle.assistantMessages).not.toContain("secretthinkingtoken");
      expect(oracle.assistantMessages).not.toContain("secretkepttoolresulttoken");

      const haystack = `${oracle.userMessages}\n${oracle.assistantMessages}\n${oracle.toolNames}`;
      for (const token of retainedTokens) {
        expect(haystack).toContain(token);
      }
      for (const token of discardedTokens) {
        expect(haystack).not.toContain(token);
      }
    } finally {
      index.close();
    }
  });

  it("caps user and assistant fields to their newest text, as the mobile filter's full branch would", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-cap-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");

    const userChunk = "U".repeat(20_000);
    const assistantChunk = "A".repeat(40_000);
    const lines = [
      JSON.stringify({
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "user", content: `${userChunk}userone` },
      }),
      JSON.stringify({
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: { role: "assistant", content: `${assistantChunk}assistone` },
      }),
      JSON.stringify({
        type: "message",
        id: "u2",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:03Z",
        message: { role: "user", content: `${userChunk}usertwo` },
      }),
      JSON.stringify({
        type: "message",
        id: "a2",
        parentId: "u2",
        timestamp: "2026-01-01T00:00:04Z",
        message: { role: "assistant", content: `${assistantChunk}assisttwo` },
      }),
      JSON.stringify({
        type: "message",
        id: "u3",
        parentId: "a2",
        timestamp: "2026-01-01T00:00:05Z",
        message: { role: "user", content: `${userChunk}userthree` },
      }),
      JSON.stringify({
        type: "message",
        id: "a3",
        parentId: "u3",
        timestamp: "2026-01-01T00:00:06Z",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: `${assistantChunk}assistthree` },
            { type: "toolCall", id: "tc-late", name: "late_tool_token", arguments: {} },
          ],
        },
      }),
    ];
    writeFileSync(jsonlPath, lines.join("\n") + "\n");

    const oracle = searchableFieldsFromMobileTrace(jsonlPath);
    expect(oracle).not.toBeNull();
    if (!oracle) return;
    expect(oracle.userMessages.length).toBe(USER_MESSAGE_CAP);
    expect(oracle.assistantMessages.length).toBe(ASSISTANT_MESSAGE_CAP);
    expect(oracle.toolNames).toBe("late_tool_token");
    expect(readSearchTranscriptFile(jsonlPath)?.transcript ?? null).toEqual(oracle);

    const session = makeSession({ id: "sess-cap", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      index.sync([session]);
      const indexed = readIndexedFields(dataDir, session.id);
      expect(indexed.user_messages).toBe(oracle.userMessages);
      expect(indexed.assistant_messages).toBe(oracle.assistantMessages);
      expect(indexed.tool_names).toBe(oracle.toolNames);
    } finally {
      index.close();
    }
  });

  it("merges an appended turn into earlier fields exactly as one full extraction yields them", () => {
    // Deterministic pseudo-random sessions: message sizes from a few characters to well past a cap,
    // words of 1-12 characters or, now and then, one unbroken run longer than the partial-word
    // window, so cuts land in words, in runs, between messages, and between turns.
    let seed = 20_261_106;
    const next = (n: number): number => {
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648;
      return seed % n;
    };
    const text = (length: number): string => {
      let out = "";
      while (out.length < length) {
        out += next(40) === 0 ? "r".repeat(80 + next(400)) : "w".repeat(1 + next(12));
        out += next(6) === 0 ? "\n" : " ";
      }
      return out.slice(0, length);
    };
    for (let session = 0; session < 10; session++) {
      const entries: SessionEntry[] = [];
      for (let n = 0; n < 12 + next(30); n++) {
        const role = n % 2 === 0 ? "user" : "assistant";
        const length = next(4) === 0 ? 20_000 + next(90_000) : 1 + next(3_000);
        const body = `${n}:${text(length)}`;
        entries.push({
          type: "message",
          id: `e${n}`,
          parentId: n === 0 ? null : `e${n - 1}`,
          timestamp: "2026-01-01T00:00:00Z",
          message: {
            role,
            content:
              role === "user"
                ? body
                : [
                    { type: "text", text: body },
                    { type: "toolCall", id: `c${n}`, name: `tool_${n % 5}`, arguments: {} },
                  ],
          },
        } as SessionEntry);
      }
      const full = extractSearchTranscriptFromEntries(entries);
      // Append in turns of one to five entries, the way turn-end indexing does.
      let done = 1;
      let indexed = extractSearchTranscriptFromEntries(entries.slice(0, done));
      while (done < entries.length) {
        const upTo = Math.min(entries.length, done + 1 + next(5));
        indexed = mergeSearchTranscript(
          indexed,
          extractSearchTranscriptAddition(entries.slice(done, upTo)),
        );
        done = upTo;
        expect(indexed).toEqual(extractSearchTranscriptFromEntries(entries.slice(0, done)));
      }
      expect(indexed).toEqual(full);

      // A full read in pages (a durable conversation read a page at a time) lands on the same fields.
      const joiner = new SearchAdditionJoiner();
      for (let from = 0; from < entries.length;) {
        const to = Math.min(entries.length, from + 1 + next(7));
        joiner.add(extractSearchTranscriptAddition(entries.slice(from, to)));
        from = to;
      }
      expect(
        mergeSearchTranscript(
          { userMessages: "", assistantMessages: "", toolNames: "" },
          joiner.result(),
        ),
      ).toEqual(full);
    }
  });

  it("merges to a full extraction when the cap falls on the newline before a message", () => {
    // The newest message starts with whitespace and fills the cap with the newline before it (or
    // one under it), so the cut lands on that newline and drops the older message whole.
    for (const newest of [
      ` ${"y".repeat(USER_MESSAGE_CAP - 1)}`,
      ` ${"y".repeat(USER_MESSAGE_CAP - 2)}`,
    ]) {
      const entries = ["older", newest].map(
        (content, n) =>
          ({
            type: "message",
            id: `e${n}`,
            parentId: n === 0 ? null : `e${n - 1}`,
            timestamp: "2026-01-01T00:00:00Z",
            message: { role: "user", content },
          }) as SessionEntry,
      );
      const full = extractSearchTranscriptFromEntries(entries);
      expect(full.userMessages).toBe(newest.trimStart());
      expect(
        mergeSearchTranscript(
          extractSearchTranscriptFromEntries(entries.slice(0, 1)),
          extractSearchTranscriptAddition(entries.slice(1)),
        ),
      ).toEqual(full);
    }
  });

  it("keeps inline media out of the field caps so later text stays searchable", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-media-cap-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    const screenshot = "A".repeat(USER_MESSAGE_CAP);
    writeJsonlEntries(jsonlPath, [
      {
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: {
          role: "user",
          content: [
            { type: "text", text: "see screenshot" },
            { type: "image", mimeType: "image/png", data: screenshot },
          ],
        },
      },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: {
          role: "assistant",
          content: `pasted data:image/jpeg;base64,${screenshot} inline`,
        },
      },
      {
        type: "message",
        id: "u2",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:03Z",
        message: { role: "user", content: "afterscreenshottoken follow-up" },
      },
    ]);

    const extracted = readSearchTranscriptFile(jsonlPath)?.transcript ?? null;
    expect(extracted?.userMessages).toBe("see screenshot\nafterscreenshottoken follow-up");
    expect(extracted?.assistantMessages).toMatch(/^pasted\s+inline$/);
  });

  it("returns null for a missing session file", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-missing-"));
    cleanupPaths.add(dataDir);
    expect(readSearchTranscriptFile(join(dataDir, "missing.jsonl"))?.transcript ?? null).toBeNull();
  });

  it("returns null for an unreadable session path", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-unreadable-"));
    cleanupPaths.add(dataDir);
    const unreadablePath = join(dataDir, "not-a-file");
    mkdirSync(unreadablePath);
    expect(readSearchTranscriptFile(unreadablePath)?.transcript ?? null).toBeNull();
  });

  it("indexes title with empty transcript fields when the jsonl is missing", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-missing-index-"));
    cleanupPaths.add(dataDir);
    const session = makeSession({
      id: "sess-missing-jsonl",
      name: "Missing Jsonl Title Token",
      piSessionFile: join(dataDir, "missing.jsonl"),
    });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(0);
      const indexed = readIndexedFields(dataDir, session.id);
      expect(indexed.title).toBe("Missing Jsonl Title Token");
      expect(indexed.user_messages).toBe("");
      expect(indexed.assistant_messages).toBe("");
      expect(indexed.tool_names).toBe("");
    } finally {
      index.close();
    }
  });

  it("indexes title with empty transcript fields when the jsonl is unreadable", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-unreadable-index-"));
    cleanupPaths.add(dataDir);
    const unreadablePath = join(dataDir, "not-a-file");
    mkdirSync(unreadablePath);
    const session = makeSession({
      id: "sess-unreadable-jsonl",
      name: "Unreadable Jsonl Title Token",
      piSessionFile: unreadablePath,
    });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      const result = index.sync([session]);
      expect(result.added).toBe(1);
      expect(result.transcriptsRead).toBe(0);
      const indexed = readIndexedFields(dataDir, session.id);
      expect(indexed.title).toBe("Unreadable Jsonl Title Token");
      expect(indexed.user_messages).toBe("");
      expect(indexed.assistant_messages).toBe("");
      expect(indexed.tool_names).toBe("");
    } finally {
      index.close();
    }
  });

  it("characterizes mobile fail-closed vs direct extract fail-open when toolResult extractText throws", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-bad-result-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonlEntries(jsonlPath, [
      {
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "user", content: "kept-user-after-bad-toolresult" },
      },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "kept-assistant-after-bad-toolresult" },
            { type: "toolCall", id: "tc-bad", name: "bash", arguments: {} },
          ],
        },
      },
      {
        type: "message",
        id: "r1",
        parentId: "a1",
        timestamp: "2026-01-01T00:00:03Z",
        message: {
          role: "toolResult",
          toolCallId: "tc-bad",
          toolName: "bash",
          content: [null],
        },
      },
    ]);

    expect(readSessionTraceFromFile(jsonlPath)).toBeNull();
    expect(searchableFieldsFromMobileTrace(jsonlPath)).toBeNull();
    expect(readSearchTranscriptFile(jsonlPath)?.transcript ?? null).toEqual({
      userMessages: "kept-user-after-bad-toolresult",
      assistantMessages: "kept-assistant-after-bad-toolresult",
      toolNames: "bash",
    });

    const session = makeSession({ id: "sess-bad-result", piSessionFile: jsonlPath });
    const sessions = new Map([[session.id, session]]);
    const index = new SearchIndex(dataDir, (id) => sessions.get(id));
    try {
      index.sync([session]);
      const indexed = readIndexedFields(dataDir, session.id);
      expect(indexed.user_messages).toBe("kept-user-after-bad-toolresult");
      expect(indexed.assistant_messages).toBe("kept-assistant-after-bad-toolresult");
      expect(indexed.tool_names).toBe("bash");
    } finally {
      index.close();
    }
  });

  it("matches the mobile filter for empty, surrogate, and non-string tool names", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "search-extract-tool-names-"));
    cleanupPaths.add(dataDir);
    const jsonlPath = join(dataDir, "session.jsonl");
    writeJsonlEntries(jsonlPath, [
      {
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "user", content: "tool-name-user" },
      },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "2026-01-01T00:00:02Z",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "tool-name-assistant" },
            { type: "toolCall", id: "tc-empty", name: "", arguments: {} },
            { type: "toolCall", id: "tc-surr", name: "grep\uD83D", arguments: {} },
            { type: "toolCall", id: "tc-num", name: 42, arguments: {} },
            { type: "toolCall", id: "tc-obj", name: { n: "x" }, arguments: {} },
            { type: "toolCall", id: "tc-arr", name: ["ba\uD800sh"], arguments: {} },
          ],
        },
      },
    ]);

    const oracle = searchableFieldsFromMobileTrace(jsonlPath);
    expect(oracle).not.toBeNull();
    if (!oracle) return;
    expect(oracle.toolNames).toBe(
      ["unknown", "grep\uFFFD", "42", "[object Object]", "ba\uFFFDsh"].join(" "),
    );
    expect(readSearchTranscriptFile(jsonlPath)?.transcript ?? null).toEqual(oracle);
  });
});
