import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";
import type { ServerMessage, Session } from "./types.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import {
  translatePiEvent,
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
    streamingArgPreviews: new Set(),
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
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

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

  it("computes delta for repeated writes to the same file", () => {
    const session = makeSession();
    // First write: new file with 5 lines
    updateSessionChangeStats(session, "write", {
      path: "/tmp/a.ts",
      content: "a\nb\nc\nd\ne",
    });
    expect(session.changeStats!.addedLines).toBe(5);
    expect(session.changeStats!.removedLines).toBe(0);

    // Second write: rewrite with 3 lines — file was created in this
    // session, so shrinking it reduces addedLines (not adds removedLines)
    // because from the pre-session baseline the file didn't exist.
    updateSessionChangeStats(session, "write", {
      path: "/tmp/a.ts",
      content: "x\ny\nz",
    });
    expect(session.changeStats!.addedLines).toBe(3); // 5 - 2 = 3 (file is 3 lines, all new)
    expect(session.changeStats!.removedLines).toBe(0); // can't remove from a new file
  });

  it("computes delta for write after edit on same file", () => {
    const session = makeSession();
    // Write 3-line file
    updateSessionChangeStats(session, "write", {
      path: "/tmp/a.ts",
      content: "a\nb\nc",
    });
    expect(session.changeStats!.addedLines).toBe(3);

    // Edit adds 2 lines (1 → 3 replacement)
    updateSessionChangeStats(session, "edit", {
      path: "/tmp/a.ts",
      oldText: "b",
      newText: "b1\nb2\nb3",
    });
    expect(session.changeStats!.addedLines).toBe(5); // 3 + 2

    // Rewrite the file (now tracked as 5 lines) with 6 lines
    updateSessionChangeStats(session, "write", {
      path: "/tmp/a.ts",
      content: "1\n2\n3\n4\n5\n6",
    });
    expect(session.changeStats!.addedLines).toBe(6); // 5 + 1
    expect(session.changeStats!.removedLines).toBe(0);
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

  // Regression: before the fix, every write counted full content as added lines.
  // A typical agent session with rewrites would show +3,897 -30 when the real
  // diff was +595 -1,321.  This test reproduces the pattern: create files, edit
  // them, then rewrite them.  The old code would report +1,270 added / -2 removed.
  // The correct numbers are +310 added / -92 removed.
  it("realistic multi-file session does not inflate line counts on rewrites", () => {
    const session = makeSession();
    const lines = (n: number): string =>
      Array.from({ length: n }, (_, i) => `line ${i}`).join("\n");

    // 1. Agent creates component.tsx (200 lines)
    updateSessionChangeStats(session, "write", { path: "/src/component.tsx", content: lines(200) });

    // 2. Agent creates test.ts (100 lines)
    updateSessionChangeStats(session, "write", { path: "/src/test.ts", content: lines(100) });

    // 3. Agent edits component.tsx: replace 10 lines with 8 (net -2)
    updateSessionChangeStats(session, "edit", {
      path: "/src/component.tsx",
      oldText: lines(10),
      newText: lines(8),
    });

    // 4. Agent rewrites component.tsx after refactor (now tracked as 198 lines → 210 lines)
    updateSessionChangeStats(session, "write", { path: "/src/component.tsx", content: lines(210) });

    // 5. Agent rewrites test.ts to match new API (100 → 90 lines, shrunk)
    updateSessionChangeStats(session, "write", { path: "/src/test.ts", content: lines(90) });

    // Both files were created in this session, so their final line counts
    // are the only thing that matters (no pre-session baseline to compare):
    //   component.tsx: created, final = 210 lines → +210
    //   test.ts:       created, final = 90 lines  → +90
    //   Total:         +300 added, -0 removed
    //
    // OLD behavior: +312 added, -12 removed (intermediate deltas leaked into removed)
    // OLDER behavior: +600 added, -2 removed (no rewrite tracking at all)
    expect(session.changeStats!.addedLines).toBe(300);
    expect(session.changeStats!.removedLines).toBe(0);
    expect(session.changeStats!.filesChanged).toBe(2);
    expect(session.changeStats!.mutatingToolCalls).toBe(5);
  });

  it("edit to untracked file does not create phantom file line count", () => {
    const session = makeSession();
    // Edit a file that was never written through our tracking (e.g. pre-existing)
    updateSessionChangeStats(session, "edit", {
      path: "/src/existing.ts",
      oldText: "old\nstuff",
      newText: "new\nstuff\nhere",
    });
    expect(session.changeStats!.addedLines).toBe(1);
    expect(session.changeStats!.removedLines).toBe(0);

    // A subsequent write to the same file should count full content as added
    // since we never tracked it via write (edit-only files have no baseline)
    updateSessionChangeStats(session, "write", { path: "/src/existing.ts", content: "a\nb\nc" });
    expect(session.changeStats!.addedLines).toBe(4); // 1 + 3
  });

  it("_fileLineCounts survives session round-trip through JSON", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "/a.ts", content: "x\ny\nz" });

    // Simulate persist + reload (JSON round-trip)
    const reloaded = JSON.parse(JSON.stringify(session)) as typeof session;

    // Continue accumulating on the reloaded session
    updateSessionChangeStats(reloaded, "write", { path: "/a.ts", content: "x\ny\nz\nw" });
    expect(reloaded.changeStats!.addedLines).toBe(4); // 3 + 1 (not 3 + 4)
  });

  // ─── Session-created file tracking ───

  it("session-created file: edit that shortens reduces addedLines, not removedLines", () => {
    const session = makeSession();
    const lines = (n: number): string =>
      Array.from({ length: n }, (_, i) => `line ${i}`).join("\n");

    // Create a new file (100 lines)
    updateSessionChangeStats(session, "write", { path: "/new.ts", content: lines(100) });
    expect(session.changeStats!.addedLines).toBe(100);
    expect(session.changeStats!.removedLines).toBe(0);

    // Edit shortens it by 5 lines (replace 10 with 5)
    updateSessionChangeStats(session, "edit", {
      path: "/new.ts",
      oldText: lines(10),
      newText: lines(5),
    });

    // Removal should reduce addedLines, not increment removedLines
    expect(session.changeStats!.addedLines).toBe(95);
    expect(session.changeStats!.removedLines).toBe(0);
  });

  it("session-created file: edit that lengthens still increments addedLines", () => {
    const session = makeSession();

    updateSessionChangeStats(session, "write", { path: "/new.ts", content: "a\nb\nc" });
    expect(session.changeStats!.addedLines).toBe(3);

    // Edit adds 2 lines
    updateSessionChangeStats(session, "edit", {
      path: "/new.ts",
      oldText: "b",
      newText: "b\nx\ny",
    });
    expect(session.changeStats!.addedLines).toBe(5); // 3 + 2
    expect(session.changeStats!.removedLines).toBe(0);
  });

  it("pre-existing file: edit removals go to removedLines normally", () => {
    const session = makeSession();

    // Edit a pre-existing file (never written in this session)
    updateSessionChangeStats(session, "edit", {
      path: "/existing.ts",
      oldText: "a\nb\nc\nd\ne",
      newText: "a\nb",
    });
    // Pre-existing file — removals count as removedLines
    expect(session.changeStats!.addedLines).toBe(0);
    expect(session.changeStats!.removedLines).toBe(3);
  });

  it("file edited then written is NOT marked as session-created", () => {
    const session = makeSession();

    // Edit first (proves file pre-exists)
    updateSessionChangeStats(session, "edit", {
      path: "/pre-existing.ts",
      oldText: "old",
      newText: "old\nnew",
    });
    expect(session.changeStats!.addedLines).toBe(1);

    // Then full rewrite
    updateSessionChangeStats(session, "write", {
      path: "/pre-existing.ts",
      content: "completely\nnew\ncontent",
    });

    // Subsequent shrinking edit should count as removedLines (not session-created)
    updateSessionChangeStats(session, "edit", {
      path: "/pre-existing.ts",
      oldText: "completely\nnew\ncontent",
      newText: "short",
    });
    expect(session.changeStats!.removedLines).toBe(2);
  });

  it("_sessionCreatedFiles survives JSON round-trip", () => {
    const session = makeSession();
    updateSessionChangeStats(session, "write", { path: "/a.ts", content: "x\ny\nz" });
    expect(session.changeStats!._sessionCreatedFiles).toEqual(["/a.ts"]);

    // Round-trip
    const reloaded = JSON.parse(JSON.stringify(session)) as typeof session;

    // Edit after reload — should still know the file was created
    updateSessionChangeStats(reloaded, "edit", {
      path: "/a.ts",
      oldText: "x\ny\nz",
      newText: "x\ny",
    });
    expect(reloaded.changeStats!.addedLines).toBe(2); // 3 - 1
    expect(reloaded.changeStats!.removedLines).toBe(0);
  });

  it("mixed session: created and pre-existing files tracked independently", () => {
    const session = makeSession();
    const lines = (n: number): string =>
      Array.from({ length: n }, (_, i) => `line ${i}`).join("\n");

    // Create new file
    updateSessionChangeStats(session, "write", { path: "/new.ts", content: lines(100) });

    // Edit pre-existing file (add 10 lines)
    updateSessionChangeStats(session, "edit", {
      path: "/old.ts",
      oldText: lines(5),
      newText: lines(15),
    });

    // Shorten new file by 20 lines
    updateSessionChangeStats(session, "edit", {
      path: "/new.ts",
      oldText: lines(30),
      newText: lines(10),
    });

    // Shorten pre-existing file by 3 lines
    updateSessionChangeStats(session, "edit", {
      path: "/old.ts",
      oldText: lines(8),
      newText: lines(5),
    });

    // new.ts: created → +100, then -20 redirected → addedLines = 80+10 = 90
    // old.ts: pre-existing → +10, then -3 as removedLines
    expect(session.changeStats!.addedLines).toBe(90); // 100 - 20 + 10
    expect(session.changeStats!.removedLines).toBe(3); // only old.ts contributes
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

  describe("message_update: streaming arg viewport preview", () => {
    it("emits tool_output with replace mode for large string args", () => {
      const ctx = makeCtx();
      const largeBody = "# Workspace Review\n\n" + "x".repeat(300);
      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "tc-1",
              name: "todo",
              arguments: { action: "create", id: "de1c026a", body: largeBody },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toHaveLength(2);
      expect(result[0]!.type).toBe("tool_start");
      const output = result[1] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(output.type).toBe("tool_output");
      expect(output.output).toBe(largeBody);
      expect(output.mode).toBe("replace");
      expect(output.toolCallId).toBe("tc-1");
      expect(ctx.streamingArgPreviews.has("tc-1")).toBe(true);
    });

    it("does not emit tool_output for small string args", () => {
      const ctx = makeCtx();
      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "tc-1",
              name: "todo",
              arguments: { action: "list" },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe("tool_start");
      expect(ctx.streamingArgPreviews.size).toBe(0);
    });

    it("picks the largest string arg when multiple exceed threshold", () => {
      const ctx = makeCtx();
      const shortText = "a".repeat(250);
      const longText = "b".repeat(500);
      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "tc-1",
              name: "custom",
              arguments: { title: shortText, body: longText },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      const output = result.find((m) => m.type === "tool_output") as Extract<
        ServerMessage,
        { type: "tool_output" }
      >;
      expect(output.output).toBe(longText);
    });

    it("ignores non-string args (objects, arrays, numbers)", () => {
      const ctx = makeCtx();
      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "tc-1",
              name: "some_extension",
              arguments: {
                data: { nested: { rows: Array(100).fill({ x: 1, y: 2 }) } },
                title: "short",
              },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      expect(result).toHaveLength(1); // only tool_start, no tool_output
    });

    it("adds callSegments from mobile renderer during streaming", () => {
      const mockRenderer = {
        renderCall: (_tool: string, _args: Record<string, unknown>) => [
          { text: "todo ", style: "bold" as const },
          { text: "create", style: "accent" as const },
        ],
        renderResult: () => [],
      };
      const mockRegistry = {
        renderCall: (tool: string, args: Record<string, unknown>) =>
          mockRenderer.renderCall(tool, args),
        renderResult: () => undefined,
      };
      const ctx = makeCtx({
        mobileRenderers: mockRegistry as unknown as MobileRendererRegistry,
      });

      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "tc-1",
              name: "todo",
              arguments: { action: "create" },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      const result = translatePiEvent(event, ctx);
      const toolStart = result[0] as Extract<ServerMessage, { type: "tool_start" }>;
      expect(toolStart.callSegments).toEqual([
        { text: "todo ", style: "bold" },
        { text: "create", style: "accent" },
      ]);
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

    it("clears streaming arg preview with empty replace before tool_start", () => {
      const ctx = makeCtx();
      ctx.streamingArgPreviews.add("tc-1");

      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "todo",
          args: { action: "create", body: "content" },
        } as AgentSessionEvent,
        ctx,
      );

      // Should emit: [tool_output(empty, replace), tool_start]
      expect(result).toHaveLength(2);
      const clearMsg = result[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(clearMsg.type).toBe("tool_output");
      expect(clearMsg.output).toBe("");
      expect(clearMsg.mode).toBe("replace");
      expect(clearMsg.toolCallId).toBe("tc-1");

      const startMsg = result[1] as Extract<ServerMessage, { type: "tool_start" }>;
      expect(startMsg.type).toBe("tool_start");
      expect(startMsg.tool).toBe("todo");

      expect(ctx.streamingArgPreviews.has("tc-1")).toBe(false);
    });

    it("does not emit clear when no streaming arg preview exists", () => {
      const ctx = makeCtx();

      const result = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "bash",
          args: { command: "ls" },
        } as AgentSessionEvent,
        ctx,
      );

      // No preview to clear — just the tool_start
      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe("tool_start");
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

    // When partialResult text unexpectedly diverges, computeToolDelta emits
    // the full text rather than a delta from a common prefix. The client
    // receives duplicated output, but no content is dropped.
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

  describe("ANSI sanitization in tool output", () => {
    it("preserves SGR color codes in tool_execution_update text", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: {
            content: [{ type: "text", text: "\x1b[31mError: not found\x1b[0m" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      // SGR codes preserved — iOS ANSIParser renders them as colored text
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(
        "\x1b[31mError: not found\x1b[0m",
      );
    });

    it("preserves SGR color codes in tool_execution_end text", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      const result = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "bash",
          result: {
            content: [{ type: "text", text: "\x1b[32mSuccess\x1b[0m: done" }],
          },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      const toolOutput = result.find((m) => m.type === "tool_output") as Extract<
        ServerMessage,
        { type: "tool_output" }
      >;
      expect(toolOutput).toBeDefined();
      expect(toolOutput.output).toBe("\x1b[32mSuccess\x1b[0m: done");
    });

    it("strips TUI chrome but preserves SGR colors from streaming output", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      // Simulates capturing pi TUI output — DEC modes and OSC stripped, SGR preserved
      const tuiOutput =
        "\x1b[?2004h\x1b[?25l\x1b[0m\x1b]8;;\x1b\\" +
        "\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\n" +
        "\x1b[38;5;167mError: 404\x1b[39m\n" +
        "\x1b[?25h\x1b[?2004l";

      const result = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: { content: [{ type: "text", text: tuiOutput }] },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result).toHaveLength(1);
      // DEC modes + OSC stripped, SGR preserved
      expect((result[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(
        "\x1b[0m\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\n" +
          "\x1b[38;5;167mError: 404\x1b[39m\n",
      );
    });

    it("computes deltas correctly with SGR codes preserved", () => {
      const ctx = makeCtx();
      ctx.toolNames.set("tc-1", "bash");

      // First update: colored text
      translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: {
            content: [{ type: "text", text: "\x1b[32mline1\x1b[0m" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      // Second update: more colored text appended
      const result2 = translatePiEvent(
        {
          type: "tool_execution_update",
          toolCallId: "tc-1",
          toolName: "bash",
          args: {},
          partialResult: {
            content: [{ type: "text", text: "\x1b[32mline1\x1b[0m\n\x1b[31mline2\x1b[0m" }],
          },
        } as AgentSessionEvent,
        ctx,
      );

      expect(result2).toHaveLength(1);
      // Delta includes SGR codes — they're part of the text now
      expect((result2[0] as Extract<ServerMessage, { type: "tool_output" }>).output).toBe(
        "\n\x1b[31mline2\x1b[0m",
      );
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

    it("handles extension tool with streaming arg preview lifecycle", () => {
      const ctx = makeCtx();
      const largeBody = "# Review\n\n" + "Content paragraph. ".repeat(20);

      // Phase 1: toolcall_delta — streaming args
      const streaming1 = translatePiEvent(
        {
          type: "message_update",
          message: {
            content: [
              {
                type: "toolCall",
                id: "tc-1",
                name: "todo",
                arguments: { action: "update", id: "abc123", body: largeBody },
              },
            ],
          },
          assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
        } as unknown as AgentSessionEvent,
        ctx,
      );

      // Should emit tool_start + tool_output (preview)
      expect(streaming1).toHaveLength(2);
      expect(streaming1[0]!.type).toBe("tool_start");
      const preview = streaming1[1] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(preview.output).toBe(largeBody);
      expect(preview.mode).toBe("replace");
      expect(ctx.streamingArgPreviews.has("tc-1")).toBe(true);

      // Phase 2: tool_execution_start — clears preview, emits real tool_start
      const execStart = translatePiEvent(
        {
          type: "tool_execution_start",
          toolCallId: "tc-1",
          toolName: "todo",
          args: { action: "update", id: "abc123", body: largeBody },
        } as AgentSessionEvent,
        ctx,
      );

      // Should emit: empty-replace clear + tool_start
      expect(execStart).toHaveLength(2);
      const clearMsg = execStart[0] as Extract<ServerMessage, { type: "tool_output" }>;
      expect(clearMsg.output).toBe("");
      expect(clearMsg.mode).toBe("replace");
      expect(execStart[1]!.type).toBe("tool_start");
      expect(ctx.streamingArgPreviews.has("tc-1")).toBe(false);

      // Phase 3: tool_execution_end — real output
      const execEnd = translatePiEvent(
        {
          type: "tool_execution_end",
          toolCallId: "tc-1",
          toolName: "todo",
          result: { content: [{ type: "text", text: '{"id":"abc123","status":"updated"}' }] },
          isError: false,
        } as AgentSessionEvent,
        ctx,
      );

      const realOutput = execEnd.find((m) => m.type === "tool_output") as Extract<
        ServerMessage,
        { type: "tool_output" }
      >;
      expect(realOutput.output).toBe('{"id":"abc123","status":"updated"}');
      expect(realOutput.mode).toBeUndefined(); // append mode (default)
      expect(execEnd.find((m) => m.type === "tool_end")).toBeTruthy();

      // Context fully clean
      expect(ctx.streamingArgPreviews.size).toBe(0);
      expect(ctx.partialResults.size).toBe(0);
    });

    it("streaming arg preview skipped when toolCallId is missing", () => {
      const ctx = makeCtx();
      const largeBody = "x".repeat(300);
      const event = {
        type: "message_update",
        message: {
          content: [
            {
              type: "toolCall",
              id: "", // empty — toolCallId will be empty
              name: "todo",
              arguments: { body: largeBody },
            },
          ],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "{}" },
      } as unknown as AgentSessionEvent;

      // Empty toolCallId → extractStreamingToolCallUpdate returns null
      const result = translatePiEvent(event, ctx);
      expect(result).toEqual([]);
      expect(ctx.streamingArgPreviews.size).toBe(0);
    });
  });
});
