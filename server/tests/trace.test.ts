import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseJsonl, readSessionTrace, buildSessionContext, type TraceEvent } from "../src/trace.js";

// ─── parseJsonl unit tests ───

describe("parseJsonl", () => {
  it("parses a user message", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-1",
      timestamp: "2026-01-01T00:00:00Z",
      message: { role: "user", content: "hello" },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("user");
    expect(events[0].text).toBe("hello");
    expect(events[0].timestamp).toBe("2026-01-01T00:00:00Z");
  });

  it("parses an assistant text message", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-2",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Hi there" }],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("assistant");
    expect(events[0].text).toBe("Hi there");
  });

  it("parses assistant string content", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-str",
      timestamp: "2026-01-01T00:00:01Z",
      message: { role: "assistant", content: "Plain string reply" },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("assistant");
    expect(events[0].text).toBe("Plain string reply");
  });

  it("parses thinking blocks", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-3",
      timestamp: "2026-01-01T00:00:02Z",
      message: {
        role: "assistant",
        content: [{ type: "thinking", thinking: "Let me think..." }],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("thinking");
    expect(events[0].thinking).toBe("Let me think...");
  });

  it("parses tool calls", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-4",
      timestamp: "2026-01-01T00:00:03Z",
      message: {
        role: "assistant",
        content: [{
          type: "toolCall",
          id: "tc-1",
          name: "bash",
          arguments: { command: "ls -la" },
        }],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("toolCall");
    expect(events[0].tool).toBe("bash");
    expect(events[0].args).toEqual({ command: "ls -la" });
  });

  it("parses tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-5",
      timestamp: "2026-01-01T00:00:04Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-1",
        toolName: "bash",
        content: "file1.txt\nfile2.txt",
        isError: false,
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("toolResult");
    expect(events[0].toolCallId).toBe("tc-1");
    expect(events[0].toolName).toBe("bash");
    expect(events[0].output).toBe("file1.txt\nfile2.txt");
    expect(events[0].isError).toBe(false);
  });

  it("parses error tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-err",
      timestamp: "2026-01-01T00:00:05Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-2",
        toolName: "bash",
        content: "Permission denied",
        isError: true,
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].isError).toBe(true);
  });

  it("parses multi-block assistant messages", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-multi",
      timestamp: "2026-01-01T00:00:06Z",
      message: {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "Analyzing..." },
          { type: "text", text: "Here is my answer" },
          { type: "toolCall", id: "tc-3", name: "read", arguments: { path: "foo.ts" } },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("thinking");
    expect(events[1].type).toBe("assistant");
    expect(events[2].type).toBe("toolCall");
  });

  it("handles multi-line JSONL", () => {
    const lines = [
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "first" },
      }),
      JSON.stringify({
        type: "message",
        id: "2",
        parentId: "1",
        timestamp: "2026-01-01T00:00:01Z",
        message: { role: "assistant", content: [{ type: "text", text: "second" }] },
      }),
    ].join("\n");

    const events = parseJsonl(lines);
    expect(events).toHaveLength(2);
    expect(events[0].text).toBe("first");
    expect(events[1].text).toBe("second");
  });

  it("skips non-message entries", () => {
    const lines = [
      JSON.stringify({ type: "system", info: "started" }),
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "hello" },
      }),
    ].join("\n");

    const events = parseJsonl(lines);
    expect(events).toHaveLength(1);
  });

  it("skips invalid JSON lines", () => {
    const lines = [
      "not json at all",
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "valid" },
      }),
    ].join("\n");

    const events = parseJsonl(lines);
    expect(events).toHaveLength(1);
    expect(events[0].text).toBe("valid");
  });

  it("skips blank lines", () => {
    const lines = [
      "",
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "hello" },
      }),
      "",
      "  ",
    ].join("\n");

    const events = parseJsonl(lines);
    expect(events).toHaveLength(1);
  });

  it("returns empty array for empty input", () => {
    expect(parseJsonl("")).toEqual([]);
  });

  it("handles toolCall with partialJson fallback", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-partial",
      timestamp: "2026-01-01T00:00:00Z",
      message: {
        role: "assistant",
        content: [{
          type: "toolCall",
          id: "tc-partial",
          name: "write",
          partialJson: '{"path":"test.ts","content":"hello"}',
        }],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].args).toEqual({ path: "test.ts", content: "hello" });
  });

  it("extracts image content blocks as data URIs in tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "img-result",
      timestamp: "2026-01-01T00:00:00Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-read-img",
        toolName: "Read",
        content: [
          { type: "image", data: "iVBORw0KGgoAAAANS", mimeType: "image/png" },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("toolResult");
    expect(events[0].output).toBe("data:image/png;base64,iVBORw0KGgoAAAANS");
  });

  it("extracts mixed text and image content blocks in tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "mixed-result",
      timestamp: "2026-01-01T00:00:00Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-mixed",
        toolName: "Read",
        content: [
          { type: "text", text: "File: screenshot.png" },
          { type: "image", data: "R0lGODlhAQABAIAAAP", mimeType: "image/gif" },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].output).toBe("File: screenshot.png\ndata:image/gif;base64,R0lGODlhAQABAIAAAP");
  });

  it("extracts audio content blocks as data URIs in tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "audio-result",
      timestamp: "2026-01-01T00:00:00Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-read-audio",
        toolName: "Read",
        content: [
          { type: "audio", data: "UklGRiQAAABXQVZF", mimeType: "audio/wav" },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("toolResult");
    expect(events[0].output).toBe("data:audio/wav;base64,UklGRiQAAABXQVZF");
  });

  it("extracts mixed text and audio content blocks in tool results", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "mixed-audio-result",
      timestamp: "2026-01-01T00:00:00Z",
      message: {
        role: "toolResult",
        toolCallId: "tc-audio-mixed",
        toolName: "Read",
        content: [
          { type: "text", text: "Generated clip" },
          { type: "audio", data: "UklGRiQAAABXQVZF", mimeType: "audio/wav" },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].output).toBe("Generated clip\ndata:audio/wav;base64,UklGRiQAAABXQVZF");
  });
});

// ─── readSessionTrace integration ───

describe("readSessionTrace", () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "oppi-server-trace-test-"));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true });
  });

  it("returns null when workspaceId is missing", () => {
    const result = readSessionTrace(tmp, "sess1");
    expect(result).toBeNull();
  });

  it("returns null when sessions dir does not exist", () => {
    const result = readSessionTrace(tmp, "sess1", "ws1");
    expect(result).toBeNull();
  });

  it("returns null when no JSONL files exist", () => {
    const dir = join(tmp, "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
    mkdirSync(dir, { recursive: true });

    const result = readSessionTrace(tmp, "sess1", "ws1");
    expect(result).toBeNull();
  });

  it("merges all JSONL files in chronological order", () => {
    const dir = join(tmp, "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
    mkdirSync(dir, { recursive: true });

    // Older file
    writeFileSync(join(dir, "2026-01-01_aaa.jsonl"), JSON.stringify({
      type: "message",
      id: "old",
      timestamp: "2026-01-01T00:00:00Z",
      message: { role: "user", content: "old message" },
    }));

    // Newer file (alphabetically last = most recent)
    writeFileSync(join(dir, "2026-01-02_bbb.jsonl"), JSON.stringify({
      type: "message",
      id: "new",
      parentId: "old",
      timestamp: "2026-01-02T00:00:00Z",
      message: { role: "user", content: "new message" },
    }));

    const events = readSessionTrace(tmp, "sess1", "ws1");
    expect(events).not.toBeNull();
    expect(events).toHaveLength(2);
    expect(events![0].text).toBe("old message");
    expect(events![1].text).toBe("new message");
  });

  it("parses a full conversation from JSONL file", () => {
    const dir = join(tmp, "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
    mkdirSync(dir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "list files" },
      }),
      JSON.stringify({
        type: "message",
        id: "2",
        parentId: "1",
        timestamp: "2026-01-01T00:00:01Z",
        message: {
          role: "assistant",
          content: [{ type: "toolCall", id: "tc-1", name: "bash", arguments: { command: "ls" } }],
        },
      }),
      JSON.stringify({
        type: "message",
        id: "3",
        parentId: "2",
        timestamp: "2026-01-01T00:00:02Z",
        message: {
          role: "toolResult",
          toolCallId: "tc-1",
          toolName: "bash",
          content: "file1.txt\nfile2.txt",
        },
      }),
    ].join("\n");

    writeFileSync(join(dir, "2026-01-01_session.jsonl"), lines);

    const events = readSessionTrace(tmp, "sess1", "ws1");
    expect(events).toHaveLength(3);
    expect(events![0].type).toBe("user");
    expect(events![1].type).toBe("toolCall");
    expect(events![2].type).toBe("toolResult");
  });
});

// ─── buildSessionContext edge cases (S5) ───

describe("buildSessionContext edge cases", () => {
  function entry(id: string, parentId: string | null, type: string, extra: Record<string, unknown> = {}): string {
    return JSON.stringify({ type, id, parentId, timestamp: `2026-01-01T00:00:0${id}Z`, ...extra });
  }

  function msgEntry(id: string, parentId: string | null, role: string, content: string): string {
    return entry(id, parentId, "message", { message: { role, content } });
  }

  it("returns empty for empty input", () => {
    const events = buildSessionContext([]);
    expect(events).toHaveLength(0);
  });

  it("handles single user message", () => {
    const entries = parseJsonl(msgEntry("1", null, "user", "hello"), { view: "full" });
    // parseJsonl uses buildSessionContext internally, just check it doesn't crash
    expect(entries.length).toBeGreaterThanOrEqual(1);
    expect(entries[0].type).toBe("user");
  });

  it("handles compaction with post-compaction messages", () => {
    const lines = [
      msgEntry("1", null, "user", "first question"),
      msgEntry("2", "1", "assistant", "first answer"),
      entry("3", "2", "compaction", { summary: "User asked a question and got an answer.", firstKeptEntryId: "2" }),
      msgEntry("4", "3", "user", "follow up"),
      msgEntry("5", "4", "assistant", "follow up answer"),
    ].join("\n");

    const events = parseJsonl(lines);
    // Context view: should show compaction summary + kept messages + post-compaction
    expect(events.some((e) => e.type === "compaction")).toBe(true);
    expect(events.some((e) => e.text === "follow up")).toBe(true);
    expect(events.some((e) => e.text === "follow up answer")).toBe(true);
    // Pre-compaction content before firstKeptEntryId should be hidden
    expect(events.find((e) => e.text === "first question")).toBeUndefined();
  });

  it("handles multi-compaction (compact twice)", () => {
    const lines = [
      msgEntry("1", null, "user", "q1"),
      msgEntry("2", "1", "assistant", "a1"),
      entry("3", "2", "compaction", { summary: "Summary 1", firstKeptEntryId: "2" }),
      msgEntry("4", "3", "user", "q2"),
      msgEntry("5", "4", "assistant", "a2"),
      entry("6", "5", "compaction", { summary: "Summary 2", firstKeptEntryId: "5" }),
      msgEntry("7", "6", "user", "q3"),
      msgEntry("8", "7", "assistant", "a3"),
    ].join("\n");

    const events = parseJsonl(lines);
    // The LAST compaction summary should be present
    expect(events.some((e) => e.type === "compaction")).toBe(true);
    // Post-second-compaction messages should be visible
    expect(events.some((e) => e.text === "q3")).toBe(true);
    expect(events.some((e) => e.text === "a3")).toBe(true);
    // Pre-second-compaction messages should be hidden in context view
    expect(events.find((e) => e.text === "q1")).toBeUndefined();
  });

  it("handles orphaned entry (parentId points to missing)", () => {
    // Entry "2" points to nonexistent "999" — walk stops early
    const lines = [
      msgEntry("2", "999", "user", "orphan"),
    ].join("\n");

    const events = parseJsonl(lines);
    // Should not crash, orphan is the leaf, walk stops at it
    expect(events).toHaveLength(1);
    expect(events[0].text).toBe("orphan");
  });

  it("handles session with only compaction entry", () => {
    const lines = entry("1", null, "compaction", {
      summary: "Previous context was compacted.",
      firstKeptEntryId: null,
    });

    const events = parseJsonl(lines);
    expect(events.some((e) => e.type === "compaction")).toBe(true);
  });

  it("handles branch with multiple children (fork)", () => {
    // Two children of entry "2" — simulates a fork
    const lines = [
      msgEntry("1", null, "user", "question"),
      msgEntry("2", "1", "assistant", "answer"),
      msgEntry("3a", "2", "user", "branch A follow-up"),
      msgEntry("3b", "2", "user", "branch B follow-up"),
      msgEntry("4a", "3a", "assistant", "branch A answer"),
    ].join("\n");

    const events = parseJsonl(lines);
    // Leaf is "4a" (last entry), so context should follow the A branch
    expect(events.some((e) => e.text === "branch A follow-up")).toBe(true);
    expect(events.some((e) => e.text === "branch A answer")).toBe(true);
    // Branch B follow-up is NOT on the leaf's ancestor path
    expect(events.find((e) => e.text === "branch B follow-up")).toBeUndefined();
  });

  it("full view includes pre-compaction entries", () => {
    const lines = [
      msgEntry("1", null, "user", "before compaction"),
      msgEntry("2", "1", "assistant", "response"),
      entry("3", "2", "compaction", { summary: "Compacted.", firstKeptEntryId: "2" }),
      msgEntry("4", "3", "user", "after compaction"),
    ].join("\n");

    const events = parseJsonl(lines, { view: "full" });
    // Full view should include everything
    expect(events.some((e) => e.text === "before compaction")).toBe(true);
    expect(events.some((e) => e.text === "after compaction")).toBe(true);
  });

  it("handles thinking content in assistant messages", () => {
    const lines = JSON.stringify({
      type: "message",
      id: "1",
      parentId: null,
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "Let me think about this..." },
          { type: "text", text: "Here's my answer." },
        ],
      },
    });

    const events = parseJsonl(lines);
    expect(events.some((e) => e.type === "thinking")).toBe(true);
    expect(events.some((e) => e.type === "assistant" && e.text === "Here's my answer.")).toBe(true);
  });

  it("handles model_change entries", () => {
    const lines = entry("1", null, "model_change", {
      provider: "anthropic",
      modelId: "claude-sonnet-4",
    });

    const events = parseJsonl(lines);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("system");
  });

  it("handles empty lines in JSONL gracefully", () => {
    const lines = [
      msgEntry("1", null, "user", "hello"),
      "",
      "",
      msgEntry("2", "1", "assistant", "hi"),
    ].join("\n");

    const events = parseJsonl(lines);
    expect(events.some((e) => e.text === "hello")).toBe(true);
    expect(events.some((e) => e.text === "hi")).toBe(true);
  });
});
