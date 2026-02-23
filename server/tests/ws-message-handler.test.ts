import { describe, expect, it, vi } from "vitest";

import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";

interface HandlerHarness {
  handler: WsMessageHandler;
  session: Session;
  sent: ServerMessage[];
  sessions: {
    sendPrompt: ReturnType<typeof vi.fn>;
    sendSteer: ReturnType<typeof vi.fn>;
    sendFollowUp: ReturnType<typeof vi.fn>;
    sendAbort: ReturnType<typeof vi.fn>;
    stopSession: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    respondToUIRequest: ReturnType<typeof vi.fn>;
    forwardClientCommand: ReturnType<typeof vi.fn>;
  };
  gate: {
    resolveDecision: ReturnType<typeof vi.fn>;
  };
  ensureSessionContextWindow: ReturnType<typeof vi.fn>;
}

function makeSession(id = "s1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeHarness(): HandlerHarness {
  const session = makeSession();
  const sent: ServerMessage[] = [];

  const sessions = {
    sendPrompt: vi.fn(async () => {}),
    sendSteer: vi.fn(async () => {}),
    sendFollowUp: vi.fn(async () => {}),
    sendAbort: vi.fn(async () => {}),
    stopSession: vi.fn(async () => {}),
    getActiveSession: vi.fn(() => undefined as Session | undefined),
    respondToUIRequest: vi.fn(() => true),
    forwardClientCommand: vi.fn(async () => {}),
  };

  const gate = {
    resolveDecision: vi.fn(() => true),
  };

  const ensureSessionContextWindow = vi.fn((value: Session) => value);

  const deps: WsMessageHandlerDeps = {
    sessions,
    gate,
    ensureSessionContextWindow,
  };

  const handler = new WsMessageHandler(deps);

  return {
    handler,
    session,
    sent,
    sessions,
    gate,
    ensureSessionContextWindow,
  };
}

function dispatch(harness: HandlerHarness, msg: ClientMessage): Promise<void> {
  return harness.handler.handleClientMessage(harness.session, msg, (outbound) => {
    harness.sent.push(outbound);
  });
}

describe("WsMessageHandler", () => {
  it("rejects subscribe/unsubscribe on per-session socket", async () => {
    const harness = makeHarness();

    await dispatch(harness, {
      type: "subscribe",
      sessionId: "s1",
      requestId: "req-1",
    });

    expect(harness.sent).toEqual([
      {
        type: "error",
        error: "Stream subscriptions are only supported on /stream (received subscribe)",
      },
    ]);
  });

  it("forwards prompt with mapped images and emits command_result success", async () => {
    const harness = makeHarness();

    await dispatch(harness, {
      type: "prompt",
      message: "hello",
      images: [{ data: "base64data", mimeType: "image/png" }],
      clientTurnId: "turn-1",
      requestId: "req-1",
      streamingBehavior: "steer",
    });

    expect(harness.sessions.sendPrompt).toHaveBeenCalledTimes(1);
    expect(harness.sessions.sendPrompt).toHaveBeenCalledWith("s1", "hello", {
      images: [{ type: "image", data: "base64data", mimeType: "image/png" }],
      clientTurnId: "turn-1",
      requestId: "req-1",
      streamingBehavior: "steer",
      timestamp: expect.any(Number),
    });

    expect(harness.sent).toEqual([
      {
        type: "command_result",
        command: "prompt",
        requestId: "req-1",
        success: true,
      },
    ]);
  });

  it("returns command_result failure when prompt handler throws and requestId exists", async () => {
    const harness = makeHarness();
    harness.sessions.sendPrompt.mockRejectedValueOnce(new Error("prompt failed"));

    await dispatch(harness, {
      type: "prompt",
      message: "hello",
      requestId: "req-2",
    });

    expect(harness.sent).toEqual([
      {
        type: "command_result",
        command: "prompt",
        requestId: "req-2",
        success: false,
        error: "prompt failed",
      },
    ]);
  });

  it("rethrows prompt handler errors when requestId is absent", async () => {
    const harness = makeHarness();
    harness.sessions.sendPrompt.mockRejectedValueOnce(new Error("prompt failed"));

    await expect(
      dispatch(harness, {
        type: "prompt",
        message: "hello",
      }),
    ).rejects.toThrow("prompt failed");

    expect(harness.sent).toEqual([]);
  });

  it("hydrates get_state through ensureSessionContextWindow", async () => {
    const harness = makeHarness();
    const activeSession: Session = {
      ...harness.session,
      model: "openai-codex/gpt-5.3-codex",
      contextWindow: 200000,
    };
    const normalizedSession: Session = {
      ...activeSession,
      contextWindow: 272000,
    };

    harness.sessions.getActiveSession.mockReturnValue(activeSession);
    harness.ensureSessionContextWindow.mockReturnValue(normalizedSession);

    await dispatch(harness, { type: "get_state", requestId: "req-3" });

    expect(harness.sessions.getActiveSession).toHaveBeenCalledWith("s1");
    expect(harness.ensureSessionContextWindow).toHaveBeenCalledWith(activeSession);
    expect(harness.sent).toEqual([
      {
        type: "state",
        session: normalizedSession,
      },
    ]);
  });

  it("reports missing permission request IDs", async () => {
    const harness = makeHarness();
    harness.gate.resolveDecision.mockReturnValueOnce(false);

    await dispatch(harness, {
      type: "permission_response",
      id: "perm-1",
      action: "allow",
    });

    expect(harness.gate.resolveDecision).toHaveBeenCalledWith("perm-1", "allow", "once", undefined);
    expect(harness.sent).toEqual([
      {
        type: "error",
        error: "Permission request not found: perm-1",
      },
    ]);
  });

  it("reports missing extension UI requests", async () => {
    const harness = makeHarness();
    harness.sessions.respondToUIRequest.mockReturnValueOnce(false);

    await dispatch(harness, {
      type: "extension_ui_response",
      id: "ui-1",
      value: "approved",
      confirmed: true,
      requestId: "req-4",
    });

    expect(harness.sessions.respondToUIRequest).toHaveBeenCalledWith("s1", {
      type: "extension_ui_response",
      id: "ui-1",
      value: "approved",
      confirmed: true,
      cancelled: undefined,
    });

    expect(harness.sent).toEqual([
      {
        type: "error",
        error: "UI request not found: ui-1",
      },
    ]);
  });

  it("forwards RPC commands with request IDs", async () => {
    const harness = makeHarness();

    await dispatch(harness, {
      type: "set_model",
      provider: "anthropic",
      modelId: "claude-sonnet-4-0",
      requestId: "req-5",
    });

    expect(harness.sessions.forwardClientCommand).toHaveBeenCalledTimes(1);
    expect(harness.sessions.forwardClientCommand).toHaveBeenCalledWith(
      "s1",
      {
        type: "set_model",
        provider: "anthropic",
        modelId: "claude-sonnet-4-0",
        requestId: "req-5",
      },
      "req-5",
    );
  });

  it("handles stop aliases through sendAbort and emits command_result", async () => {
    const harness = makeHarness();

    await dispatch(harness, {
      type: "stop",
      requestId: "req-6",
    });

    expect(harness.sessions.sendAbort).toHaveBeenCalledWith("s1");
    expect(harness.sent).toEqual([
      {
        type: "command_result",
        command: "stop",
        requestId: "req-6",
        success: true,
      },
    ]);
  });

  it("emits stop_session command_result failure when stopSession throws", async () => {
    const harness = makeHarness();
    harness.sessions.stopSession.mockRejectedValueOnce(new Error("stop failed"));

    await dispatch(harness, {
      type: "stop_session",
      requestId: "req-7",
    });

    expect(harness.sent).toEqual([
      {
        type: "command_result",
        command: "stop_session",
        requestId: "req-7",
        success: false,
        error: "stop failed",
      },
    ]);
  });
});
