import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";

function makeSession(id: string): Session {
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
    runtime: "host",
  };
}

function makeUser(): User {
  return {
    id: "u1",
    name: "Bob",
    token: "tok",
    createdAt: Date.now(),
  };
}

class FakeWebSocket {
  readyState = WebSocket.OPEN;
  bufferedAmount = 0;
  sent: ServerMessage[] = [];

  private handlers: {
    message: Array<(data: Buffer) => void>;
    close: Array<(code: number, reason: Buffer) => void>;
    error: Array<(err: Error) => void>;
  } = {
    message: [],
    close: [],
    error: [],
  };

  on(event: "message" | "close" | "error", handler: (...args: unknown[]) => void): void {
    if (event === "message") {
      this.handlers.message.push(handler as (data: Buffer) => void);
      return;
    }
    if (event === "close") {
      this.handlers.close.push(handler as (code: number, reason: Buffer) => void);
      return;
    }
    this.handlers.error.push(handler as (err: Error) => void);
  }

  send(data: string, _opts?: { compress?: boolean }): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  emitMessage(msg: unknown): void {
    const data = Buffer.from(JSON.stringify(msg));
    for (const handler of this.handlers.message) {
      handler(data);
    }
  }

  emitClose(code = 1000, reason = ""): void {
    this.readyState = WebSocket.CLOSED;
    const reasonBuffer = Buffer.from(reason);
    for (const handler of this.handlers.close) {
      handler(code, reasonBuffer);
    }
  }
}

interface Harness {
  mux: UserStreamMux;
  sessionCallbacks: Map<string, (msg: ServerMessage) => void>;
  unsubscribeCalls: string[];
  handleClientMessage: ReturnType<typeof vi.fn>;
  getCatchUp: ReturnType<typeof vi.fn>;
}

function makeHarness(options?: {
  sessions?: Session[];
  catchUpBySession?: Record<
    string,
    {
      events: ServerMessage[];
      currentSeq: number;
      catchUpComplete: boolean;
    }
  >;
}): Harness {
  const sessions = options?.sessions ?? [makeSession("s1", "owner")];
  const sessionsById = new Map(sessions.map((session) => [session.id, session]));
  const sessionCallbacks = new Map<string, (msg: ServerMessage) => void>();
  const unsubscribeCalls: string[] = [];

  const getCurrentSeq = vi.fn((sessionId: string) => {
    const fixture = options?.catchUpBySession?.[sessionId];
    return fixture?.currentSeq ?? 0;
  });

  const getCatchUp = vi.fn((sessionId: string, _sinceSeq: number) => {
    const session = sessionsById.get(sessionId);
    if (!session) return null;

    const fixture = options?.catchUpBySession?.[sessionId];
    if (!fixture) {
      return { events: [], currentSeq: 0, session, catchUpComplete: true };
    }
    return {
      events: fixture.events,
      currentSeq: fixture.currentSeq,
      session,
      catchUpComplete: fixture.catchUpComplete,
    };
  });

  const handleClientMessage = vi.fn(
    async (
      _session: Session,
      _msg: ClientMessage,
      send: (msg: ServerMessage) => void,
    ) => {
      send({ type: "agent_start" });
    },
  );

  const ctx: StreamContext = {
    sessions: {
      startSession: vi.fn(async (sessionId: string) => {
        const session = sessionsById.get(sessionId);
        if (!session) throw new Error(`Session not found: ${sessionId}`);
        return session;
      }),
      subscribe: vi.fn((sessionId: string, cb: (msg: ServerMessage) => void) => {
        sessionCallbacks.set(sessionId, cb);
        return () => {
          unsubscribeCalls.push(sessionId);
          if (sessionCallbacks.get(sessionId) === cb) {
            sessionCallbacks.delete(sessionId);
          }
        };
      }),
      getActiveSession: vi.fn((sessionId: string) => sessionsById.get(sessionId)),
      getCurrentSeq,
      getCatchUp,
    } as unknown as StreamContext["sessions"],
    storage: {
      getSession: vi.fn((sessionId: string) => sessionsById.get(sessionId)),
      getOwnerName: vi.fn(() => "test-host"),
    } as unknown as StreamContext["storage"],
    gate: {
      getPendingForUser: vi.fn(() => []),
      resolveDecision: vi.fn(() => true),
    } as unknown as StreamContext["gate"],
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage,
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  };

  const mux = new UserStreamMux(ctx);

  return {
    mux,
    sessionCallbacks,
    unsubscribeCalls,
    handleClientMessage,
    getCatchUp,
  };
}

async function flushQueue(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("/stream websocket behavior", () => {
  it("streams active and background session events on one socket", async () => {
    const harness = makeHarness({ sessions: [makeSession("s1"), makeSession("s2")] });
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket, harness.user);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    await flushQueue();
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s2",
      level: "notifications",
      requestId: "sub-2",
    });
    await flushQueue();

    const base = ws.sent.length;

    harness.sessionCallbacks.get("s1")?.({ type: "text_delta", delta: "active-delta" });
    harness.sessionCallbacks.get("s1")?.({ type: "agent_start" });
    harness.sessionCallbacks.get("s2")?.({ type: "text_delta", delta: "bg-delta" });
    harness.sessionCallbacks.get("s2")?.({ type: "agent_end" });

    const delivered = ws.sent.slice(base);
    expect(delivered).toContainEqual({ type: "text_delta", delta: "active-delta", sessionId: "s1" });
    expect(delivered).toContainEqual({ type: "agent_start", sessionId: "s1" });
    expect(delivered).toContainEqual({ type: "agent_end", sessionId: "s2" });
    expect(delivered.find((msg) => msg.type === "text_delta" && msg.sessionId === "s2")).toBeUndefined();
  });

  it("handles duplicate subscribe and idempotent unsubscribe", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket, harness.user);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "notifications",
      requestId: "sub-1",
    });
    await flushQueue();

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "notifications",
      requestId: "sub-2",
    });
    await flushQueue();

    expect(harness.unsubscribeCalls).toEqual(["s1"]);

    ws.emitMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-1" });
    await flushQueue();
    ws.emitMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-2" });
    await flushQueue();

    const unsubscribeResults = ws.sent.filter(
      (msg): msg is Extract<ServerMessage, { type: "rpc_result" }> =>
        msg.type === "rpc_result" && msg.command === "unsubscribe",
    );

    expect(unsubscribeResults).toHaveLength(2);
    expect(unsubscribeResults.every((msg) => msg.success)).toBe(true);
  });

  it("auto-downgrades old full subscription when a new full session is selected", async () => {
    const harness = makeHarness({ sessions: [makeSession("s1"), makeSession("s2")] });
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket, harness.user);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    await flushQueue();
    ws.emitMessage({ type: "subscribe", sessionId: "s2", level: "full", requestId: "sub-2" });
    await flushQueue();

    const beforeOldFullPrompt = ws.sent.length;
    ws.emitMessage({ type: "prompt", sessionId: "s1", message: "should fail" });
    await flushQueue();

    const oldFullError = ws.sent.slice(beforeOldFullPrompt).find((msg) => msg.type === "error");
    expect(oldFullError?.type).toBe("error");
    if (oldFullError?.type === "error") {
      expect(oldFullError.error).toContain("not subscribed at level=full");
    }

    const beforeNewFullPrompt = ws.sent.length;
    ws.emitMessage({ type: "prompt", sessionId: "s2", message: "should pass" });
    await flushQueue();

    expect(harness.handleClientMessage).toHaveBeenCalledTimes(1);
    expect(
      ws.sent
        .slice(beforeNewFullPrompt)
        .find((msg) => msg.type === "agent_start" && msg.sessionId === "s2"),
    ).toBeTruthy();
  });

  it("drops high-volume deltas under backpressure but preserves lifecycle events", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket, harness.user);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    await flushQueue();

    const callback = harness.sessionCallbacks.get("s1");
    expect(callback).toBeTruthy();

    ws.bufferedAmount = 70 * 1024;
    const base = ws.sent.length;

    callback?.({ type: "text_delta", delta: "x" });
    callback?.({ type: "thinking_delta", delta: "y" });
    callback?.({ type: "tool_output", output: "z" });
    callback?.({
      type: "permission_request",
      id: "perm-1",
      sessionId: "s1",
      tool: "bash",
      input: { command: "rm -rf /" },
      displaySummary: "danger",
      risk: "high",
      reason: "needs approval",
      timeoutAt: Date.now() + 60_000,
      resolutionOptions: {
        allowSession: true,
        allowAlways: true,
        denyAlways: true,
      },
    });
    callback?.({ type: "agent_start" });

    const delivered = ws.sent.slice(base);
    expect(delivered.map((msg) => msg.type)).toEqual(["permission_request", "agent_start"]);
  });

  it("reconnect + re-subscribe with sinceSeq is deterministic", async () => {
    const catchUpEvents: ServerMessage[] = [
      { type: "agent_start", seq: 6 },
      { type: "agent_end", seq: 7 },
    ];

    const harness = makeHarness({
      sessions: [makeSession("s1")],
      catchUpBySession: {
        s1: {
          events: catchUpEvents,
          currentSeq: 7,
          catchUpComplete: true,
        },
      },
    });

    const connect = async (): Promise<FakeWebSocket> => {
      const ws = new FakeWebSocket();
      await harness.mux.handleWebSocket(ws as unknown as WebSocket, harness.user);
      return ws;
    };

    const ws1 = await connect();
    ws1.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 5,
      requestId: "sub-1",
    });
    await flushQueue();
    ws1.emitClose();

    const ws2 = await connect();
    ws2.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 5,
      requestId: "sub-1",
    });
    await flushQueue();

    const normalize = (messages: ServerMessage[]) =>
      messages.map((msg) => {
        if (msg.type === "rpc_result") {
          return {
            type: msg.type,
            command: msg.command,
            requestId: msg.requestId,
            success: msg.success,
            sessionId: msg.sessionId,
            data: msg.data,
          };
        }
        if (msg.type === "state") {
          return {
            type: msg.type,
            sessionId: msg.sessionId,
            status: msg.session.status,
          };
        }
        if (msg.type === "connected") {
          return {
            type: msg.type,
            sessionId: msg.sessionId,
            currentSeq: msg.currentSeq,
          };
        }
        return {
          type: msg.type,
          sessionId: msg.sessionId,
          seq: msg.seq,
        };
      });

    expect(normalize(ws2.sent)).toEqual(normalize(ws1.sent));

    expect(harness.getCatchUp).toHaveBeenCalledWith("s1", 5);
  });
});
