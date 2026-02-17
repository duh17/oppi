/**
 * Session context building from JSONL — compaction, tool matching.
 *
 * Uses synthetic JSONL only (no dependency on real session files).
 * Migrated from test-session-context.ts.
 */

import { describe, it, expect } from "vitest";
import { parseJsonl } from "../src/trace.js";

describe("parseJsonl: compaction", () => {
  const syntheticJsonl = [
    '{"type":"session","version":3,"id":"test-session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}',
    '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":"old question"}}',
    '{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}]}}',
    '{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-01-01T00:03:00Z","message":{"role":"user","content":"another old question"}}',
    '{"type":"message","id":"m4","parentId":"m3","timestamp":"2026-01-01T00:04:00Z","message":{"role":"assistant","content":[{"type":"text","text":"another old answer"}]}}',
    '{"type":"compaction","id":"c1","parentId":"m4","timestamp":"2026-01-01T00:05:00Z","summary":"User asked two questions about testing","firstKeptEntryId":"m3","tokensBefore":50000}',
    '{"type":"message","id":"m5","parentId":"c1","timestamp":"2026-01-01T00:06:00Z","message":{"role":"user","content":"new question"}}',
    '{"type":"message","id":"m6","parentId":"m5","timestamp":"2026-01-01T00:07:00Z","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}]}}',
  ].join("\n");

  const events = parseJsonl(syntheticJsonl);

  it("produces exactly 5 events (compaction + kept + post-compaction)", () => {
    expect(events).toHaveLength(5);
  });

  it("first event is compaction summary", () => {
    expect(events[0].type).toBe("compaction");
  });

  it("compaction text shows token count", () => {
    expect(events[0].text).toContain("50,000 tokens");
  });

  it("kept user message is present", () => {
    expect(events[1].type).toBe("user");
    expect(events[1].text).toBe("another old question");
  });

  it("kept assistant message is present", () => {
    expect(events[2].type).toBe("assistant");
    expect(events[2].text).toBe("another old answer");
  });

  it("post-compaction user message is present", () => {
    expect(events[3].type).toBe("user");
    expect(events[3].text).toBe("new question");
  });

  it("post-compaction assistant message is present", () => {
    expect(events[4].type).toBe("assistant");
    expect(events[4].text).toBe("new answer");
  });

  it("hidden messages (m1, m2) do not appear", () => {
    const allTexts = events.map((e) => e.text || "");
    expect(allTexts.some((t) => t === "old question")).toBe(false);
    expect(allTexts.some((t) => t === "old answer")).toBe(false);
  });
});

describe("parseJsonl: full view preserves pre-compaction timeline", () => {
  const syntheticJsonl = [
    '{"type":"session","version":3,"id":"test-session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}',
    '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":"old question"}}',
    '{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}]}}',
    '{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-01-01T00:03:00Z","message":{"role":"user","content":"another old question"}}',
    '{"type":"message","id":"m4","parentId":"m3","timestamp":"2026-01-01T00:04:00Z","message":{"role":"assistant","content":[{"type":"text","text":"another old answer"}]}}',
    '{"type":"compaction","id":"c1","parentId":"m4","timestamp":"2026-01-01T00:05:00Z","summary":"User asked two questions about testing","firstKeptEntryId":"m3","tokensBefore":50000}',
    '{"type":"message","id":"m5","parentId":"c1","timestamp":"2026-01-01T00:06:00Z","message":{"role":"user","content":"new question"}}',
    '{"type":"message","id":"m6","parentId":"m5","timestamp":"2026-01-01T00:07:00Z","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}]}}',
  ].join("\n");

  const events = parseJsonl(syntheticJsonl, { view: "full" });

  it("keeps pre-compaction messages", () => {
    const allTexts = events.map((e) => e.text || "");
    expect(allTexts).toContain("old question");
    expect(allTexts).toContain("old answer");
  });

  it("keeps compaction marker in chronological position", () => {
    expect(events).toHaveLength(7);
    expect(events[0].id).toBe("m1");
    expect(events[1].id).toBe("m2-text-0");
    expect(events[2].id).toBe("m3");
    expect(events[3].id).toBe("m4-text-0");
    expect(events[4].type).toBe("compaction");
    expect(events[5].id).toBe("m5");
    expect(events[6].id).toBe("m6-text-0");
  });

  it("compaction marker includes summary text", () => {
    expect(events[4].text).toContain("User asked two questions about testing");
  });
});

describe("parseJsonl: tool call matching", () => {
  const toolJsonl = [
    '{"type":"session","version":3,"id":"test-tools","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}',
    '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":"list files"}}',
    '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"I should use bash to list files"},{"type":"text","text":"Let me check."},{"type":"toolCall","id":"tc1","name":"bash","arguments":{"command":"ls -la"}}]}}',
    '{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-01-01T00:03:00Z","message":{"role":"toolResult","content":[{"type":"text","text":"file1.txt\\nfile2.txt"}],"toolCallId":"tc1","toolName":"bash","isError":false}}',
    '{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-01-01T00:04:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Found 2 files."}]}}',
  ].join("\n");

  const events = parseJsonl(toolJsonl);

  it("produces 6 events: thinking, assistant, toolCall, toolResult, assistant", () => {
    expect(events).toHaveLength(6);
  });

  it("has correct event types in order", () => {
    expect(events[0].type).toBe("user");
    expect(events[1].type).toBe("thinking");
    expect(events[2].type).toBe("assistant");
    expect(events[3].type).toBe("toolCall");
    expect(events[4].type).toBe("toolResult");
    expect(events[5].type).toBe("assistant");
  });

  it("tool call is bash", () => {
    expect(events[3].tool).toBe("bash");
  });

  it("tool result links to tc1", () => {
    expect(events[4].toolCallId).toBe("tc1");
  });
});
