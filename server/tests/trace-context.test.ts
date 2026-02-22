import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { buildSessionContext, parseJsonl, findToolOutput } from "../src/trace.js";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ─── Helpers ───

function entry(
  type: string,
  id: string,
  parentId: string | null,
  extra: Record<string, unknown> = {},
) {
  return { type, id, parentId, timestamp: "2025-01-01T00:00:00Z", ...extra };
}

function msg(
  id: string,
  parentId: string | null,
  role: string,
  content: unknown,
  extra: Record<string, unknown> = {},
) {
  return entry("message", id, parentId, { message: { role, content, ...extra } });
}

function toJsonl(entries: Record<string, unknown>[]): string {
  return entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
}

// ─── buildSessionContext ───

describe("buildSessionContext", () => {
  it("builds linear chain of user + assistant messages", () => {
    const entries = [
      msg("1", null, "user", "hello"),
      msg("2", "1", "assistant", "hi there"),
      msg("3", "2", "user", "thanks"),
    ];

    const events = buildSessionContext(entries);
    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("user");
    expect(events[0].text).toBe("hello");
    expect(events[1].type).toBe("assistant");
    expect(events[1].text).toBe("hi there");
    expect(events[2].type).toBe("user");
    expect(events[2].text).toBe("thanks");
  });

  it("handles assistant content blocks (text + thinking + toolCall)", () => {
    const entries = [
      msg("1", null, "user", "help"),
      msg("2", "1", "assistant", [
        { type: "thinking", thinking: "let me think..." },
        { type: "text", text: "here is the answer" },
        { type: "toolCall", id: "tc1", name: "bash", arguments: { command: "ls" } },
      ]),
    ];

    const events = buildSessionContext(entries);
    expect(events).toHaveLength(4); // user + thinking + text + toolCall
    expect(events[0].type).toBe("user");
    expect(events[1].type).toBe("thinking");
    expect(events[1].thinking).toBe("let me think...");
    expect(events[2].type).toBe("assistant");
    expect(events[2].text).toBe("here is the answer");
    expect(events[3].type).toBe("toolCall");
    expect(events[3].tool).toBe("bash");
    expect(events[3].args).toEqual({ command: "ls" });
  });

  it("handles toolResult messages", () => {
    const entries = [
      msg("1", null, "user", "list files"),
      msg("2", "1", "assistant", [
        { type: "toolCall", id: "tc1", name: "bash", arguments: { command: "ls" } },
      ]),
      msg("3", "2", "toolResult", "file1.txt\nfile2.txt", {
        toolCallId: "tc1",
        toolName: "bash",
      }),
    ];

    const events = buildSessionContext(entries);
    const result = events.find((e) => e.type === "toolResult");
    expect(result).toBeDefined();
    expect(result!.output).toBe("file1.txt\nfile2.txt");
    expect(result!.toolCallId).toBe("tc1");
    expect(result!.toolName).toBe("bash");
  });

  it("handles compaction — hides pre-compaction messages", () => {
    const entries = [
      msg("1", null, "user", "old message 1"),
      msg("2", "1", "assistant", "old response 1"),
      msg("3", "2", "user", "old message 2"),
      msg("4", "3", "assistant", "old response 2"),
      // Compaction: keep from entry 3 onward
      entry("compaction", "5", "4", {
        summary: "Prior conversation about setup",
        firstKeptEntryId: "3",
        tokensBefore: 5000,
      }),
      msg("6", "5", "user", "new message after compaction"),
      msg("7", "6", "assistant", "new response"),
    ];

    const events = buildSessionContext(entries);

    // Should have: compaction summary + kept entries (3,4) + post-compaction (6,7)
    const types = events.map((e) => e.type);
    expect(types[0]).toBe("compaction");
    expect(events[0].text).toContain("5,000 tokens");
    expect(events[0].text).toContain("Prior conversation about setup");

    // Old messages 1 and 2 should be hidden
    const texts = events.filter((e) => e.type === "user" || e.type === "assistant").map((e) => e.text);
    expect(texts).not.toContain("old message 1");
    expect(texts).not.toContain("old response 1");

    // Kept + post-compaction messages should be present
    expect(texts).toContain("old message 2");
    expect(texts).toContain("new message after compaction");
    expect(texts).toContain("new response");
  });

  it("returns empty for empty entries", () => {
    expect(buildSessionContext([])).toEqual([]);
  });

  it("returns empty when no entries have ids", () => {
    const entries = [{ type: "session", id: "", parentId: null }];
    expect(buildSessionContext(entries as any)).toEqual([]);
  });

  it("handles model_change entries", () => {
    const entries = [
      msg("1", null, "user", "hi"),
      entry("model_change", "2", "1", { modelId: "claude-4-sonnet" }),
      msg("3", "2", "assistant", "hello"),
    ];

    const events = buildSessionContext(entries);
    const modelChange = events.find((e) => e.type === "system" && e.text?.includes("Model:"));
    expect(modelChange).toBeDefined();
    expect(modelChange!.text).toContain("claude-4-sonnet");
  });

  it("handles thinking_level_change entries", () => {
    const entries = [
      msg("1", null, "user", "hi"),
      entry("thinking_level_change", "2", "1", { thinkingLevel: "high" }),
      msg("3", "2", "assistant", "hello"),
    ];

    const events = buildSessionContext(entries);
    const change = events.find((e) => e.type === "system" && e.text?.includes("Thinking level:"));
    expect(change).toBeDefined();
    expect(change!.text).toContain("high");
  });

  it("handles branch_summary entries", () => {
    const entries = [
      entry("branch_summary", "1", null, { summary: "Earlier debugging session" }),
      msg("2", "1", "user", "continue"),
    ];

    const events = buildSessionContext(entries);
    const branch = events.find((e) => e.type === "system" && e.text?.includes("Branch"));
    expect(branch).toBeDefined();
    expect(branch!.text).toContain("Earlier debugging session");
  });

  it("handles custom_message entries", () => {
    const entries = [
      msg("1", null, "user", "hi"),
      entry("custom_message", "2", "1", {
        content: "Extension notification: build complete",
        display: true,
      }),
    ];

    const events = buildSessionContext(entries);
    const custom = events.find((e) => e.text?.includes("Extension notification"));
    expect(custom).toBeDefined();
  });

  it("skips custom_message with display:false", () => {
    const entries = [
      msg("1", null, "user", "hi"),
      entry("custom_message", "2", "1", {
        content: "hidden message",
        display: false,
      }),
    ];

    const events = buildSessionContext(entries);
    expect(events.find((e) => e.text?.includes("hidden"))).toBeUndefined();
  });

  it("handles toolResult with isError flag", () => {
    const entries = [
      msg("1", null, "user", "run broken"),
      msg("2", "1", "assistant", [
        { type: "toolCall", id: "tc1", name: "bash", arguments: { command: "exit 1" } },
      ]),
      msg("3", "2", "toolResult", "command failed", {
        toolCallId: "tc1",
        toolName: "bash",
        isError: true,
      }),
    ];

    const events = buildSessionContext(entries);
    const result = events.find((e) => e.type === "toolResult");
    expect(result!.isError).toBe(true);
  });

  it("full view includes pre-compaction messages", () => {
    const entries = [
      msg("1", null, "user", "old message"),
      entry("compaction", "2", "1", { summary: "compacted", firstKeptEntryId: "1" }),
      msg("3", "2", "user", "new message"),
    ];

    const events = buildSessionContext(entries, { view: "full" });
    const userTexts = events.filter((e) => e.type === "user").map((e) => e.text);
    expect(userTexts).toContain("old message");
    expect(userTexts).toContain("new message");
  });

  it("handles media content blocks in assistant messages", () => {
    const entries = [
      msg("1", null, "user", "show me a chart"),
      msg("2", "1", "assistant", [
        { type: "text", text: "Here is the chart:" },
        { type: "image", data: "aGVsbG8=", mimeType: "image/png" },
      ]),
    ];

    // Image blocks don't show in assistant events (they're in separate blocks)
    const events = buildSessionContext(entries);
    expect(events.length).toBeGreaterThanOrEqual(2);
  });

  it("handles toolCall with partialJson instead of arguments", () => {
    const entries = [
      msg("1", null, "user", "do stuff"),
      msg("2", "1", "assistant", [
        {
          type: "toolCall",
          id: "tc1",
          name: "bash",
          partialJson: '{"command":"echo hello"}',
        },
      ]),
    ];

    const events = buildSessionContext(entries);
    const tc = events.find((e) => e.type === "toolCall");
    expect(tc).toBeDefined();
    expect(tc!.args).toEqual({ command: "echo hello" });
  });
});

// ─── parseJsonl ───

describe("parseJsonl", () => {
  it("parses JSONL string into events", () => {
    const jsonl = toJsonl([
      msg("1", null, "user", "hello"),
      msg("2", "1", "assistant", "world"),
    ]);

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(2);
    expect(events[0].text).toBe("hello");
    expect(events[1].text).toBe("world");
  });

  it("skips malformed lines", () => {
    const jsonl =
      JSON.stringify(msg("1", null, "user", "valid")) + "\n{bad json}\n" + JSON.stringify(msg("2", "1", "assistant", "also valid")) + "\n";

    const events = parseJsonl(jsonl);
    expect(events).toHaveLength(2);
  });

  it("handles empty input", () => {
    expect(parseJsonl("")).toEqual([]);
    expect(parseJsonl("\n\n")).toEqual([]);
  });
});

// ─── findToolOutput ───

describe("findToolOutput", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = join(tmpdir(), `trace-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("finds tool output by toolCallId", () => {
    const jsonl = toJsonl([
      msg("1", null, "user", "list files"),
      msg("2", "1", "assistant", [
        { type: "toolCall", id: "tc1", name: "bash", arguments: { command: "ls" } },
      ]),
      msg("3", "2", "toolResult", "file1.txt\nfile2.txt", {
        toolCallId: "tc1",
        toolName: "bash",
      }),
    ]);

    const path = join(tmpDir, "session.jsonl");
    writeFileSync(path, jsonl);

    const result = findToolOutput(path, "tc1");
    expect(result).not.toBeNull();
    expect(result!.text).toBe("file1.txt\nfile2.txt");
    expect(result!.isError).toBe(false);
  });

  it("returns null for nonexistent toolCallId", () => {
    const jsonl = toJsonl([
      msg("1", null, "user", "hi"),
      msg("2", "1", "assistant", "hello"),
    ]);

    const path = join(tmpDir, "session.jsonl");
    writeFileSync(path, jsonl);

    expect(findToolOutput(path, "nonexistent")).toBeNull();
  });

  it("returns null for nonexistent file", () => {
    expect(findToolOutput(join(tmpDir, "nope.jsonl"), "tc1")).toBeNull();
  });

  it("detects error results", () => {
    const jsonl = toJsonl([
      msg("1", null, "user", "break it"),
      msg("2", "1", "assistant", [
        { type: "toolCall", id: "tc1", name: "bash", arguments: { command: "exit 1" } },
      ]),
      msg("3", "2", "toolResult", "exit code 1", {
        toolCallId: "tc1",
        toolName: "bash",
        isError: true,
      }),
    ]);

    const path = join(tmpDir, "session.jsonl");
    writeFileSync(path, jsonl);

    const result = findToolOutput(path, "tc1");
    expect(result!.isError).toBe(true);
  });
});
