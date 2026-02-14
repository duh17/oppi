import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseJsonl, readSessionTrace } from "../src/trace.js";

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
    const result = readSessionTrace(tmp, "user1", "sess1");
    expect(result).toBeNull();
  });

  it("returns null when sessions dir does not exist", () => {
    const result = readSessionTrace(tmp, "user1", "sess1", "ws1");
    expect(result).toBeNull();
  });

  it("returns null when no JSONL files exist", () => {
    const dir = join(tmp, "user1", "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
    mkdirSync(dir, { recursive: true });

    const result = readSessionTrace(tmp, "user1", "sess1", "ws1");
    expect(result).toBeNull();
  });

  it("merges all JSONL files in chronological order", () => {
    const dir = join(tmp, "user1", "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
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

    const events = readSessionTrace(tmp, "user1", "sess1", "ws1");
    expect(events).not.toBeNull();
    expect(events).toHaveLength(2);
    expect(events![0].text).toBe("old message");
    expect(events![1].text).toBe("new message");
  });

  it("parses a full conversation from JSONL file", () => {
    const dir = join(tmp, "user1", "ws1", "sessions", "sess1", "agent", "sessions", "--work--");
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

    const events = readSessionTrace(tmp, "user1", "sess1", "ws1");
    expect(events).toHaveLength(3);
    expect(events![0].type).toBe("user");
    expect(events![1].type).toBe("toolCall");
    expect(events![2].type).toBe("toolResult");
  });
});
