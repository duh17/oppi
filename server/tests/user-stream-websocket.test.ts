import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";
import { UserStreamMux, startServerPing, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { messagesOfType, requireMessageOfType } from "./harness/ws-harness.js";
import { flushMicrotasks } from "./harness/async.js";

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

  emitClientMessage(msg: ClientMessage): void {
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
  ensureSessionContextWindow?: (session: Session) => Session;
}): Harness {
  const sessions = options?.sessions ?? [makeSession("s1")];
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
    async (_session: Session, _msg: ClientMessage, send: (msg: ServerMessage) => void) => {
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
    ensureSessionContextWindow:
      options?.ensureSessionContextWindow ?? ((session: Session) => session),
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
  await flushMicrotasks(3);
}

describe("/stream websocket behavior", () => {
  it("streams active and background session events on one socket", async () => {
    const harness = makeHarness({ sessions: [makeSession("s1"), makeSession("s2")] });
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await flushQueue();
    ws.emitClientMessage({
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
    expect(delivered).toContainEqual({
      type: "text_delta",
      delta: "active-delta",
      sessionId: "s1",
    });
    expect(delivered).toContainEqual({ type: "agent_start", sessionId: "s1" });
    expect(delivered).toContainEqual({ type: "agent_end", sessionId: "s2" });
    expect(
      delivered.find((msg) => msg.type === "text_delta" && msg.sessionId === "s2"),
    ).toBeUndefined();
  });

  it("normalizes stale context window on streamed state events", async () => {
    const staleSession: Session = {
      ...makeSession("s1"),
      model: "gpt-5.3-codex/gpt-5.3-codex",
      contextWindow: 200000,
    };

    const harness = makeHarness({
      sessions: [staleSession],
      ensureSessionContextWindow: (session: Session) => {
        if (session.model?.includes("gpt-5.3-codex") && session.contextWindow === 200000) {
          return { ...session, contextWindow: 272000 };
        }
        return session;
      },
    });
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await flushQueue();

    const callback = harness.sessionCallbacks.get("s1");
    expect(callback).toBeTruthy();
    callback?.({ type: "state", session: staleSession });

    const latestState = [...ws.sent].reverse().find((msg) => msg.type === "state");
    expect(latestState?.type).toBe("state");
    if (latestState?.type === "state") {
      expect(latestState.session.contextWindow).toBe(272000);
    }
  });

  it("handles duplicate subscribe and idempotent unsubscribe", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "notifications",
      requestId: "sub-1",
    });
    await flushQueue();

    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "notifications",
      requestId: "sub-2",
    });
    await flushQueue();

    expect(harness.unsubscribeCalls).toEqual(["s1"]);

    ws.emitClientMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-1" });
    await flushQueue();
    ws.emitClientMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-2" });
    await flushQueue();

    const unsubscribeResults = messagesOfType(ws.sent, "command_result").filter(
      (msg) => msg.command === "unsubscribe",
    );

    expect(unsubscribeResults).toHaveLength(2);
    expect(unsubscribeResults.every((msg) => msg.success)).toBe(true);
  });

  it("auto-downgrades old full subscription when a new full session is selected", async () => {
    const harness = makeHarness({ sessions: [makeSession("s1"), makeSession("s2")] });
    const ws = new FakeWebSocket();

    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await flushQueue();
    ws.emitClientMessage({
      type: "subscribe",
      sessionId: "s2",
      level: "full",
      requestId: "sub-2",
    });
    await flushQueue();

    const beforeOldFullPrompt = ws.sent.length;
    ws.emitClientMessage({ type: "prompt", sessionId: "s1", message: "should fail" });
    await flushQueue();

    const oldFullError = requireMessageOfType(ws.sent.slice(beforeOldFullPrompt), "error");
    expect(oldFullError.error).toContain("not subscribed at level=full");

    const beforeNewFullPrompt = ws.sent.length;
    ws.emitClientMessage({ type: "prompt", sessionId: "s2", message: "should pass" });
    await flushQueue();

    expect(harness.handleClientMessage).toHaveBeenCalledTimes(1);
    expect(
      ws.sent
        .slice(beforeNewFullPrompt)
        .find((msg) => msg.type === "agent_start" && msg.sessionId === "s2"),
    ).toBeTruthy();
  });

  // Backpressure dropping was intentionally removed — it was dropping tool output
  // and thinking deltas that the client needs. All events are delivered unconditionally.

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
      await harness.mux.handleWebSocket(ws as unknown as WebSocket);
      return ws;
    };

    const ws1 = await connect();
    ws1.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 5,
      requestId: "sub-1",
    });
    await flushQueue();
    ws1.emitClose();

    const ws2 = await connect();
    ws2.emitClientMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 5,
      requestId: "sub-1",
    });
    await flushQueue();

    const normalize = (messages: ServerMessage[]) =>
      messages.map((msg) => {
        if (msg.type === "command_result") {
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

describe("server-side ping keepalive", () => {
  it("terminates connection when pong is not received", async () => {
    const pings: Array<() => void> = [];
    let terminated = false;

    const fakeWs = {
      on: vi.fn((event: string, handler: () => void) => {
        // Don't register a pong handler — simulates no pong
        if (event === "pong") {
          // Intentionally do NOT call handler — pong never fires
        }
      }),
      ping: vi.fn(() => {
        // No-op — client doesn't respond
      }),
      terminate: vi.fn(() => {
        terminated = true;
      }),
    };

    vi.useFakeTimers();
    try {
      const stop = startServerPing(fakeWs as unknown as WebSocket, "test", 100);

      // First interval tick: alive is true → set alive=false, send ping
      vi.advanceTimersByTime(100);
      expect(fakeWs.ping).toHaveBeenCalledTimes(1);
      expect(terminated).toBe(false);

      // Second tick: alive is still false (no pong) → terminate
      vi.advanceTimersByTime(100);
      expect(terminated).toBe(true);
      expect(fakeWs.terminate).toHaveBeenCalledTimes(1);

      stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it("stays alive when pong is received", async () => {
    let pongHandler: (() => void) | null = null;
    let terminated = false;

    const fakeWs = {
      on: vi.fn((event: string, handler: () => void) => {
        if (event === "pong") {
          pongHandler = handler;
        }
      }),
      ping: vi.fn(),
      terminate: vi.fn(() => {
        terminated = true;
      }),
    };

    vi.useFakeTimers();
    try {
      const stop = startServerPing(fakeWs as unknown as WebSocket, "test", 100);

      // Tick 1: send ping
      vi.advanceTimersByTime(100);
      expect(fakeWs.ping).toHaveBeenCalledTimes(1);

      // Simulate pong received
      pongHandler?.();

      // Tick 2: alive was reset → send another ping (not terminate)
      vi.advanceTimersByTime(100);
      expect(fakeWs.ping).toHaveBeenCalledTimes(2);
      expect(terminated).toBe(false);

      // Pong again
      pongHandler?.();

      // Tick 3: still alive
      vi.advanceTimersByTime(100);
      expect(fakeWs.ping).toHaveBeenCalledTimes(3);
      expect(terminated).toBe(false);

      stop();
    } finally {
      vi.useRealTimers();
    }
  });
});
