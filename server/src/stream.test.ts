/**
 * Tests for UserStreamMux — specifically the removal of the single-full-subscription
 * constraint. Multiple sessions can now be subscribed at level=full concurrently.
 */

import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "events";
import { WebSocket } from "ws";
import { UserStreamMux, type StreamContext } from "./stream.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "./types.js";

// ─── Helpers ───

function makeSession(id: string): Session {
  return {
    id,
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

/**
 * Minimal WebSocket stub that behaves like a real WS for the mux:
 * - emits "message", "close", "error", "pong"
 * - tracks sent messages via ws.send()
 * - readyState defaults to OPEN
 */
class FakeWebSocket extends EventEmitter {
  readyState: number = WebSocket.OPEN;
  sent: ServerMessage[] = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  ping(): void {
    /* no-op */
  }

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  /** Simulate receiving a client message. */
  receive(msg: ClientMessage): void {
    this.emit("message", Buffer.from(JSON.stringify(msg)));
  }

  /** Get sent messages of a specific type, optionally filtered by sessionId. */
  sentOfType(type: string, sessionId?: string): ServerMessage[] {
    return this.sent.filter(
      (m) => m.type === type && (sessionId === undefined || m.sessionId === sessionId),
    );
  }

  close(code = 1000): void {
    this.readyState = WebSocket.CLOSED;
    this.emit("close", code, Buffer.from(""));
  }
}

/**
 * Build a mock StreamContext. Sessions are pre-populated; subscribe callbacks
 * are stored so we can simulate server-side broadcasts.
 */
function createMockContext(sessions: Session[]): {
  ctx: StreamContext;
  sessionMap: Map<string, Session>;
  subscribers: Map<string, Set<(msg: ServerMessage) => void>>;
  broadcastTo: (sessionId: string, msg: ServerMessage) => void;
} {
  const sessionMap = new Map(sessions.map((s) => [s.id, s]));
  const subscribers = new Map<string, Set<(msg: ServerMessage) => void>>();

  const broadcastTo = (sessionId: string, msg: ServerMessage): void => {
    const subs = subscribers.get(sessionId);
    if (subs) {
      for (const cb of subs) cb(msg);
    }
  };

  const ctx: StreamContext = {
    storage: {
      getOwnerName: () => "test-user",
      getSession: (id: string) => sessionMap.get(id) ?? null,
    } as StreamContext["storage"],

    sessions: {
      startSession: vi.fn(async (id: string) => sessionMap.get(id)!),
      subscribe: (id: string, cb: (msg: ServerMessage) => void) => {
        if (!subscribers.has(id)) subscribers.set(id, new Set());
        subscribers.get(id)!.add(cb);
        return () => subscribers.get(id)?.delete(cb);
      },
      getActiveSession: (id: string) => sessionMap.get(id) ?? null,
      getCurrentSeq: () => 0,
      getCatchUp: () => null,
    } as unknown as StreamContext["sessions"],

    gate: {
      getPendingForUser: () => [],
    } as unknown as StreamContext["gate"],

    ensureSessionContextWindow: (s: Session) => s,
    resolveWorkspaceForSession: () => undefined as Workspace | undefined,
    handleClientMessage: vi.fn(async () => {}),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  };

  return { ctx, sessionMap, subscribers, broadcastTo };
}

/** Drain microtask queue so the mux's serialized message handler runs. */
async function drain(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
}

// ─── Tests ───

describe("UserStreamMux — multiple full subscriptions", () => {
  it("allows two sessions to be subscribed at full level simultaneously", async () => {
    const sessA = makeSession("sess-a");
    const sessB = makeSession("sess-b");
    const { ctx } = createMockContext([sessA, sessB]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    // Subscribe session A at full
    ws.receive({ type: "subscribe", sessionId: "sess-a", level: "full", requestId: "r1" });
    await drain();

    const subResultA = ws
      .sentOfType("command_result")
      .find((m) => (m as Record<string, unknown>).requestId === "r1");
    expect((subResultA as Record<string, unknown>)?.success).toBe(true);

    // Subscribe session B at full — session A should NOT be downgraded
    ws.receive({ type: "subscribe", sessionId: "sess-b", level: "full", requestId: "r2" });
    await drain();

    const subResultB = ws
      .sentOfType("command_result")
      .find((m) => (m as Record<string, unknown>).requestId === "r2");
    expect((subResultB as Record<string, unknown>)?.success).toBe(true);

    // Verify session A is still full by sending a command to it — should NOT get
    // a STREAM_ERROR_NOT_SUBSCRIBED_FULL error
    ws.receive({
      type: "get_state",
      sessionId: "sess-a",
      requestId: "r3",
    } as ClientMessage);
    await drain();

    const errors = ws.sent.filter(
      (m) => m.type === "error" && m.sessionId === "sess-a" && m.code !== undefined,
    );
    expect(errors).toHaveLength(0);
  });

  it("delivers events independently for each full subscription", async () => {
    const sessA = makeSession("sess-a");
    const sessB = makeSession("sess-b");
    const { ctx, broadcastTo } = createMockContext([sessA, sessB]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({ type: "subscribe", sessionId: "sess-a", level: "full", requestId: "r1" });
    await drain();
    ws.receive({ type: "subscribe", sessionId: "sess-b", level: "full", requestId: "r2" });
    await drain();

    // Clear sent messages to isolate broadcast events
    ws.sent.length = 0;

    // Broadcast a text_delta to session A
    broadcastTo("sess-a", { type: "text_delta", delta: "hello from A" } as ServerMessage);
    // Broadcast a text_delta to session B
    broadcastTo("sess-b", { type: "text_delta", delta: "hello from B" } as ServerMessage);

    const deltasA = ws.sentOfType("text_delta", "sess-a");
    const deltasB = ws.sentOfType("text_delta", "sess-b");

    expect(deltasA).toHaveLength(1);
    expect((deltasA[0] as Record<string, unknown>).delta).toBe("hello from A");
    expect(deltasB).toHaveLength(1);
    expect((deltasB[0] as Record<string, unknown>).delta).toBe("hello from B");
  });

  it("unsubscribing one session does not affect the other", async () => {
    const sessA = makeSession("sess-a");
    const sessB = makeSession("sess-b");
    const { ctx, broadcastTo } = createMockContext([sessA, sessB]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({ type: "subscribe", sessionId: "sess-a", level: "full", requestId: "r1" });
    await drain();
    ws.receive({ type: "subscribe", sessionId: "sess-b", level: "full", requestId: "r2" });
    await drain();

    // Unsubscribe session A
    ws.receive({ type: "unsubscribe", sessionId: "sess-a", requestId: "r3" });
    await drain();

    ws.sent.length = 0;

    // Session B should still receive events
    broadcastTo("sess-b", { type: "text_delta", delta: "still alive" } as ServerMessage);

    const deltasB = ws.sentOfType("text_delta", "sess-b");
    expect(deltasB).toHaveLength(1);
    expect((deltasB[0] as Record<string, unknown>).delta).toBe("still alive");

    // Session A should NOT receive events (unsubscribed)
    broadcastTo("sess-a", { type: "text_delta", delta: "ghost" } as ServerMessage);
    const deltasA = ws.sentOfType("text_delta", "sess-a");
    expect(deltasA).toHaveLength(0);
  });

  it("commands to a full-subscribed session succeed while another is also full", async () => {
    const sessA = makeSession("sess-a");
    const sessB = makeSession("sess-b");
    const { ctx } = createMockContext([sessA, sessB]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({ type: "subscribe", sessionId: "sess-a", level: "full" });
    await drain();
    ws.receive({ type: "subscribe", sessionId: "sess-b", level: "full" });
    await drain();

    // Send commands to both sessions — neither should get NOT_SUBSCRIBED_FULL
    ws.receive({ type: "get_state", sessionId: "sess-a", requestId: "cmd-a" } as ClientMessage);
    await drain();
    ws.receive({ type: "get_state", sessionId: "sess-b", requestId: "cmd-b" } as ClientMessage);
    await drain();

    const notSubscribedErrors = ws.sent.filter(
      (m) => m.type === "error" && m.code === "stream_not_subscribed_full",
    );
    expect(notSubscribedErrors).toHaveLength(0);

    // handleClientMessage should have been called for both
    expect(ctx.handleClientMessage).toHaveBeenCalledTimes(2);
  });

  it("notification-level subscriptions still filter non-notification events", async () => {
    const sessA = makeSession("sess-a");
    const { ctx, broadcastTo } = createMockContext([sessA]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({
      type: "subscribe",
      sessionId: "sess-a",
      level: "notifications",
      requestId: "r1",
    });
    await drain();

    ws.sent.length = 0;

    // text_delta is NOT a notification-level message — should be filtered
    broadcastTo("sess-a", { type: "text_delta", delta: "filtered" } as ServerMessage);
    expect(ws.sentOfType("text_delta")).toHaveLength(0);

    // agent_start IS a notification-level message — should be delivered
    broadcastTo("sess-a", { type: "agent_start" } as ServerMessage);
    expect(ws.sentOfType("agent_start")).toHaveLength(1);
  });

  it("commands to a notifications-only session are rejected", async () => {
    const sessA = makeSession("sess-a");
    const { ctx } = createMockContext([sessA]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({
      type: "subscribe",
      sessionId: "sess-a",
      level: "notifications",
      requestId: "r1",
    });
    await drain();

    ws.receive({ type: "get_state", sessionId: "sess-a", requestId: "cmd-a" } as ClientMessage);
    await drain();

    const errors = ws.sent.filter(
      (m) => m.type === "error" && m.code === "stream_not_subscribed_full",
    );
    expect(errors).toHaveLength(1);
  });
});
