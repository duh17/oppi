import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  getSessionAttachment,
  materializeToolAudioDetails,
  materializeToolMediaContentBlocks,
} from "../src/session-attachments.js";
import {
  parseJsonl,
  readSessionTrace,
  buildSessionContext,
  replaceUnpairedSurrogates,
} from "../src/trace.js";

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

  it("normalizes unpaired surrogate text in mobile trace events", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-bad-surrogate",
      timestamp: "2026-01-01T00:00:01Z",
      message: { role: "assistant", content: [{ type: "text", text: "broken \uD83D... ok 😀" }] },
    });

    const events = parseJsonl(jsonl);
    const body = JSON.stringify({ trace: events });

    expect(events[0].text).toBe("broken �... ok 😀");
    expect(body).not.toContain("\\ud83d...");
  });

  it("normalizes unpaired surrogate object keys in mobile trace events", () => {
    const badKey = "bad\uD83Dkey";
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-bad-surrogate-key",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: "tc-1", name: "bash", arguments: { [badKey]: "ok" } }],
      },
    });

    const events = parseJsonl(jsonl);
    const body = JSON.stringify({ trace: events });

    expect(events[0].args).toEqual({ "bad�key": "ok" });
    expect(body).not.toContain("\\ud83d");
  });

  it("preserves valid surrogate pairs when normalizing trace text", () => {
    expect(replaceUnpairedSurrogates("ok 😀")).toBe("ok 😀");
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
        content: [
          {
            type: "toolCall",
            id: "tc-1",
            name: "bash",
            arguments: { command: "ls -la" },
          },
        ],
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
        content: [
          {
            type: "toolCall",
            id: "tc-partial",
            name: "write",
            partialJson: '{"path":"test.ts","content":"hello"}',
          },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].args).toEqual({ path: "test.ts", content: "hello" });
  });

  it("parses assistant output_text content blocks (Responses API format)", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-output-text",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [{ type: "output_text", text: "Response via output_text block" }],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("assistant");
    expect(events[0].text).toBe("Response via output_text block");
  });

  it("parses mixed output_text and text blocks in assistant message", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-mixed-text",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [
          { type: "output_text", text: "First part" },
          { type: "text", text: "Second part" },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    const assistantEvents = events.filter((e) => e.type === "assistant");
    expect(assistantEvents).toHaveLength(2);
    expect(assistantEvents[0].text).toBe("First part");
    expect(assistantEvents[1].text).toBe("Second part");
  });

  it("parses output_text alongside thinking and tool calls", () => {
    const jsonl = JSON.stringify({
      type: "message",
      id: "msg-full-turn",
      timestamp: "2026-01-01T00:00:01Z",
      message: {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "Let me think..." },
          { type: "output_text", text: "Here is my answer" },
          { type: "toolCall", id: "tc-5", name: "bash", arguments: { command: "echo hi" } },
        ],
      },
    });

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("thinking");
    expect(events[1].type).toBe("assistant");
    expect(events[1].text).toBe("Here is my answer");
    expect(events[2].type).toBe("toolCall");
  });

  it("does not drop assistant messages when all blocks are output_text", () => {
    // Regression: a full conversation where every assistant turn uses output_text
    // should produce assistant trace events, not just user + tool events.
    const lines = [
      JSON.stringify({
        type: "message",
        id: "1",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "hello" },
      }),
      JSON.stringify({
        type: "message",
        id: "2",
        parentId: "1",
        timestamp: "2026-01-01T00:00:01Z",
        message: {
          role: "assistant",
          content: [{ type: "output_text", text: "Hi there!" }],
        },
      }),
      JSON.stringify({
        type: "message",
        id: "3",
        parentId: "2",
        timestamp: "2026-01-01T00:00:02Z",
        message: { role: "user", content: "how are you?" },
      }),
      JSON.stringify({
        type: "message",
        id: "4",
        parentId: "3",
        timestamp: "2026-01-01T00:00:03Z",
        message: {
          role: "assistant",
          content: [{ type: "output_text", text: "I'm doing great!" }],
        },
      }),
    ].join("\n");

    const events = parseJsonl(lines);
    const userEvents = events.filter((e) => e.type === "user");
    const assistantEvents = events.filter((e) => e.type === "assistant");
    expect(userEvents).toHaveLength(2);
    expect(assistantEvents).toHaveLength(2);
    expect(assistantEvents[0].text).toBe("Hi there!");
    expect(assistantEvents[1].text).toBe("I'm doing great!");
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
        content: [{ type: "image", data: "iVBORw0KGgoAAAANS", mimeType: "image/png" }],
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
        content: [{ type: "audio", data: "UklGRiQAAABXQVZF", mimeType: "audio/wav" }],
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
    writeFileSync(
      join(dir, "2026-01-01_aaa.jsonl"),
      JSON.stringify({
        type: "message",
        id: "old",
        timestamp: "2026-01-01T00:00:00Z",
        message: { role: "user", content: "old message" },
      }),
    );

    // Newer file (alphabetically last = most recent)
    writeFileSync(
      join(dir, "2026-01-02_bbb.jsonl"),
      JSON.stringify({
        type: "message",
        id: "new",
        parentId: "old",
        timestamp: "2026-01-02T00:00:00Z",
        message: { role: "user", content: "new message" },
      }),
    );

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
  function entry(
    id: string,
    parentId: string | null,
    type: string,
    extra: Record<string, unknown> = {},
  ): string {
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
      entry("3", "2", "compaction", {
        summary: "User asked a question and got an answer.",
        firstKeptEntryId: "2",
      }),
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
    const lines = [msgEntry("2", "999", "user", "orphan")].join("\n");

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

  it("warns on unknown content block types instead of silently dropping", async () => {
    const stderrLines: string[] = [];
    const originalLogLevel = process.env.OPPI_LOG_LEVEL;
    process.env.OPPI_LOG_LEVEL = "warn";
    vi.resetModules();
    const { parseJsonl: parseJsonlWithWarnings } = await import("../src/trace.js");

    const writeSpy = vi.spyOn(process.stderr, "write").mockImplementation(((
      chunk: string | Uint8Array,
    ) => {
      stderrLines.push(typeof chunk === "string" ? chunk : chunk.toString("utf8"));
      return true;
    }) as typeof process.stderr.write);

    try {
      const lines = [
        JSON.stringify({
          type: "message",
          id: "1",
          timestamp: "2026-01-01T00:00:00Z",
          message: { role: "user", content: "hello" },
        }),
        JSON.stringify({
          type: "message",
          id: "2",
          parentId: "1",
          timestamp: "2026-01-01T00:00:01Z",
          message: {
            role: "assistant",
            content: [
              { type: "future_block_type", data: "some new format" },
              { type: "text", text: "I can still answer" },
            ],
          },
        }),
      ].join("\n");

      const events = parseJsonlWithWarnings(lines);
      // The known text block should still be emitted
      expect(events.some((e) => e.type === "assistant" && e.text === "I can still answer")).toBe(
        true,
      );

      const warningEvents = stderrLines
        .join("")
        .split("\n")
        .filter((line) => line.includes('"event":"trace.unknown_assistant_block_type"'));

      expect(warningEvents.length).toBeGreaterThanOrEqual(1);
      expect(warningEvents[0]).toContain("future_block_type");
    } finally {
      writeSpy.mockRestore();
      if (originalLogLevel === undefined) {
        delete process.env.OPPI_LOG_LEVEL;
      } else {
        process.env.OPPI_LOG_LEVEL = originalLogLevel;
      }
      vi.resetModules();
    }
  });

  it("structural: multi-turn conversation preserves assistant responses", () => {
    // Invariant: in a normal multi-turn conversation, every user message
    // (except possibly the last) should have a corresponding assistant response.
    // This catches silent-drop bugs regardless of content block format.
    const turns = 10;
    const lines: string[] = [];
    for (let i = 0; i < turns; i++) {
      const userId = `user-${i}`;
      const assistantId = `asst-${i}`;
      const parentId = i === 0 ? null : `asst-${i - 1}`;

      lines.push(
        JSON.stringify({
          type: "message",
          id: userId,
          parentId,
          timestamp: `2026-01-01T00:00:${String(i * 2).padStart(2, "0")}Z`,
          message: { role: "user", content: `Question ${i}` },
        }),
      );
      lines.push(
        JSON.stringify({
          type: "message",
          id: assistantId,
          parentId: userId,
          timestamp: `2026-01-01T00:00:${String(i * 2 + 1).padStart(2, "0")}Z`,
          message: {
            role: "assistant",
            // Alternate between text and output_text to cover both formats
            content: [{ type: i % 2 === 0 ? "text" : "output_text", text: `Answer ${i}` }],
          },
        }),
      );
    }

    const events = parseJsonl(lines.join("\n"));
    const userEvents = events.filter((e) => e.type === "user");
    const assistantEvents = events.filter((e) => e.type === "assistant");

    expect(userEvents).toHaveLength(turns);
    expect(assistantEvents).toHaveLength(turns);

    // Every answer should be present
    for (let i = 0; i < turns; i++) {
      expect(assistantEvents[i].text).toBe(`Answer ${i}`);
    }
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

// ─── media replay ───

describe("trace media replay", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("normalizes replayed audio details as an audio presentation", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const sessionId = "session-voice";
    const toolCallId = "tool-voice";
    const wavBase64 = Buffer.from("fixture audio").toString("base64");
    const details = materializeToolAudioDetails({
      dataDir,
      sessionId,
      toolCallId,
      details: {
        serverUrl: "http://127.0.0.1:7937",
        audio: {
          kind: "audio",
          mimeType: "audio/wav",
          fileName: "voice.wav",
          base64: wavBase64,
          durationSeconds: 1.2,
        },
        message: "hello from voice",
      },
    });

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-voice",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId,
          toolName: "voice_speak",
          content: "hello from voice",
          details,
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: sessionId },
    );

    const toolResult = trace[0] as {
      type: string;
      details?: {
        kind?: string;
        text?: string;
        audio?: { id?: string; kind?: string; mimeType?: string; durationSeconds?: number };
      };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.details).toMatchObject({
      kind: "audio_presentation",
      text: "hello from voice",
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        durationSeconds: 1.2,
      },
    });
    expect(toolResult.details?.audio?.id).toBeTruthy();
  });

  it("does not replay update-only attachments when final toolResult has no media", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-1",
      toolCallId: "tool-1",
      contents: [
        {
          type: "image",
          data: pngBase64,
          mimeType: "image/png",
          fileName: "preview.png",
        },
      ],
    });

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-1",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-1",
          toolName: "screenshot",
          content: "done",
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-1" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: unknown[] };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("done");
    expect(toolResult.details?.media).toBeUndefined();
  });

  it("replays final inline media from non-PNG session attachments with metadata", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const icoBytes = makeICO(32, 16);
    const icoBase64 = icoBytes.toString("base64");

    const blocks = materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-ico",
      toolCallId: "tool-ico",
      contents: [
        {
          type: "image",
          data: icoBase64,
          mimeType: "image/x-icon",
          fileName: "favicon.ico",
        },
      ],
    }) as Array<{ id: string }>;

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-ico",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-ico",
          toolName: "screenshot",
          content: [
            { type: "text", text: "captured" },
            { type: "image", data: icoBase64, mimeType: "image/x-icon", fileName: "favicon.ico" },
          ],
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-ico" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: Array<{ id: string; mimeType: string; storageKey: string }> };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("captured");
    expect(toolResult.details?.media).toMatchObject([
      {
        kind: "image",
        id: blocks[0]!.id,
        mimeType: "image/x-icon",
        fileName: "favicon.ico",
        storageKey: expect.stringMatching(/\.ico$/),
        sizeBytes: icoBytes.length,
        width: 32,
        height: 16,
      },
    ]);
  });

  it("replays final inline media from session attachments without leaking base64", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-trace-"));
    tempDirs.push(dataDir);
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";

    const pngBytes = Buffer.from(pngBase64, "base64");
    const blocks = materializeToolMediaContentBlocks({
      dataDir,
      sessionId: "session-2",
      toolCallId: "tool-2",
      contents: [
        {
          type: "image",
          data: pngBase64,
          mimeType: "image/png",
          fileName: "chart.png",
        },
      ],
    }) as Array<{ id: string }>;

    const trace = parseJsonl(
      `${JSON.stringify({
        type: "message",
        id: "entry-2",
        timestamp: "2026-05-13T00:00:00.000Z",
        message: {
          role: "toolResult",
          toolCallId: "tool-2",
          toolName: "screenshot",
          content: [
            { type: "text", text: "captured" },
            { type: "image", data: pngBase64, mimeType: "image/png", fileName: "chart.png" },
          ],
        },
      })}\n`,
      { attachmentDataDir: dataDir, attachmentSessionId: "session-2" },
    );

    const toolResult = trace[0] as {
      type: string;
      output?: string;
      details?: { media?: Array<{ id: string; mimeType: string }> };
    };
    expect(toolResult.type).toBe("toolResult");
    expect(toolResult.output).toBe("captured");
    expect(toolResult.details?.media).toMatchObject([
      {
        kind: "image",
        id: blocks[0]!.id,
        mimeType: "image/png",
        fileName: "chart.png",
        sizeBytes: pngBytes.length,
        width: 2,
        height: 3,
      },
    ]);

    const attachment = await getSessionAttachment(dataDir, "session-2", blocks[0]!.id);
    expect(attachment ? await readFile(attachment.path) : null).toEqual(pngBytes);
  });
});

function makeICO(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(22);
  bytes.writeUInt16LE(0, 0);
  bytes.writeUInt16LE(1, 2);
  bytes.writeUInt16LE(1, 4);
  bytes[6] = width === 256 ? 0 : width;
  bytes[7] = height === 256 ? 0 : height;
  bytes[8] = 0;
  bytes[9] = 0;
  bytes.writeUInt16LE(1, 10);
  bytes.writeUInt16LE(32, 12);
  bytes.writeUInt32LE(0, 14);
  bytes.writeUInt32LE(22, 18);
  return bytes;
}
