import { describe, expect, it } from "vitest";

import { parsePiEvent, parsePiStateSnapshot } from "../src/pi-events.js";

describe("pi-events parser", () => {
  it("maps known tool_execution_start payloads", () => {
    const parsed = parsePiEvent({
      type: "tool_execution_start",
      id: "evt-1",
      toolCallId: "call-1",
      toolName: "bash",
      args: { command: "echo hi" },
    });

    expect(parsed).toMatchObject({
      type: "tool_execution_start",
      id: "evt-1",
      toolCallId: "call-1",
      toolName: "bash",
      args: { command: "echo hi" },
    });
  });

  it("returns unknown for invalid message_update assistant payload", () => {
    const parsed = parsePiEvent({
      type: "message_update",
      assistantMessageEvent: { type: "future_delta_v1" },
    });

    expect(parsed).toEqual({
      type: "unknown",
      raw: {
        type: "message_update",
        assistantMessageEvent: { type: "future_delta_v1" },
      },
      originalType: "message_update",
      reason: "invalid assistantMessageEvent payload",
    });
  });

  it("returns unknown for unrecognized event type", () => {
    const parsed = parsePiEvent({ type: "future_event_v99", foo: 1 });

    expect(parsed).toEqual({
      type: "unknown",
      raw: { type: "future_event_v99", foo: 1 },
      originalType: "future_event_v99",
      reason: "unrecognized event type",
    });
  });

  it("returns unknown for non-object payloads", () => {
    const parsed = parsePiEvent(null);

    expect(parsed).toEqual({
      type: "unknown",
      raw: null,
      reason: "event is not an object",
    });
  });

  it("maps agent_start", () => {
    expect(parsePiEvent({ type: "agent_start" })).toEqual({ type: "agent_start" });
  });

  it("maps agent_end with messages", () => {
    const parsed = parsePiEvent({ type: "agent_end", messages: [{ role: "assistant" }] });
    expect(parsed).toMatchObject({ type: "agent_end" });
    expect((parsed as { messages?: unknown[] }).messages).toHaveLength(1);
  });

  it("maps turn_start", () => {
    expect(parsePiEvent({ type: "turn_start" })).toEqual({ type: "turn_start" });
  });

  it("maps turn_end with message", () => {
    const parsed = parsePiEvent({
      type: "turn_end",
      message: { role: "assistant", content: "done" },
    });
    expect(parsed).toMatchObject({ type: "turn_end" });
    expect((parsed as { message?: { role?: string } }).message?.role).toBe("assistant");
  });

  it("maps message_start", () => {
    const parsed = parsePiEvent({
      type: "message_start",
      message: { role: "assistant" },
    });
    expect(parsed).toMatchObject({ type: "message_start" });
  });

  it("maps message_end with required message", () => {
    const parsed = parsePiEvent({
      type: "message_end",
      message: { role: "assistant", content: "hi" },
    });
    expect(parsed).toMatchObject({ type: "message_end" });
    expect((parsed as { message: { role?: string } }).message.role).toBe("assistant");
  });

  it("rejects message_end without message", () => {
    const parsed = parsePiEvent({ type: "message_end" });
    expect(parsed.type).toBe("unknown");
    expect((parsed as { reason: string }).reason).toContain("missing message payload");
  });

  it("maps tool_execution_update", () => {
    const parsed = parsePiEvent({
      type: "tool_execution_update",
      toolCallId: "tc-1",
      toolName: "read",
      args: { path: "/tmp" },
      partialResult: { summary: "reading..." },
    });
    expect(parsed).toMatchObject({
      type: "tool_execution_update",
      toolName: "read",
      toolCallId: "tc-1",
    });
  });

  it("maps tool_execution_end", () => {
    const parsed = parsePiEvent({
      type: "tool_execution_end",
      toolCallId: "tc-1",
      toolName: "bash",
      result: { summary: "ok", content: [{ type: "text", text: "done" }] },
      isError: false,
    });
    expect(parsed).toMatchObject({
      type: "tool_execution_end",
      toolName: "bash",
      isError: false,
    });
  });

  it("rejects tool_execution_end without toolName", () => {
    const parsed = parsePiEvent({ type: "tool_execution_end", isError: false });
    expect(parsed.type).toBe("unknown");
  });

  it("maps auto_compaction_start", () => {
    const parsed = parsePiEvent({ type: "auto_compaction_start", reason: "overflow" });
    expect(parsed).toEqual({ type: "auto_compaction_start", reason: "overflow" });
  });

  it("maps auto_compaction_end", () => {
    const parsed = parsePiEvent({
      type: "auto_compaction_end",
      aborted: false,
      willRetry: false,
    });
    expect(parsed).toMatchObject({
      type: "auto_compaction_end",
      aborted: false,
      willRetry: false,
    });
  });

  it("maps auto_retry_start", () => {
    const parsed = parsePiEvent({
      type: "auto_retry_start",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 2000,
      errorMessage: "rate limited",
    });
    expect(parsed).toMatchObject({
      type: "auto_retry_start",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 2000,
    });
  });

  it("maps auto_retry_end", () => {
    const parsed = parsePiEvent({
      type: "auto_retry_end",
      success: true,
      attempt: 2,
    });
    expect(parsed).toEqual({ type: "auto_retry_end", success: true, attempt: 2, finalError: undefined });
  });

  it("maps extension_ui_request with required fields", () => {
    const parsed = parsePiEvent({
      type: "extension_ui_request",
      id: "ext-1",
      method: "confirm",
      title: "Allow?",
      options: ["yes", "no"],
    });
    expect(parsed).toMatchObject({
      type: "extension_ui_request",
      id: "ext-1",
      method: "confirm",
    });
  });

  it("rejects extension_ui_request without id", () => {
    const parsed = parsePiEvent({ type: "extension_ui_request", method: "confirm" });
    expect(parsed.type).toBe("unknown");
  });

  it("maps extension_error", () => {
    const parsed = parsePiEvent({
      type: "extension_error",
      extensionPath: "/ext/gate",
      error: "timeout",
    });
    expect(parsed).toMatchObject({
      type: "extension_error",
      extensionPath: "/ext/gate",
      error: "timeout",
    });
  });

  it("maps response with required command", () => {
    const parsed = parsePiEvent({
      type: "response",
      id: 42,
      command: "get_state",
      success: true,
      data: { model: "sonnet" },
    });
    expect(parsed).toMatchObject({
      type: "response",
      id: 42,
      command: "get_state",
      success: true,
    });
  });

  it("rejects response without command", () => {
    const parsed = parsePiEvent({ type: "response", success: true });
    expect(parsed.type).toBe("unknown");
  });

  it("returns unknown for missing type field", () => {
    const parsed = parsePiEvent({ foo: "bar" });
    expect(parsed).toEqual({
      type: "unknown",
      raw: { foo: "bar" },
      reason: "event is missing string type",
    });
  });
});

describe("pi state snapshot parser", () => {
  it("parses known state snapshot shape", () => {
    const snapshot = parsePiStateSnapshot({
      sessionFile: "/tmp/session.json",
      sessionId: "s1",
      sessionName: "My Session",
      model: {
        provider: "anthropic",
        id: "claude-sonnet-4",
        name: "Claude Sonnet 4",
      },
      thinkingLevel: "medium",
      isStreaming: true,
      autoCompaction: false,
    });

    expect(snapshot).toEqual({
      sessionFile: "/tmp/session.json",
      sessionId: "s1",
      sessionName: "My Session",
      model: {
        provider: "anthropic",
        id: "claude-sonnet-4",
        name: "Claude Sonnet 4",
      },
      thinkingLevel: "medium",
      isStreaming: true,
      autoCompaction: false,
    });
  });

  it("returns null for non-object snapshots", () => {
    expect(parsePiStateSnapshot(null)).toBeNull();
    expect(parsePiStateSnapshot("nope")).toBeNull();
  });

  it("drops invalid nested model shapes", () => {
    const snapshot = parsePiStateSnapshot({
      sessionId: "s2",
      model: "invalid-model",
    });

    expect(snapshot).toEqual({
      sessionFile: undefined,
      sessionId: "s2",
      sessionName: undefined,
      model: undefined,
      thinkingLevel: undefined,
      isStreaming: undefined,
      autoCompaction: undefined,
    });
  });
});
