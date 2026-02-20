import { describe, expect, it, vi } from "vitest";
import type { Session } from "../src/types.js";
import {
  normalizeRpcError,
  translatePiEvent,
  updateSessionChangeStats,
  applyMessageEndToSession,
  type TranslationContext,
} from "../src/session-protocol.js";
import { composeModelId } from "../src/sessions.js";

function makeSession(): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    model: "openai/gpt-test",
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeCtx(): TranslationContext {
  return {
    sessionId: "s1",
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
  };
}

describe("session-protocol normalizeRpcError", () => {
  it("strips parse prefix from RPC errors", () => {
    expect(normalizeRpcError("set_model", "Failed to parse command: Invalid payload")).toBe(
      "Invalid payload",
    );
  });

  it("normalizes compact already-compacted message", () => {
    expect(normalizeRpcError("compact", "Already compacted for this turn")).toBe(
      "Already compacted",
    );
  });
});

describe("session-protocol translatePiEvent", () => {
  it("streams text deltas and updates context", () => {
    const ctx = makeCtx();

    const messages = translatePiEvent(
      {
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", delta: "hello" },
      },
      ctx,
    );

    expect(messages).toEqual([{ type: "text_delta", delta: "hello" }]);
    expect(ctx.streamedAssistantText).toBe("hello");
  });

  it("converts tool partialResult replace semantics into append deltas", () => {
    const ctx = makeCtx();

    const first = translatePiEvent(
      {
        type: "tool_execution_update",
        toolCallId: "tc-1",
        partialResult: {
          content: [{ type: "text", text: "line1\n" }],
        },
      },
      ctx,
    );

    const second = translatePiEvent(
      {
        type: "tool_execution_update",
        toolCallId: "tc-1",
        partialResult: {
          content: [{ type: "text", text: "line1\nline2\n" }],
        },
      },
      ctx,
    );

    expect(first).toEqual([{ type: "tool_output", output: "line1\n", toolCallId: "tc-1" }]);
    expect(second).toEqual([{ type: "tool_output", output: "line2\n", toolCallId: "tc-1" }]);
  });

  it("emits final tool_output from tool_execution_end text when no partial exists", () => {
    const ctx = makeCtx();

    const messages = translatePiEvent(
      {
        type: "tool_execution_end",
        toolName: "read",
        toolCallId: "tc-final",
        result: {
          content: [{ type: "text", text: "full read output" }],
        },
      },
      ctx,
    );

    expect(messages).toEqual([
      { type: "tool_output", output: "full read output", toolCallId: "tc-final" },
      { type: "tool_end", tool: "read", toolCallId: "tc-final" },
    ]);
  });

  it("emits only tail delta on tool_execution_end after partial output", () => {
    const ctx = makeCtx();

    translatePiEvent(
      {
        type: "tool_execution_update",
        toolCallId: "tc-tail",
        partialResult: {
          content: [{ type: "text", text: "line1\n" }],
        },
      },
      ctx,
    );

    const messages = translatePiEvent(
      {
        type: "tool_execution_end",
        toolName: "read",
        toolCallId: "tc-tail",
        result: {
          content: [{ type: "text", text: "line1\nline2\n" }],
        },
      },
      ctx,
    );

    expect(messages).toEqual([
      { type: "tool_output", output: "line2\n", toolCallId: "tc-tail" },
      { type: "tool_end", tool: "read", toolCallId: "tc-tail" },
    ]);
  });

  it("falls back to event id when toolCallId is missing", () => {
    const ctx = makeCtx();

    const start = translatePiEvent(
      {
        type: "tool_execution_start",
        id: "evt-tool-1",
        toolName: "read",
        args: { path: "README.md" },
      },
      ctx,
    );

    const end = translatePiEvent(
      {
        type: "tool_execution_end",
        id: "evt-tool-1",
        toolName: "read",
        result: {
          content: [{ type: "text", text: "content" }],
        },
      },
      ctx,
    );

    expect(start).toEqual([
      { type: "tool_start", tool: "read", args: { path: "README.md" }, toolCallId: "evt-tool-1" },
    ]);
    expect(end).toEqual([
      { type: "tool_output", output: "content", toolCallId: "evt-tool-1" },
      { type: "tool_end", tool: "read", toolCallId: "evt-tool-1" },
    ]);
  });

  it("emits media tool_output data URIs", () => {
    const ctx = makeCtx();

    const messages = translatePiEvent(
      {
        type: "tool_execution_update",
        toolCallId: "tc-media",
        partialResult: {
          content: [
            { type: "image", data: "aGVsbG8=", mimeType: "image/png" },
            { type: "audio", data: "d29ybGQ=", mimeType: "audio/wav" },
          ],
        },
      },
      ctx,
    );

    expect(messages).toEqual([
      { type: "tool_output", output: "data:image/png;base64,aGVsbG8=", toolCallId: "tc-media" },
      { type: "tool_output", output: "data:audio/wav;base64,d29ybGQ=", toolCallId: "tc-media" },
    ]);
  });

  it("recovers missing message_end tail and thinking blocks", () => {
    const ctx = makeCtx();
    ctx.streamedAssistantText = "Short answer: ";

    const messages = translatePiEvent(
      {
        type: "message_end",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "Short answer: plus detail." },
            { type: "thinking", thinking: "chain" },
          ],
        },
      },
      ctx,
    );

    expect(messages).toEqual([
      { type: "text_delta", delta: "plus detail." },
      { type: "thinking_delta", delta: "chain" },
    ]);
    expect(ctx.streamedAssistantText).toBe("");
  });

  it("skips thinking recovery when thinking was already streamed", () => {
    const ctx = makeCtx();
    ctx.streamedAssistantText = "Full answer.";
    ctx.hasStreamedThinking = true; // thinking_delta events were forwarded live

    const messages = translatePiEvent(
      {
        type: "message_end",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "Full answer." },
            { type: "thinking", thinking: "streamed thinking" },
          ],
        },
      },
      ctx,
    );

    // No text_delta (text matches), no thinking_delta (already streamed)
    expect(messages).toEqual([]);
    expect(ctx.hasStreamedThinking).toBe(false); // reset for next message
  });

  it("sets hasStreamedThinking on thinking_delta forwarding", () => {
    const ctx = makeCtx();
    expect(ctx.hasStreamedThinking).toBe(false);

    translatePiEvent(
      {
        type: "message_update",
        assistantMessageEvent: { type: "thinking_delta", delta: "hmm" },
      },
      ctx,
    );

    expect(ctx.hasStreamedThinking).toBe(true);
  });

  it("logs extension errors and emits no messages", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const ctx = makeCtx();

    const messages = translatePiEvent(
      {
        type: "extension_error",
        extensionPath: "ext.ts",
        error: "boom",
      },
      ctx,
    );

    expect(messages).toEqual([]);
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });
});

describe("session-protocol state mutation helpers", () => {
  it("updates change stats for write/edit tool calls", () => {
    const session = makeSession();

    updateSessionChangeStats(session, "write", {
      path: "src/a.ts",
      content: "line1\nline2",
    });

    updateSessionChangeStats(session, "edit", {
      path: "src/a.ts",
      oldText: "line1\nline2",
      newText: "line1\nline2\nline3",
    });

    expect(session.changeStats).toEqual({
      mutatingToolCalls: 2,
      filesChanged: 1,
      changedFiles: ["src/a.ts"],
      addedLines: 3,
      removedLines: 0,
    });
  });

  it("applies assistant message_end usage and persistence", () => {
    const session = makeSession();
    const addMessage = vi.fn();

    applyMessageEndToSession(
      session,
      {
        role: "assistant",
        content: [{ type: "text", text: "final answer" }],
        usage: {
          input: 5,
          output: 7,
          cacheRead: 2,
          cacheWrite: 3,
          cost: { total: 1.25 },
        },
      },
      addMessage,
    );

    expect(addMessage).toHaveBeenCalledTimes(1);
    expect(session.messageCount).toBe(1);
    expect(session.tokens).toEqual({ input: 5, output: 7 });
    expect(session.cost).toBe(1.25);
    expect(session.contextTokens).toBe(17);
    expect(session.lastMessage).toBe("final answer");
  });

  it("ignores user message_end for persistence", () => {
    const session = makeSession();
    const addMessage = vi.fn();

    applyMessageEndToSession(
      session,
      {
        role: "user",
        content: "hello",
      },
      addMessage,
    );

    expect(addMessage).not.toHaveBeenCalled();
    expect(session.messageCount).toBe(0);
  });
});

describe("composeModelId", () => {
  it("prefixes simple model with provider", () => {
    expect(composeModelId("anthropic", "claude-sonnet-4-0")).toBe("anthropic/claude-sonnet-4-0");
  });

  it("prefixes nested model with provider (openrouter/z.ai/glm-5)", () => {
    expect(composeModelId("openrouter", "z.ai/glm-5")).toBe("openrouter/z.ai/glm-5");
  });

  it("does not double-prefix when model already starts with provider", () => {
    expect(composeModelId("anthropic", "anthropic/claude-sonnet-4-0")).toBe("anthropic/claude-sonnet-4-0");
  });

  it("handles lmstudio local models", () => {
    expect(composeModelId("lmstudio", "glm-4.7-flash-mlx")).toBe("lmstudio/glm-4.7-flash-mlx");
  });
});
