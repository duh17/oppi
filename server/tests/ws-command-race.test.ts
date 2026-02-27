/**
 * WebSocket command/state race matrix tests.
 *
 * Integration-level tests using the UserStreamMux with FakeWebSocket
 * to verify ordering, subscription state, and no phantom/duplicate events
 * under various race conditions.
 *
 * Race matrix coverage:
 *   A) Queue ordering on a single socket
 *   B) Command/result correlation (partially — see ws-message-handler.test.ts)
 *   C) Catch-up boundaries (sinceSeq)
 *   D) State transition interleavings
 */

import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "../src/types.js";

// ─── Test Infrastructure ───

function makeSession(id: string, overrides?: Partial<Session>): Session {
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
    ...overrides,
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

  ping(): void {
    // no-op for tests
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
  getCurrentSeq: ReturnType<typeof vi.fn>;
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
  const sessions = options?.sessions ?? [makeSession("s1")];
  const sessionsById = new Map(sessions.map((s) => [s.id, s]));
  const sessionCallbacks = new Map<string, (msg: ServerMessage) => void>();
  const unsubscribeCalls: string[] = [];

  const getCurrentSeq = vi.fn((sessionId: string) => {
    const fixture = options?.catchUpBySession?.[sessionId];
    return fixture?.currentSeq ?? 0;
  });

  const getCatchUp = vi.fn((sessionId: string, sinceSeq: number) => {
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
    async (_session: Session, msg: ClientMessage, send: (msg: ServerMessage) => void) => {
      // Default: echo back a command_result for prompt
      if (msg.type === "prompt") {
        send({ type: "command_result", command: "prompt", requestId: msg.requestId, success: true });
      }
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
    getCurrentSeq,
  };
}

async function flushQueue(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

/** Wait for the promise queue to fully drain (multiple ticks). */
async function drainQueue(ticks = 5): Promise<void> {
  for (let i = 0; i < ticks; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function findCommandResults(
  messages: ServerMessage[],
  command?: string,
): Array<Extract<ServerMessage, { type: "command_result" }>> {
  return messages.filter(
    (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
      msg.type === "command_result" && (command === undefined || msg.command === command),
  );
}

function findByType(messages: ServerMessage[], type: string): ServerMessage[] {
  return messages.filter((msg) => msg.type === type);
}

// ─── A) Queue Ordering on a Single Socket ───

describe("A: queue ordering on a single socket", () => {
  it("subscribe(full) -> prompt in same tick: prompt accepted only after subscribe success", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    // Fire subscribe + prompt in the same tick (no await between)
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    ws.emitMessage({
      type: "prompt",
      sessionId: "s1",
      message: "hello",
      requestId: "prompt-1",
    });

    await drainQueue();

    // Subscribe command_result must appear before prompt result
    const subResult = ws.sent.find(
      (msg) =>
        msg.type === "command_result" &&
        msg.command === "subscribe" &&
        msg.requestId === "sub-1",
    );
    const promptResult = ws.sent.find(
      (msg) =>
        msg.type === "command_result" &&
        msg.command === "prompt" &&
        msg.requestId === "prompt-1",
    );

    expect(subResult).toBeDefined();
    expect(subResult!.success).toBe(true);
    expect(promptResult).toBeDefined();
    expect(promptResult!.success).toBe(true);

    // Subscribe result index must be before prompt result index
    const subIdx = ws.sent.indexOf(subResult!);
    const promptIdx = ws.sent.indexOf(promptResult!);
    expect(subIdx).toBeLessThan(promptIdx);

    // handleClientMessage should have been called (prompt was accepted)
    expect(harness.handleClientMessage).toHaveBeenCalledTimes(1);
  });

  it("unsubscribe -> prompt in same tick: prompt rejected with not-subscribed error", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    // First subscribe so we have a subscription to unsubscribe
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await drainQueue();

    const baseline = ws.sent.length;

    // Now unsubscribe + prompt in the same tick
    ws.emitMessage({
      type: "unsubscribe",
      sessionId: "s1",
      requestId: "unsub-1",
    });
    ws.emitMessage({
      type: "prompt",
      sessionId: "s1",
      message: "should fail",
      requestId: "prompt-1",
    });

    await drainQueue();

    const newMessages = ws.sent.slice(baseline);

    // Unsubscribe result should succeed
    const unsubResult = newMessages.find(
      (msg) =>
        msg.type === "command_result" &&
        msg.command === "unsubscribe" &&
        msg.requestId === "unsub-1",
    );
    expect(unsubResult).toBeDefined();
    expect(unsubResult!.success).toBe(true);

    // Prompt should be rejected with not-subscribed error
    const promptError = newMessages.find(
      (msg) => msg.type === "error" && msg.sessionId === "s1",
    );
    expect(promptError).toBeDefined();
    if (promptError?.type === "error") {
      expect(promptError.error).toContain("not subscribed");
    }

    // handleClientMessage should NOT have been called for the rejected prompt
    // It was called once during initial subscribe (startSession flow), but not for the prompt
    expect(harness.handleClientMessage).not.toHaveBeenCalled();
  });

  it("subscribe(A full) -> subscribe(B full) demotes A to notifications", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1"), makeSession("s2")],
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    // Subscribe to A as full
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-a",
    });
    await drainQueue();

    // Subscribe to B as full (should demote A)
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s2",
      level: "full",
      requestId: "sub-b",
    });
    await drainQueue();

    const baseline = ws.sent.length;

    // Now try to send a prompt to A — should be rejected (demoted to notifications)
    ws.emitMessage({
      type: "prompt",
      sessionId: "s1",
      message: "demoted session",
      requestId: "prompt-a",
    });
    await drainQueue();

    const afterPromptA = ws.sent.slice(baseline);
    const errorA = afterPromptA.find(
      (msg) => msg.type === "error" && msg.sessionId === "s1",
    );
    expect(errorA).toBeDefined();
    if (errorA?.type === "error") {
      expect(errorA.error).toContain("not subscribed at level=full");
    }

    const baseline2 = ws.sent.length;

    // Prompt to B should succeed
    ws.emitMessage({
      type: "prompt",
      sessionId: "s2",
      message: "active session",
      requestId: "prompt-b",
    });
    await drainQueue();

    const afterPromptB = ws.sent.slice(baseline2);
    const promptResult = afterPromptB.find(
      (msg) =>
        msg.type === "command_result" &&
        msg.command === "prompt" &&
        msg.requestId === "prompt-b",
    );
    expect(promptResult).toBeDefined();
    expect(promptResult!.success).toBe(true);
  });

  it("subscribe(A full) -> subscribe(B full): A still receives notification-level events", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1"), makeSession("s2")],
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-a" });
    await drainQueue();
    ws.emitMessage({ type: "subscribe", sessionId: "s2", level: "full", requestId: "sub-b" });
    await drainQueue();

    const baseline = ws.sent.length;

    // Emit notification-level event (agent_end) for demoted session A
    harness.sessionCallbacks.get("s1")?.({ type: "agent_end" });
    // Emit streaming event (text_delta) for demoted session A — should be filtered
    harness.sessionCallbacks.get("s1")?.({ type: "text_delta", delta: "filtered" });

    const newMessages = ws.sent.slice(baseline);

    // agent_end (notification level) should be delivered
    expect(newMessages.find((msg) => msg.type === "agent_end" && msg.sessionId === "s1")).toBeDefined();
    // text_delta (full level) should be filtered out
    expect(
      newMessages.find((msg) => msg.type === "text_delta" && msg.sessionId === "s1"),
    ).toBeUndefined();
  });
});

// ─── C) Catch-up Boundaries (sinceSeq) ───

describe("C: catch-up boundaries (sinceSeq)", () => {
  it("stale/too-old sinceSeq returns catchUpComplete:false and still delivers current state", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1")],
      catchUpBySession: {
        s1: {
          events: [], // No events returned — ring can't serve this range
          currentSeq: 100,
          catchUpComplete: false,
        },
      },
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 5, // Too old — ring has moved past this
      requestId: "sub-stale",
    });
    await drainQueue();

    // Should still get a state event (current session state)
    const stateMsg = ws.sent.find(
      (msg) => msg.type === "state" && msg.sessionId === "s1",
    );
    expect(stateMsg).toBeDefined();

    // command_result should indicate catchUpComplete:false
    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" &&
        msg.command === "subscribe" &&
        msg.requestId === "sub-stale",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(true);
    expect((result!.data as { catchUpComplete: boolean }).catchUpComplete).toBe(false);
  });

  it("exact boundary sinceSeq=currentSeq yields empty replay with catchUpComplete:true", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1")],
      catchUpBySession: {
        s1: {
          events: [], // Empty — nothing to replay
          currentSeq: 42,
          catchUpComplete: true,
        },
      },
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 42,
      requestId: "sub-exact",
    });
    await drainQueue();

    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" &&
        msg.command === "subscribe" &&
        msg.requestId === "sub-exact",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(true);
    expect((result!.data as { catchUpComplete: boolean }).catchUpComplete).toBe(true);

    // No replay events should have been sent (only connected + state + command_result)
    const nonMetaMessages = ws.sent.filter(
      (msg) =>
        msg.sessionId === "s1" &&
        msg.type !== "connected" &&
        msg.type !== "state" &&
        msg.type !== "command_result" &&
        msg.type !== "stream_connected",
    );
    expect(nonMetaMessages).toHaveLength(0);
  });

  it("catch-up delivers replay events between state and command_result", async () => {
    const catchUpEvents: ServerMessage[] = [
      { type: "agent_start", seq: 11 },
      { type: "text_delta", delta: "replayed", seq: 12 },
      { type: "agent_end", seq: 13 },
    ];

    const harness = makeHarness({
      sessions: [makeSession("s1")],
      catchUpBySession: {
        s1: {
          events: catchUpEvents,
          currentSeq: 13,
          catchUpComplete: true,
        },
      },
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 10,
      requestId: "sub-replay",
    });
    await drainQueue();

    // Find ordering: state should come before replay events, which come before command_result
    const s1Messages = ws.sent.filter((msg) => msg.sessionId === "s1");
    const stateIdx = s1Messages.findIndex((msg) => msg.type === "state");
    const agentStartIdx = s1Messages.findIndex((msg) => msg.type === "agent_start");
    const agentEndIdx = s1Messages.findIndex((msg) => msg.type === "agent_end");
    const resultIdx = s1Messages.findIndex(
      (msg) => msg.type === "command_result" && msg.command === "subscribe",
    );

    expect(stateIdx).toBeGreaterThanOrEqual(0);
    expect(agentStartIdx).toBeGreaterThanOrEqual(0);
    expect(agentEndIdx).toBeGreaterThanOrEqual(0);
    expect(resultIdx).toBeGreaterThanOrEqual(0);

    // Order: state < replay events < command_result
    expect(stateIdx).toBeLessThan(agentStartIdx);
    expect(agentStartIdx).toBeLessThan(agentEndIdx);
    expect(agentEndIdx).toBeLessThan(resultIdx);
  });

  it("invalid sinceSeq (negative) returns command_result error", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: -5,
      requestId: "sub-neg",
    });
    await drainQueue();

    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" &&
        msg.requestId === "sub-neg",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(false);
    expect(result!.error).toContain("sinceSeq");
  });

  it("invalid sinceSeq (non-integer float) returns command_result error", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 3.7,
      requestId: "sub-float",
    });
    await drainQueue();

    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" &&
        msg.requestId === "sub-float",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(false);
    expect(result!.error).toContain("sinceSeq");
  });
});

// ─── D) State Transition Interleavings ───

describe("D: state transition interleavings", () => {
  it("rapid subscribe/unsubscribe churn leaves exactly one effective subscription state", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    // Rapid churn: subscribe → unsubscribe → subscribe → unsubscribe → subscribe
    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    ws.emitMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-1" });
    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-2" });
    ws.emitMessage({ type: "unsubscribe", sessionId: "s1", requestId: "unsub-2" });
    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-3" });

    await drainQueue(10);

    // Should have exactly 3 subscribe results and 2 unsubscribe results
    const subResults = findCommandResults(ws.sent, "subscribe");
    const unsubResults = findCommandResults(ws.sent, "unsubscribe");
    expect(subResults).toHaveLength(3);
    expect(unsubResults).toHaveLength(2);
    expect(subResults.every((r) => r.success)).toBe(true);
    expect(unsubResults.every((r) => r.success)).toBe(true);

    // Final state: subscribed to s1. Sending an event should be delivered.
    const baseline = ws.sent.length;
    harness.sessionCallbacks.get("s1")?.({ type: "agent_start" });
    const newMessages = ws.sent.slice(baseline);
    expect(newMessages).toHaveLength(1);
    expect(newMessages[0]!.type).toBe("agent_start");
    expect(newMessages[0]!.sessionId).toBe("s1");
  });

  it("reconnect during active session receives deterministic bootstrap order", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1", { status: "busy" })],
      catchUpBySession: {
        s1: {
          events: [{ type: "agent_start", seq: 1 }],
          currentSeq: 1,
          catchUpComplete: true,
        },
      },
    });

    // First connection
    const ws1 = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws1 as unknown as WebSocket);

    ws1.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 0,
      requestId: "sub-1",
    });
    await drainQueue();

    // Verify bootstrap order: stream_connected → connected → state → catch-up → command_result
    const types1 = ws1.sent.map((msg) => msg.type);

    expect(types1[0]).toBe("stream_connected");
    const connectedIdx = types1.indexOf("connected");
    const stateIdx = types1.indexOf("state");
    const subResultIdx = types1.findIndex(
      (t, i) => t === "command_result" && ws1.sent[i]!.command === "subscribe",
    );

    expect(connectedIdx).toBeGreaterThan(0);
    expect(stateIdx).toBeGreaterThan(connectedIdx);
    expect(subResultIdx).toBeGreaterThan(stateIdx);

    // Disconnect
    ws1.emitClose();

    // Second connection — same bootstrap order
    const ws2 = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws2 as unknown as WebSocket);

    ws2.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      sinceSeq: 0,
      requestId: "sub-1",
    });
    await drainQueue();

    const types2 = ws2.sent.map((msg) => msg.type);
    expect(types2[0]).toBe("stream_connected");
    const connectedIdx2 = types2.indexOf("connected");
    const stateIdx2 = types2.indexOf("state");
    const subResultIdx2 = types2.findIndex(
      (t, i) => t === "command_result" && ws2.sent[i]!.command === "subscribe",
    );

    expect(connectedIdx2).toBeGreaterThan(0);
    expect(stateIdx2).toBeGreaterThan(connectedIdx2);
    expect(subResultIdx2).toBeGreaterThan(stateIdx2);
  });

  it("no duplicate events when subscription callback fires during subscribe flow", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await drainQueue();

    const baseline = ws.sent.length;

    // Emit exactly one event from the session callback
    harness.sessionCallbacks.get("s1")?.({ type: "agent_start" });

    const newMessages = ws.sent.slice(baseline);

    // Should receive exactly one agent_start — no duplicates
    const agentStarts = newMessages.filter(
      (msg) => msg.type === "agent_start" && msg.sessionId === "s1",
    );
    expect(agentStarts).toHaveLength(1);
  });

  it("unsubscribe during active events stops delivery immediately", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "s1",
      level: "full",
      requestId: "sub-1",
    });
    await drainQueue();

    // Save the callback before unsubscribe clears it
    const callback = harness.sessionCallbacks.get("s1");
    expect(callback).toBeDefined();

    ws.emitMessage({
      type: "unsubscribe",
      sessionId: "s1",
      requestId: "unsub-1",
    });
    await drainQueue();

    const baseline = ws.sent.length;

    // Try to emit via the old callback — should be no-op
    callback?.({ type: "text_delta", delta: "after-unsub" });

    const newMessages = ws.sent.slice(baseline);
    expect(newMessages).toHaveLength(0);
  });

  it("close while subscribed cleans up all subscriptions", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1"), makeSession("s2")],
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    await drainQueue();
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s2",
      level: "notifications",
      requestId: "sub-2",
    });
    await drainQueue();

    // Verify both sessions have callbacks
    expect(harness.sessionCallbacks.has("s1")).toBe(true);
    expect(harness.sessionCallbacks.has("s2")).toBe(true);

    // Close the connection
    ws.emitClose();

    // Both subscriptions should be cleaned up
    expect(harness.unsubscribeCalls).toContain("s1");
    expect(harness.unsubscribeCalls).toContain("s2");
  });
});

// ─── Edge Cases ───

describe("edge cases: multi-session ordering", () => {
  it("events for different sessions are tagged with correct sessionId", async () => {
    const harness = makeHarness({
      sessions: [makeSession("s1"), makeSession("s2")],
    });
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({ type: "subscribe", sessionId: "s1", level: "full", requestId: "sub-1" });
    await drainQueue();
    ws.emitMessage({
      type: "subscribe",
      sessionId: "s2",
      level: "notifications",
      requestId: "sub-2",
    });
    await drainQueue();

    const baseline = ws.sent.length;

    // Emit events from both sessions
    harness.sessionCallbacks.get("s1")?.({ type: "text_delta", delta: "from-s1" });
    harness.sessionCallbacks.get("s2")?.({ type: "agent_end" });

    const newMessages = ws.sent.slice(baseline);

    const s1Events = newMessages.filter((msg) => msg.sessionId === "s1");
    const s2Events = newMessages.filter((msg) => msg.sessionId === "s2");

    expect(s1Events).toHaveLength(1);
    expect(s1Events[0]!.type).toBe("text_delta");

    expect(s2Events).toHaveLength(1);
    expect(s2Events[0]!.type).toBe("agent_end");
  });

  it("subscribe to nonexistent session returns error without crashing", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "subscribe",
      sessionId: "nonexistent",
      level: "full",
      requestId: "sub-missing",
    });
    await drainQueue();

    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" && msg.requestId === "sub-missing",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(false);
    expect(result!.error).toContain("not found");
  });

  it("unsubscribe from never-subscribed session is idempotent", async () => {
    const harness = makeHarness();
    const ws = new FakeWebSocket();
    await harness.mux.handleWebSocket(ws as unknown as WebSocket);

    ws.emitMessage({
      type: "unsubscribe",
      sessionId: "s1",
      requestId: "unsub-never",
    });
    await drainQueue();

    // Should get a success result (idempotent) without crash
    const result = ws.sent.find(
      (msg): msg is Extract<ServerMessage, { type: "command_result" }> =>
        msg.type === "command_result" && msg.requestId === "unsub-never",
    );
    expect(result).toBeDefined();
    expect(result!.success).toBe(true);
  });
});
