import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";
import type { ServerMessage, Session } from "./types.js";
import {
  translatePiEvent,
  computeAssistantTextTailDelta,
  normalizeCommandError,
  extractToolFullOutputPath,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";

// ─── Factories ───

function makeCtx(overrides?: Partial<TranslationContext>): TranslationContext {
  return {
    sessionId: "test-session",
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    ...overrides,
  };
}

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "sess-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...overrides,
  };
}

// ─── computeAssistantTextTailDelta ───

describe("computeAssistantTextTailDelta", () => {
  it("returns empty when finalized is empty", () => {
    expect(computeAssistantTextTailDelta("anything", "")).toBe("");
  });

  it("returns full finalized when streamed is empty", () => {
    expect(computeAssistantTextTailDelta("", "hello world")).toBe("hello world");
  });

  it("returns empty when both are equal", () => {
    expect(computeAssistantTextTailDelta("hello", "hello")).toBe("");
  });

  it("returns tail when finalized extends streamed", () => {
    expect(computeAssistantTextTailDelta("hello", "hello world")).toBe(" world");
  });

  it("returns from common prefix when finalized diverges", () => {
    // Streamed "abc", finalized "abd" — common prefix "ab", returns "d"
    expect(computeAssistantTextTailDelta("abc", "abd")).toBe("d");
  });

  it("handles complete divergence (no common prefix)", () => {
    expect(computeAssistantTextTailDelta("abc", "xyz")).toBe("xyz");
  });

  it("handles finalized shorter than streamed", () => {
    // Streamed "hello world" but finalized is "hello" — streamed is longer
    // finalized doesn't startWith streamed (reverse), falls into divergence path
    // common prefix = "hello", returns "" (slice from 5 on "hello" is "")
    expect(computeAssistantTextTailDelta("hello world", "hello")).toBe("");
  });

  it("handles both empty", () => {
    expect(computeAssistantTextTailDelta("", "")).toBe("");
  });

  // Unicode edge cases
  it("handles unicode characters correctly (extension)", () => {
    expect(computeAssistantTextTailDelta("hello 🌍", "hello 🌍🎉")).toBe("🎉");
  });

  // BUG FOUND: computeAssistantTextTailDelta breaks on emoji divergence.
  //
  // "hello 🌍" vs "hello 🎉" should return "🎉" but returns "\uDF89" (lone low surrogate).
  //
  // Root cause: The divergence fallback compares by JS string index (UTF-16 code units).
  // Both emoji start with the same high surrogate (\uD83C), so commonPrefix advances
  // past it to index 7. finalizedText.slice(7) yields the lone low surrogate "\uDF89"
  // instead of the complete emoji "🎉" (\uD83C\uDF89).
  //
  // Impact: When assistant text diverges at an emoji boundary where both emoji share
  // a high surrogate, the client receives a malformed string fragment. This could cause
  // display corruption or encoding errors in downstream consumers.
  //
  // Fix: Use Array.from() or a code-point-aware iteration for the common prefix scan,
  // or after computing commonPrefix, back up if it lands inside a surrogate pair.
  it("handles unicode divergence at emoji boundary — KNOWN BUG: returns lone surrogate", () => {
    const result = computeAssistantTextTailDelta("hello 🌍", "hello 🎉");
    // Expected correct behavior: "🎉"
    // Actual buggy behavior: lone low surrogate from mid-surrogate slice
    expect(result).toBe("\uDF89"); // BUG: should be "🎉"
    expect(result).not.toBe("🎉"); // confirms the bug
  });

  // BUG PROBE: The divergence fallback compares by JS string index, which
  // works for code points but could produce a partial surrogate pair in theory.
  // In practice, emoji are single code points in JS strings (even if multiple
  // UTF-16 code units), so charAt comparison across surrogates could mismatch
  // at the code unit level rather than the code point level.
  it("handles surrogate pair characters (e.g. 𝕳)", () => {
    // 𝕳 is U+1D573, represented as surrogate pair in UTF-16
    const streamed = "test 𝕳";
    const finalized = "test 𝕳 done";
    expect(computeAssistantTextTailDelta(streamed, finalized)).toBe(" done");
  });

  // BUG FOUND: Same class of bug as the emoji divergence above.
  // Mathematical symbols 𝕳 (U+1D573) and 𝕴 (U+1D574) share high surrogate \uD835.
  // The common prefix scan matches "a" + \uD835 → commonPrefix=2.
  // finalizedText.slice(2) = "\uDD74" — a lone low surrogate, not a valid character.
  it("handles divergence mid-surrogate — KNOWN BUG: produces lone low surrogate", () => {
    const streamed = "a\uD835\uDD73"; // a𝕳
    const finalized = "a\uD835\uDD74"; // a𝕴
    const delta = computeAssistantTextTailDelta(streamed, finalized);
    expect(delta).toBe("\uDD74"); // BUG: should be "𝕴" (\uD835\uDD74)
    expect(delta).not.toBe("𝕴"); // confirms the bug
  });
});

// ─── normalizeCommandError ───

describe("normalizeCommandError", () => {
  it('normalizes "already compacted" for compact command', () => {
    expect(normalizeCommandError("compact", "already compacted")).toBe("Already compacted");
  });

  it("is case-insensitive for already compacted", () => {
    expect(normalizeCommandError("compact", "Already Compacted")).toBe("Already compacted");
  });

  it("trims whitespace", () => {
    expect(normalizeCommandError("compact", "  already compacted  ")).toBe("Already compacted");
  });

  it("passes through other errors for compact", () => {
    expect(normalizeCommandError("compact", "something else")).toBe("something else");
  });

  it("does not normalize for other commands", () => {
    expect(normalizeCommandError("fork", "already compacted")).toBe("already compacted");
  });

  it("handles empty error string", () => {
    expect(normalizeCommandError("compact", "")).toBe("");
  });

  it("handles whitespace-only error string", () => {
    expect(normalizeCommandError("compact", "   ")).toBe("");
  });
});

// ─── extractToolFullOutputPath ───

describe("extractToolFullOutputPath", () => {
  it("extracts path from details object", () => {
    expect(extractToolFullOutputPath({ fullOutputPath: "/tmp/out.txt" })).toBe("/tmp/out.txt");
  });

  it("trims whitespace from path", () => {
    expect(extractToolFullOutputPath({ fullOutputPath: "  /tmp/out.txt  " })).toBe("/tmp/out.txt");
  });

  it("returns null for missing fullOutputPath", () => {
    expect(extractToolFullOutputPath({ other: "field" })).toBeNull();
  });

  it("returns null for empty string path", () => {
    expect(extractToolFullOutputPath({ fullOutputPath: "" })).toBeNull();
  });

  it("returns null for whitespace-only path", () => {
    expect(extractToolFullOutputPath({ fullOutputPath: "   " })).toBeNull();
  });

  it("returns null for non-string path", () => {
    expect(extractToolFullOutputPath({ fullOutputPath: 42 })).toBeNull();
  });

  it("returns null for null input", () => {
    expect(extractToolFullOutputPath(null)).toBeNull();
  });

  it("returns null for undefined input", () => {
    expect(extractToolFullOutputPath(undefined)).toBeNull();
  });

  it("returns null for primitive input", () => {
    expect(extractToolFullOutputPath("string")).toBeNull();
    expect(extractToolFullOutputPath(42)).toBeNull();
  });
});

// ─── updateSessionChangeStats ───

describe("updateSessionChangeStats", () => {
  it("ignores non-edit/write tools", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "bash", { command: "ls" });
    expect(session.changeStats).toBeUndefined();
  });

  it("ignores non-edit/write tools (read)", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "read", { path: "/foo" });
    expect(session.changeStats).toBeUndefined();
  });

  it("tracks write tool calls", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "/tmp/a.ts", content: "line1\nline2" });
    expect(session.changeStats).toBeDefined();
    expect(session.changeStats!.mutatingToolCalls).toBe(1);
    expect(session.changeStats!.filesChanged).toBe(1);
    expect(session.changeStats!.changedFiles).toEqual(["/tmp/a.ts"]);
    expect(session.changeStats!.addedLines).toBe(2);
  });

  it("tracks edit tool calls", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "edit", {
      path: "/tmp/a.ts",
      oldText: "line1",
      newText: "line1\nline2\nline3",
    });
    expect(session.changeStats!.mutatingToolCalls).toBe(1);
    expect(session.changeStats!.addedLines).toBe(2);
    expect(session.changeStats!.removedLines).toBe(0);
  });

  it("deduplicates file paths across multiple calls", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "/tmp/a.ts", content: "x" });
    updateSessionChangeStats(session, "write", { path: "/tmp/a.ts", content: "y" });
    expect(session.changeStats!.mutatingToolCalls).toBe(2);
    expect(session.changeStats!.filesChanged).toBe(1);
    expect(session.changeStats!.changedFiles).toEqual(["/tmp/a.ts"]);
  });

  it("is case-insensitive for tool name", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "Write", { path: "/a.ts", content: "x" });
    updateSessionChangeStats(session, "EDIT", {
      path: "/b.ts",
      oldText: "a",
      newText: "b",
    });
    expect(session.changeStats!.mutatingToolCalls).toBe(2);
  });

  it("tracks overflow when exceeding MAX_TRACKED_CHANGED_FILES", () => {
    const session = makeSession();
    // Push 100 unique files (the max)
    for (let i = 0; i < 100; i++) {
      updateSessionChangeStats(session, "write", { path: `/tmp/f${i}.ts`, content: "x" });
    }
    expect(session.changeStats!.changedFiles).toHaveLength(100);
    expect(session.changeStats!.changedFilesOverflow).toBeUndefined();

    // 101st unique file triggers overflow
    updateSessionChangeStats(session, "write", { path: "/tmp/overflow.ts", content: "x" });
    expect(session.changeStats!.changedFiles).toHaveLength(100); // capped
    expect(session.changeStats!.filesChanged).toBe(101);
    expect(session.changeStats!.changedFilesOverflow).toBe(1);
  });

  it("handles null/undefined args gracefully", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", null);
    expect(session.changeStats!.mutatingToolCalls).toBe(1);
    expect(session.changeStats!.filesChanged).toBe(0);
  });

  it("handles args without path", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { content: "hello" });
    expect(session.changeStats!.mutatingToolCalls).toBe(1);
    expect(session.changeStats!.filesChanged).toBe(0);
  });

  it("handles non-string tool name", () => {
    const session = makeSession();
    updateSessionChangeStats(session, 42, { path: "/a.ts" });
    expect(session.changeStats).toBeUndefined();
  });

  it("trims file paths", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "  /tmp/a.ts  ", content: "x" });
    expect(session.changeStats!.changedFiles).toEqual(["/tmp/a.ts"]);
  });

  it("ignores empty file paths", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "", content: "x" });
    expect(session.changeStats!.filesChanged).toBe(0);
  });

  it("accepts file_path as alternative to path", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { file_path: "/tmp/a.ts", content: "x" });
    expect(session.changeStats!.changedFiles).toEqual(["/tmp/a.ts"]);
  });

  it("accumulates line deltas correctly for edits", () => {
    const session = makeSession();
    // Replace 3 lines with 1 line
    updateSessionChangeStats(session, "edit", {
      path: "/a.ts",
      oldText: "a\nb\nc",
      newText: "x",
    });
    expect(session.changeStats!.addedLines).toBe(0);
    expect(session.changeStats!.removedLines).toBe(2);
  });

  it("write with empty content counts 0 added lines", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "/a.ts", content: "" });
    expect(session.changeStats!.addedLines).toBe(0);
  });
});

// ─── translatePiEvent ───

describe("translatePiEvent", () => {
  describe("agent_start / agent_end", () => {
    it("emits agent_start and resets streamedAssistantText", () => {
      const ctx = makeCtx({ streamedAssistantText: "leftover" });
      const result = translatePiEvent({ type: "agent_start" } as AgentSessionEvent, ctx);
      expect(result).toEqual([{ type: "agent_start" }]);
      expect(ctx.streamedAssistantText).toBe("");
    });

    it("emits agent_end and resets streamedAssistantText", () => {
      const ctx = makeCtx({ streamedAssistantText: "leftover" });
      const result = translatePiEvent(
        { type: "agent_end", messages: [] } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([{ type: "agent_end" }]);
      expect(ctx.streamedAssistantText).toBe("");
    });
  });

  describe("turn_start / turn_end / message_start", () => {
    it("turn_start returns empty", () => {
      expect(translatePiEvent({ type: "turn_start" } as AgentSessionEvent, makeCtx())).toEqual([]);
    });

    it("turn_end returns empty", () => {
      const event = {
        type: "turn_end",
        message: {},
        toolResults: [],
      } as unknown as AgentSessionEvent;
      expect(translatePiEvent(event, makeCtx())).toEqual([]);
    });

    it("message_start returns empty", () => {
      const event = { type: "message_start", message: {} } as AgentSessionEvent;
      expect(translatePiEvent(event, makeCtx())).toEqual([]);
    });
  });

  describe("message_update: text_delta", () => {
    it("accumulates text and emits text_delta", () => {
      const ctx = makeCtx();
      const event = {
        type: "message_update",
        message: {},
        assistantMessageEvent: { type: "text_delta", delta: "hello", contentIndex: 0 },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toEqual([{ type: "text_delta", delta: "hello" }]);
      expect(ctx.streamedAssistantText).toBe("hello");
    });

    it("accumulates across multiple deltas", () => {
      const ctx = makeCtx();
      translatePiEvent(
        {
          type: "message_update",
          message: {},
          assistantMessageEvent: { type: "text_delta", delta: "hello ", contentIndex: 0 },
        } as AgentSessionEvent,
        ctx,
      );
      translatePiEvent(
        {
          type: "message_update",
          message: {},
          assistantMessageEvent: { type: "text_delta", delta: "world", contentIndex: 0 },
        } as AgentSessionEvent,
        ctx,
      );
      expect(ctx.streamedAssistantText).toBe("hello world");
    });
  });

  describe("message_update: thinking_delta", () => {
    it("sets hasStreamedThinking and emits thinking_delta", () => {
      const ctx = makeCtx();
      const event = {
        type: "message_update",
        message: {},
        assistantMessageEvent: { type: "thinking_delta", delta: "hmm", contentIndex: 0 },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toEqual([{ type: "thinking_delta", delta: "hmm" }]);
      expect(ctx.hasStreamedThinking).toBe(true);
    });
  });

  describe("message_update: error", () => {
    it("extracts error message from assistantMessageEvent", () => {
      const event = {
        type: "message_update",
        message: {},
        assistantMessageEvent: {
          type: "error",
          reason: "error",
          error: { errorMessage: "rate limit exceeded" },
        },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toEqual([{ type: "error", error: "rate limit exceeded" }]);
    });

    it("falls back to stream reason when errorMessage is empty", () => {
      const event = {
        type: "message_update",
        message: {},
        assistantMessageEvent: {
          type: "error",
          reason: "aborted",
          error: { errorMessage: "" },
        },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toEqual([{ type: "error", error: "Stream aborted" }]);
    });

    it("falls back to stream reason when errorMessage is missing", () => {
      const event = {
        type: "message_update",
        message: {},
        assistantMessageEvent: {
          type: "error",
          reason: "error",
          error: {},
        },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toEqual([{ type: "error", error: "Stream error" }]);
    });
  });

  describe("message_update: toolcall streaming", () => {
    it("extracts tool_start from toolcall_delta with content array", () => {
      const event = {
        type: "message_update",
        message: {
          content: [{ type: "toolCall", id: "tc-1", name: "write", arguments: { path: "/a.ts" } }],
        },
        assistantMessageEvent: {
          type: "toolcall_delta",
          contentIndex: 0,
          delta: '{"path":',
        },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe("tool_start");
      const msg = result[0] as Extract<ServerMessage, { type: "tool_start" }>;
      expect(msg.tool).toBe("write");
      expect(msg.toolCallId).toBe("tc-1");
      expect(msg.args).toEqual({ path: "/a.ts" });
    });

    it("falls back to last toolCall in content when contentIndex is missing", () => {
      const event = {
        type: "message_update",
        message: {
          content: [
            { type: "text", text: "hello" },
            { type: "toolCall", id: "tc-2", name: "edit", arguments: { path: "/b.ts" } },
          ],
        },
        assistantMessageEvent: {
          type: "toolcall_delta",
          // no contentIndex
          delta: "stuff",
        },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toHaveLength(1);
      expect((result[0] as Extract<ServerMessage, { type: "tool_start" }>).tool).toBe("edit");
    });

    it("returns empty when no toolCall found in content", () => {
      const event = {
        type: "message_update",
        message: { content: [{ type: "text", text: "no tools here" }] },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 5, delta: "x" },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toEqual([]);
    });

    it("returns empty for toolCall with empty id or name", () => {
      const event = {
        type: "message_update",
        message: {
          content: [{ type: "toolCall", id: "", name: "write", arguments: {} }],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "x" },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toEqual([]);
    });

    it("handles toolcall_end with explicit toolCall on the event", () => {
      const event = {
        type: "message_update",
        message: { content: [] },
        assistantMessageEvent: {
          type: "toolcall_end",
          contentIndex: 0,
          toolCall: { type: "toolCall", id: "tc-3", name: "read", arguments: { path: "/c.ts" } },
        },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, makeCtx());
      expect(result).toHaveLength(1);
      expect((result[0] as Extract<ServerMessage, { type: "tool_start" }>).tool).toBe("read");
    });
  });

  describe("tool_execution_start", () => {
    it("emits tool_start with args", () => {
      const ctx = makeCtx();
      const event = {
        type: "tool_execution_start",
        toolCallId: "tc-1",
        toolName: "bash",
        args: { command: "ls" },
      } as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toHaveLength(1);
      expect(result[0]).toMatchObject({
        type: "tool_start",
        tool: "bash",
        args: { command: "ls" },
        toolCallId: "tc-1",
      });
    });

    it("tracks tool name in context for shell preview", () => {
      const ctx = makeCtx();
      translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
        } as AgentSessionEvent,
        ctx,
      );
      expect(ctx.toolNames.get("tc-1")).toBe("bash");
    });

    it("handles missing args (null/undefined)", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "read",
          args: undefined,
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(result[0]).toMatchObject({
        type: "tool_start",
        tool: "read",
        args: {},
      });
    });
  });

  describe("tool_execution_update: normal delta", () => {
    it("converts replace semantics to append delta", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "read");

      // First update: full text "hello"
      const result1 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "hello" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result1).toHaveLength(1);
      expect((result1[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe("hello");

      // Second update: accumulated "hello world"
      const result2 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "hello world" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result2).toHaveLength(1);
      expect((result2[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(" world");
    });

    it("emits nothing when text hasn't changed", () => {
      const ctx = makeCtx();
      ctx.partialResults.set("tc-1", "hello");
      ctx.toolNames.set("tc-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "hello" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
    });

    it("handles empty partialResult content", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
    });

    it("handles null partialResult", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: null,
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
    });

    // BUG PROBE: What happens when partialResult text diverges from accumulated?
    // The computeToolDelta inside translatePiEvent uses a different divergence
    // strategy than computeAssistantTextTailDelta — it emits the full text
    // rather than computing from common prefix. This means the client would
    // get duplicated output on divergence.
    it("emits full text on divergence (replace semantics reset)", () => {
      const ctx = makeCtx();
      ctx.partialResults.set("tc-1", "hello world");
      ctx.toolNames.set("tc-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "completely different" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toHaveLength(1);
      // This emits the FULL "completely different" even though client already
      // has "hello world" appended. Client will show "hello worldcompletely different".
      // This is arguably a bug vs the assistant text delta which uses common prefix.
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(
        "completely different",
      );
    });

    it("handles empty text in partialResult", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "" }] },
        } as AgentSessionEvent,
        ctx,
      );
      // Empty text → computeToolDelta returns "" → no message
      expect(result).toEqual([]);
    });

    it("uses event.id as fallback toolCallId when toolCallId is missing", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("evt-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          id: "evt-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "data" }] },
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(result).toHaveLength(1);
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).toolCallId).toBe(
        "evt-1",
      );
    });
  });

  describe("tool_execution_update: shell preview mode", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("switches to replace mode when bash output exceeds 8KB", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      // Create output > 8KB
      const bigOutput = "x".repeat(9000);
      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput }] },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      const msg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(msg.mode).toBe("replace");
      expect(msg.truncated).toBe(true);
      expect(msg.totalBytes).toBe(9000);
    });

    it("throttles shell preview updates to 150ms intervals", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const bigOutput = "x".repeat(9000);
      vi.setSystemTime(1000);

      // First update at t=1000 — should emit
      const result1 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result1).toHaveLength(1);

      // Second update at t=1050 (< 150ms) — should be throttled
      vi.setSystemTime(1050);
      const result2 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput + "more" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result2).toEqual([]);

      // Third update at t=1200 (>= 150ms from last sent) — should emit
      vi.setSystemTime(1200);
      const result3 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput + "even more" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result3).toHaveLength(1);
    });

    it("does not switch to replace for non-bash tools even with large output", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "read");

      const bigOutput = "x".repeat(9000);
      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput }] },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      const msg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(msg.mode).toBeUndefined(); // normal append mode
    });

    it("is case-insensitive for shell tool detection", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "Bash");

      const bigOutput = "x".repeat(9000);
      // The tool name lookup uses toolNames map (which stores what was passed)
      // but isShellLikeTool lowercases. Let's check the code flow:
      // toolName = ctx.toolNames.get(key) → "Bash"
      // shellTool = isShellLikeTool("Bash") → SHELL_LIKE_TOOLS.has("bash") → true
      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "Bash",
          args: {},
          partialResult: { content: [{ type: "text", text: bigOutput }] },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).mode).toBe("replace");
    });
  });

  describe("tool_execution_update: media extraction", () => {
    it("emits data URI for image blocks", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "screenshot");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "screenshot",
          args: {},
          partialResult: {
            content: [{ type: "image", data: "abc123", mimeType: "image/png" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      const msg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(msg.output).toBe("data:image/png;base64,abc123");
    });

    it("emits data URI for audio blocks", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "tts");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "tts",
          args: {},
          partialResult: {
            content: [{ type: "audio", data: "wavdata", mimeType: "audio/wav" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      const msg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(msg.output).toBe("data:audio/wav;base64,wavdata");
    });

    it("uses default mime type for image without explicit mimeType", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "tool");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "tool",
          args: {},
          partialResult: {
            content: [{ type: "image", data: "abc" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      const msg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(msg.output).toBe("data:image/png;base64,abc");
    });
  });

  describe("tool_execution_end", () => {
    it("emits final delta and tool_end", () => {
      const ctx = makeCtx();
      ctx.partialResults.set("tc-1", "partial");
      ctx.toolNames.set("tc-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "read",
          result: { content: [{ type: "text", text: "partial output" }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      // Should emit delta (" output") + tool_end
      expect(result).toHaveLength(2);
      expect(result[0]!.type).toBe("tool_output");
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(" output");
      expect(result[1]!.type).toBe("tool_end");
    });

    it("emits only tool_end when final matches accumulated", () => {
      const ctx = makeCtx();
      ctx.partialResults.set("tc-1", "complete");
      ctx.toolNames.set("tc-1", "read");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "read",
          result: { content: [{ type: "text", text: "complete" }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe("tool_end");
    });

    it("clears context maps after processing", () => {
      const ctx = makeCtx();
      ctx.partialResults.set("tc-1", "data");
      ctx.toolNames.set("tc-1", "bash");
      ctx.shellPreviewLastSent.set("tc-1", 1000);

      translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: { content: [] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      expect(ctx.partialResults.has("tc-1")).toBe(false);
      expect(ctx.toolNames.has("tc-1")).toBe(false);
      expect(ctx.shellPreviewLastSent.has("tc-1")).toBe(false);
    });

    it("emits tool_end with isError when tool errored", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: { content: [{ type: "text", text: "command not found" }] },
          isError: true,
        } as AgentSessionEvent,
        ctx,
      );

      const toolEnd = result.find((m) => m.type === "tool_end") as Extract<
        ServerMessage,
        { type: "tool_end" }
      >;
      expect(toolEnd.isError).toBe(true);
    });

    it("handles null/empty result content", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: null,
          isError: false,
        } as unknown as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe("tool_end");
    });

    it("extracts media outputs from result content", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "screenshot");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "screenshot",
          result: {
            content: [
              { type: "text", text: "captured" },
              { type: "image", data: "imgdata", mimeType: "image/jpeg" },
            ],
          },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      // delta("captured") + image tool_output + tool_end = 3
      expect(result).toHaveLength(3);
      const imageMsg = result.find(
        (m) => m.type === "tool_output" && (m as { output: string }).output.startsWith("data:"),
      ) as Extract<ServerMessage, { type: "tool_output" }>;
      expect(imageMsg.output).toBe("data:image/jpeg;base64,imgdata");
    });

    it("uses replace mode for shell tool final output exceeding threshold", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const bigOutput = "line\n".repeat(2000); // > 8KB
      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: { content: [{ type: "text", text: bigOutput }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      const toolOutput = result.find((m) => m.type === "tool_output") as Extract<
        ServerMessage,
        { type: "tool_output" }
      >;
      expect(toolOutput.mode).toBe("replace");
      expect(toolOutput.truncated).toBe(true);
    });
  });

  describe("message_end", () => {
    it("resets state for non-assistant messages", () => {
      const ctx = makeCtx({ streamedAssistantText: "data" });
      const result = translatePiEvent(
        {
          type: "message_end",
          message: { role: "user", content: "hello" },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
      expect(ctx.streamedAssistantText).toBe("");
    });

    it("recovers thinking when not streamed live", () => {
      const ctx = makeCtx({ hasStreamedThinking: false });
      const result = translatePiEvent(
        {
          type: "message_end",
          message: {
            role: "assistant",
            content: [{ type: "thinking", thinking: "I should..." }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      expect(result[0]).toEqual({ type: "thinking_delta", delta: "I should..." });
    });

    it("skips thinking recovery when already streamed live", () => {
      const ctx = makeCtx({ hasStreamedThinking: true });
      const result = translatePiEvent(
        {
          type: "message_end",
          message: {
            role: "assistant",
            content: [{ type: "thinking", thinking: "I should..." }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toEqual([]);
    });

    it("resets hasStreamedThinking after processing", () => {
      const ctx = makeCtx({ hasStreamedThinking: true });
      translatePiEvent(
        {
          type: "message_end",
          message: { role: "assistant", content: [] },
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(ctx.hasStreamedThinking).toBe(false);
    });

    it("resets streamedAssistantText after processing", () => {
      const ctx = makeCtx({ streamedAssistantText: "some text" });
      translatePiEvent(
        {
          type: "message_end",
          message: { role: "assistant", content: [] },
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(ctx.streamedAssistantText).toBe("");
    });

    it("recovers multiple thinking blocks", () => {
      const ctx = makeCtx({ hasStreamedThinking: false });
      const result = translatePiEvent(
        {
          type: "message_end",
          message: {
            role: "assistant",
            content: [
              { type: "thinking", thinking: "first thought" },
              { type: "text", text: "response" },
              { type: "thinking", thinking: "second thought" },
            ],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual({ type: "thinking_delta", delta: "first thought" });
      expect(result[1]).toEqual({ type: "thinking_delta", delta: "second thought" });
    });

    it("skips empty thinking blocks", () => {
      const ctx = makeCtx({ hasStreamedThinking: false });
      const result = translatePiEvent(
        {
          type: "message_end",
          message: {
            role: "assistant",
            content: [{ type: "thinking", thinking: "" }],
          },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
    });

    // BUG PROBE: Interleaved tool calls between thinking and message_end.
    // If thinking_delta sets hasStreamedThinking=true, then a tool call happens,
    // then message_end arrives — hasStreamedThinking is still true, so thinking
    // recovery is correctly skipped. But if the tool call is for a DIFFERENT
    // message (new turn), hasStreamedThinking should have been reset.
    // The reset only happens in message_end and agent_start/end.
    // This means: if thinking is streamed for turn N, then turn N+1 starts
    // without an intervening message_end for turn N's assistant message,
    // hasStreamedThinking would be stale.
    // In practice, message_end always fires, so this isn't a real issue.
    it("hasStreamedThinking persists across tool executions within same turn", () => {
      const ctx = makeCtx();

      // Stream thinking
      translatePiEvent(
        {
          type: "message_update",
          message: {},
          assistantMessageEvent: { type: "thinking_delta", delta: "hmm", contentIndex: 0 },
        } as AgentSessionEvent,
        ctx,
      );
      expect(ctx.hasStreamedThinking).toBe(true);

      // Tool execution happens
      translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
        } as AgentSessionEvent,
        ctx,
      );
      translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: { content: [] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      // hasStreamedThinking should still be true
      expect(ctx.hasStreamedThinking).toBe(true);

      // message_end correctly skips thinking recovery
      const result = translatePiEvent(
        {
          type: "message_end",
          message: {
            role: "assistant",
            content: [{ type: "thinking", thinking: "hmm" }],
          },
        } as AgentSessionEvent,
        ctx,
      );
      expect(result).toEqual([]);
    });
  });

  describe("compaction events", () => {
    it("translates auto_compaction_start", () => {
      const result = translatePiEvent(
        { type: "auto_compaction_start", reason: "threshold" } as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([{ type: "compaction_start", reason: "threshold" }]);
    });

    it("translates auto_compaction_end", () => {
      const result = translatePiEvent(
        {
          type: "auto_compaction_end",
          result: { summary: "compressed", tokensBefore: 50000 },
          aborted: false,
          willRetry: false,
        } as unknown as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([
        {
          type: "compaction_end",
          aborted: false,
          willRetry: false,
          summary: "compressed",
          tokensBefore: 50000,
        },
      ]);
    });

    it("handles auto_compaction_end with undefined result", () => {
      const result = translatePiEvent(
        {
          type: "auto_compaction_end",
          result: undefined,
          aborted: true,
          willRetry: true,
        } as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([
        {
          type: "compaction_end",
          aborted: true,
          willRetry: true,
          summary: undefined,
          tokensBefore: undefined,
        },
      ]);
    });
  });

  describe("retry events", () => {
    it("translates auto_retry_start", () => {
      const result = translatePiEvent(
        {
          type: "auto_retry_start",
          attempt: 1,
          maxAttempts: 3,
          delayMs: 5000,
          errorMessage: "rate limit",
        } as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([
        {
          type: "retry_start",
          attempt: 1,
          maxAttempts: 3,
          delayMs: 5000,
          errorMessage: "rate limit",
        },
      ]);
    });

    it("translates auto_retry_end", () => {
      const result = translatePiEvent(
        {
          type: "auto_retry_end",
          success: true,
          attempt: 2,
          finalError: undefined,
        } as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([
        {
          type: "retry_end",
          success: true,
          attempt: 2,
          finalError: undefined,
        },
      ]);
    });
  });

  describe("unknown event types", () => {
    it("returns empty array for unknown event types", () => {
      const result = translatePiEvent(
        { type: "some_future_event" } as unknown as AgentSessionEvent,
        makeCtx(),
      );
      expect(result).toEqual([]);
    });
  });

  describe("toolCallId resolution", () => {
    it("prefers toolCallId over id", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          id: "evt-1",
          toolName: "bash",
          args: {},
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect((result[0] as Extract<ServerMessage, { type: "tool_start" }>).toolCallId).toBe("tc-1");
    });

    it("falls back to id when toolCallId is empty string", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "",
          id: "evt-1",
          toolName: "bash",
          args: {},
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect((result[0] as Extract<ServerMessage, { type: "tool_start" }>).toolCallId).toBe(
        "evt-1",
      );
    });

    it("returns undefined when both toolCallId and id are missing", () => {
      const ctx = makeCtx();
      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolName: "bash",
          args: {},
        } as unknown as AgentSessionEvent,
        ctx,
      );
      expect(
        (result[0] as Extract<ServerMessage, { type: "tool_start" }>).toolCallId,
      ).toBeUndefined();
    });
  });

  // ─── Integration: Full tool lifecycle ───

  describe("full tool lifecycle", () => {
    it("handles complete bash tool with progressive output", () => {
      const ctx = makeCtx();

      // tool_execution_start
      const start = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "bash",
          args: { command: "echo hello" },
        } as AgentSessionEvent,
        ctx,
      );
      expect(start[0]!.type).toBe("tool_start");

      // Progressive updates
      translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: "hel" }] },
        } as AgentSessionEvent,
        ctx,
      );

      const update2 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: "hello" }] },
        } as AgentSessionEvent,
        ctx,
      );
      expect((update2[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe("lo");

      // tool_execution_end
      const end = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: { content: [{ type: "text", text: "hello\n" }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      const outputs = end.filter((m) => m.type === "tool_output");
      expect(outputs).toHaveLength(1);
      expect((outputs[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe("\n");
      expect(end.find((m) => m.type === "tool_end")).toBeTruthy();

      // Context should be clean
      expect(ctx.partialResults.size).toBe(0);
      expect(ctx.toolNames.size).toBe(0);
    });

    it("handles concurrent tool calls with separate partialResults tracking", () => {
      const ctx = makeCtx();

      // Start two tools
      translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
        } as AgentSessionEvent,
        ctx,
      );
      translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-2",
          toolName: "read",
          args: {},
        } as AgentSessionEvent,
        ctx,
      );

      // Update tc-1
      translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "file1" }] },
        } as AgentSessionEvent,
        ctx,
      );

      // Update tc-2
      translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-2",
          toolName: "read",
          args: {},
          partialResult: { content: [{ type: "text", text: "file2" }] },
        } as AgentSessionEvent,
        ctx,
      );

      expect(ctx.partialResults.get("tc-1")).toBe("file1");
      expect(ctx.partialResults.get("tc-2")).toBe("file2");

      // End tc-1 — should only clear tc-1's state
      translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "read",
          result: { content: [{ type: "text", text: "file1" }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      expect(ctx.partialResults.has("tc-1")).toBe(false);
      expect(ctx.partialResults.get("tc-2")).toBe("file2");
    });
  });
});
