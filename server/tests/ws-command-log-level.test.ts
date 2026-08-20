import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";

const { records } = vi.hoisted(() => {
  const records: Array<{
    level: string;
    event: string;
    context?: Record<string, unknown>;
  }> = [];
  return { records };
});

vi.mock("../src/logger.js", () => ({
  createLogger: () => ({
    debug: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "debug", event, context });
    },
    info: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "info", event, context });
    },
    warn: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "warn", event, context });
    },
    error: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "error", event, context });
    },
    child() {
      return this;
    },
    isEnabled: () => true,
  }),
}));

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

function makeHandler() {
  const session = makeSession();
  const sent: ServerMessage[] = [];
  const sessions = {
    sendPrompt: vi.fn(async () => {}),
    sendSteer: vi.fn(async () => {}),
    sendFollowUp: vi.fn(async () => {}),
    getMessageQueue: vi.fn(() => ({ version: 0, steering: [], followUp: [] })),
    setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    sendAbort: vi.fn(async () => {}),
    stopSession: vi.fn(async () => {}),
    getActiveSession: vi.fn(() => undefined as Session | undefined),
    respondToUIRequest: vi.fn(() => true),
    forwardClientCommand: vi.fn(async () => {}),
  };
  const deps: WsMessageHandlerDeps = {
    sessions,
    ensureSessionContextWindow: vi.fn((value: Session) => value),
  };
  return {
    session,
    sent,
    sessions,
    handler: new WsMessageHandler(deps),
  };
}

function dispatch(
  harness: ReturnType<typeof makeHandler>,
  msg: ClientMessage,
): Promise<void> {
  return harness.handler.handleClientMessage(harness.session, msg, (outbound) => {
    harness.sent.push(outbound);
  });
}

function eventsNamed(event: string) {
  return records.filter((entry) => entry.event === event);
}

describe("WsMessageHandler heartbeat log levels", () => {
  beforeEach(() => {
    records.length = 0;
  });

  it("demotes queue_command received/completed pairs to debug", async () => {
    const harness = makeHandler();

    await dispatch(harness, { type: "get_queue", requestId: "req-q1" });

    expect(eventsNamed("ws.queue_command.received")).toEqual([
      expect.objectContaining({ level: "debug" }),
    ]);
    expect(eventsNamed("ws.queue_command.completed")).toEqual([
      expect.objectContaining({ level: "debug" }),
    ]);
  });

  it("demotes RPC command received/completed pairs to debug", async () => {
    const harness = makeHandler();

    await dispatch(harness, {
      type: "get_commands",
      requestId: "req-c1",
    });

    expect(eventsNamed("ws.command.received")).toEqual([
      expect.objectContaining({ level: "debug" }),
    ]);
    expect(eventsNamed("ws.command.completed")).toEqual([
      expect.objectContaining({ level: "debug" }),
    ]);
  });

  it("keeps queue_command failures at warn", async () => {
    const harness = makeHandler();
    harness.sessions.getMessageQueue.mockImplementation(() => {
      throw new Error("queue unavailable");
    });

    await dispatch(harness, { type: "get_queue", requestId: "req-q-fail" });

    expect(eventsNamed("ws.queue_command.failed")).toEqual([
      expect.objectContaining({
        level: "warn",
        context: expect.objectContaining({ error: "queue unavailable" }),
      }),
    ]);
  });

  it("keeps command failures at warn", async () => {
    const harness = makeHandler();
    harness.sessions.forwardClientCommand.mockRejectedValueOnce(new Error("rpc failed"));

    await dispatch(harness, {
      type: "get_commands",
      requestId: "req-c-fail",
    });

    expect(eventsNamed("ws.command.failed")).toEqual([
      expect.objectContaining({
        level: "warn",
        context: expect.objectContaining({ error: "rpc failed" }),
      }),
    ]);
  });

  it("keeps turn_command received/completed at info", async () => {
    const harness = makeHandler();

    await dispatch(harness, {
      type: "prompt",
      message: "hello",
      requestId: "req-turn",
    });

    expect(eventsNamed("ws.turn_command.received")).toEqual([
      expect.objectContaining({ level: "info" }),
    ]);
    expect(eventsNamed("ws.turn_command.completed")).toEqual([
      expect.objectContaining({ level: "info" }),
    ]);
  });
});
