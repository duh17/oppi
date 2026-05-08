/**
 * Tests for UserStreamMux — specifically the removal of the single-full-subscription
 * constraint. Multiple sessions can now be subscribed at level=full concurrently.
 */

import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "events";
import { WebSocket } from "ws";
import {
  BoundSessionStreamMux,
  SessionAudioStreamMux,
  UserStreamMux,
  WorkspaceStreamMux,
  type StreamContext,
} from "./stream.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "./types.js";

// ─── Helpers ───

function makeSession(id: string, workspaceId?: string): Session {
  return {
    id,
    workspaceId,
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
    this.emit("message", Buffer.from(JSON.stringify(msg)), false);
  }

  receiveBinary(data: Buffer): void {
    this.emit("message", data, true);
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
      getPendingAskMessage: () => undefined,
      getPendingUIRequestMessages: () => [],
    } as unknown as StreamContext["sessions"],

    gate: {
      getPendingForUser: () => [],
    } as unknown as StreamContext["gate"],

    ensureSessionContextWindow: (s: Session) => s,
    resolveWorkspaceForSession: () => undefined as Workspace | undefined,
    handleClientMessage: vi.fn(async () => {}),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
    createDictationManager: undefined,
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
  it("routes reload commands through the full subscription harness", async () => {
    const session = makeSession("sess-reload");
    const { ctx } = createMockContext([session]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    expect(ctx.trackConnection).toHaveBeenCalledWith(ws, { userBroadcast: true });

    ws.receive({ type: "subscribe", sessionId: session.id, level: "full", requestId: "sub-1" });
    await drain();

    ws.receive({ type: "reload", sessionId: session.id, requestId: "reload-1" } as ClientMessage);
    await drain();

    expect(ctx.handleClientMessage).toHaveBeenCalledWith(
      expect.objectContaining({ id: session.id }),
      expect.objectContaining({ type: "reload", requestId: "reload-1" }),
      expect.any(Function),
      expect.any(Object),
    );
  });

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

  it("does not downgrade a full subscription when a stale notification subscribe arrives", async () => {
    const sessA = makeSession("sess-a");
    const { ctx } = createMockContext([sessA]);

    const mux = new UserStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);
    await drain();

    ws.receive({ type: "subscribe", sessionId: "sess-a", level: "full", requestId: "full" });
    await drain();
    ws.receive({
      type: "subscribe",
      sessionId: "sess-a",
      level: "notifications",
      requestId: "stale-notification",
    });
    await drain();

    const notificationResult = ws
      .sentOfType("command_result")
      .find((m) => (m as Record<string, unknown>).requestId === "stale-notification") as
      | (ServerMessage & { data?: Record<string, unknown> })
      | undefined;
    expect(notificationResult?.success).toBe(true);
    expect(notificationResult?.data?.level).toBe("full");
    expect(notificationResult?.data?.retainedFullSubscription).toBe(true);

    ws.receive({ type: "get_state", sessionId: "sess-a", requestId: "cmd-a" } as ClientMessage);
    await drain();

    const notSubscribedErrors = ws.sent.filter(
      (m) => m.type === "error" && m.code === "stream_not_subscribed_full",
    );
    expect(notSubscribedErrors).toHaveLength(0);
    expect(ctx.handleClientMessage).toHaveBeenCalledTimes(1);
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

describe("BoundSessionStreamMux", () => {
  it("starts the bound session and accepts commands without subscribe", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    expect(ws.sentOfType("stream_connected")).toHaveLength(1);
    expect(ws.sentOfType("connected", "sess-bound")).toHaveLength(1);
    expect(ws.sentOfType("state", "sess-bound")).toHaveLength(1);
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws, { userBroadcast: false });
    expect(ctx.sessions.startSession).toHaveBeenCalledWith("sess-bound", undefined);

    ws.sent.length = 0;
    expect(
      mux.sendToSession("sess-bound", {
        type: "permission_request",
        id: "p-bound",
        sessionId: "sess-bound",
        tool: "bash",
        input: {},
        displaySummary: "approval",
        reason: "test",
        timeoutAt: Date.now() + 1000,
      }),
    ).toBe(1);
    expect(ws.sentOfType("permission_request", "sess-bound")).toHaveLength(1);

    ws.receive({ type: "reload", sessionId: "sess-bound", requestId: "reload-1" } as ClientMessage);
    await drain();

    expect(ctx.handleClientMessage).toHaveBeenCalledWith(
      expect.objectContaining({ id: "sess-bound" }),
      expect.objectContaining({ type: "reload", sessionId: "sess-bound", requestId: "reload-1" }),
      expect.any(Function),
      expect.any(Object),
    );
    expect(ws.sentOfType("command_result").filter((m) => m.command === "subscribe")).toHaveLength(
      0,
    );
  });

  it("includes ASR availability in the split session bootstrap", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    ctx.dictationManager = {} as NonNullable<StreamContext["dictationManager"]>;

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    expect(ws.sentOfType("stream_connected")[0]).toMatchObject({ asrAvailable: true });
  });

  it("accepts permission responses while session startup is waiting", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    let resolveStart: ((session: Session) => void) | undefined;
    vi.mocked(ctx.sessions.startSession).mockImplementation(
      () =>
        new Promise<Session>((resolve) => {
          resolveStart = resolve;
        }),
    );
    const resolveDecision = vi.fn(() => true);
    ctx.gate = {
      getPendingForUser: () => [],
      resolveDecision,
    } as unknown as StreamContext["gate"];

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    const connect = mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.receive({
      type: "permission_response",
      id: "perm-startup",
      action: "allow",
      requestId: "perm-1",
    });
    await drain();

    expect(resolveDecision).toHaveBeenCalledWith("perm-startup", "allow", "once", undefined);
    const result = ws
      .sentOfType("command_result", "sess-bound")
      .find((m) => (m as Record<string, unknown>).requestId === "perm-1");
    expect(result?.success).toBe(true);

    expect(resolveStart).toBeDefined();
    resolveStart?.(session);
    await connect;

    expect(ws.sentOfType("connected", "sess-bound")).toHaveLength(1);
  });

  it("cleans up when the bound session socket closes during startup", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    let resolveStart: ((session: Session) => void) | undefined;
    vi.mocked(ctx.sessions.startSession).mockImplementation(
      () =>
        new Promise<Session>((resolve) => {
          resolveStart = resolve;
        }),
    );

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    const connect = mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.close(1000);
    await drain();

    expect(ctx.untrackConnection).toHaveBeenCalledWith(ws);
    expect(resolveStart).toBeDefined();
    resolveStart?.(session);
    await connect;

    expect(ws.sentOfType("connected", "sess-bound")).toHaveLength(0);
  });

  it("rejects subscribe messages because the URL is the subscription", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.receive({ type: "subscribe", sessionId: "sess-bound", level: "full", requestId: "sub-1" });
    await drain();

    const result = ws
      .sentOfType("command_result")
      .find((m) => (m as Record<string, unknown>).requestId === "sub-1");
    expect(result?.success).toBe(false);
    expect((result as { error?: string } | undefined)?.error).toContain("not supported");
  });

  it("rejects commands targeting a different session", async () => {
    const session = makeSession("sess-bound", "w1");
    const other = makeSession("sess-other", "w1");
    const { ctx } = createMockContext([session, other]);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.receive({
      type: "reload",
      sessionId: "sess-other",
      requestId: "reload-other",
    } as ClientMessage);
    await drain();

    expect(ctx.handleClientMessage).not.toHaveBeenCalled();
    const result = ws
      .sentOfType("command_result", "sess-other")
      .find((m) => (m as Record<string, unknown>).requestId === "reload-other");
    expect(result?.success).toBe(false);
  });

  it("unsubscribes from session manager when the socket closes", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx, broadcastTo } = createMockContext([session]);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.sent.length = 0;
    ws.close(1000);
    broadcastTo("sess-bound", { type: "text_delta", delta: "after close" } as ServerMessage);

    expect(ws.sentOfType("text_delta", "sess-bound")).toHaveLength(0);
    expect(ctx.untrackConnection).toHaveBeenCalled();
  });
});

describe("WorkspaceStreamMux", () => {
  function createWorkspaceContext(): Pick<
    StreamContext,
    "storage" | "metrics" | "trackConnection" | "untrackConnection"
  > {
    const workspaces = new Map<string, Workspace>([
      ["w1", { id: "w1", name: "One", path: "/tmp/one" } as Workspace],
      ["w2", { id: "w2", name: "Two", path: "/tmp/two" } as Workspace],
    ]);

    return {
      storage: {
        getOwnerName: () => "test-user",
        getWorkspace: (id: string) => workspaces.get(id) ?? null,
      } as StreamContext["storage"],
      metrics: { record: vi.fn() } as unknown as StreamContext["metrics"],
      trackConnection: vi.fn(),
      untrackConnection: vi.fn(),
    };
  }

  it("includes ASR availability in the workspace stream bootstrap", () => {
    const ctx = createWorkspaceContext() as ReturnType<typeof createWorkspaceContext> & {
      dictationManager: NonNullable<StreamContext["dictationManager"]>;
    };
    ctx.dictationManager = {} as NonNullable<StreamContext["dictationManager"]>;
    const mux = new WorkspaceStreamMux(ctx);
    const ws = new FakeWebSocket();

    mux.handleWebSocket("w1", ws as unknown as WebSocket);

    expect(ws.sentOfType("stream_connected")[0]).toMatchObject({ asrAvailable: true });
  });

  it("fans out workspace events only to matching workspace sockets", () => {
    const ctx = createWorkspaceContext();
    const mux = new WorkspaceStreamMux(ctx);
    const ws1 = new FakeWebSocket();
    const ws2 = new FakeWebSocket();

    mux.handleWebSocket("w1", ws1 as unknown as WebSocket);
    mux.handleWebSocket("w2", ws2 as unknown as WebSocket);
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws1, { userBroadcast: false });
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws2, { userBroadcast: false });
    ws1.sent.length = 0;
    ws2.sent.length = 0;

    mux.recordAndFanOutWorkspaceEvent("w1", {
      type: "session_projection",
      summary: makeSession("s1", "w1"),
      sessionId: "s1",
    } as ServerMessage);

    expect(ws1.sentOfType("session_projection")).toHaveLength(1);
    expect(ws2.sentOfType("session_projection")).toHaveLength(0);
    expect(ws1.sent[0]?.workspaceId).toBe("w1");
    expect(ws1.sent[0]?.streamSeq).toBe(1);
  });

  it("serves workspace catch-up from the workspace-specific ring", () => {
    const ctx = createWorkspaceContext();
    const mux = new WorkspaceStreamMux(ctx);

    mux.recordAndFanOutWorkspaceEvent("w1", {
      type: "session_projection",
      summary: makeSession("s1", "w1"),
      sessionId: "s1",
    } as ServerMessage);
    mux.recordAndFanOutWorkspaceEvent("w2", {
      type: "session_projection",
      summary: makeSession("s2", "w2"),
      sessionId: "s2",
    } as ServerMessage);
    mux.recordAndFanOutWorkspaceEvent("w1", {
      type: "session_deleted",
      sessionId: "s1",
    } as ServerMessage);

    const catchUp = mux.getWorkspaceStreamCatchUp("w1", 0);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.currentSeq).toBe(2);
    expect(catchUp.events.map((event) => event.type)).toEqual([
      "session_projection",
      "session_deleted",
    ]);
    expect(catchUp.events.every((event) => event.workspaceId === "w1")).toBe(true);
  });

  it("closes unknown workspace sockets without tracking them", () => {
    const ctx = createWorkspaceContext();
    const mux = new WorkspaceStreamMux(ctx);
    const ws = new FakeWebSocket();

    mux.handleWebSocket("missing", ws as unknown as WebSocket);

    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ctx.trackConnection).not.toHaveBeenCalled();
  });
});

describe("SessionAudioStreamMux", () => {
  it("routes dictation controls and binary audio to a per-connection manager", () => {
    const session = makeSession("s-audio", "w1");
    const { ctx } = createMockContext([session]);
    const manager = {
      handleControlMessage: vi.fn((msg, send) => {
        if (msg.type === "dictation_start") {
          send({ type: "dictation_ready", sttProvider: "test", sttModel: "mock" });
        }
      }),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new SessionAudioStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket("w1", "s-audio", ws as unknown as WebSocket);
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws, { userBroadcast: false });

    ws.receive({ type: "dictation_start" } as ClientMessage);
    ws.receiveBinary(Buffer.from([1, 2, 3]));
    ws.close(1000);

    expect(manager.handleControlMessage).toHaveBeenCalledWith(
      { type: "dictation_start" },
      expect.any(Function),
    );
    expect(manager.handleAudioData).toHaveBeenCalledWith(Buffer.from([1, 2, 3]));
    expect(manager.handleDisconnect).toHaveBeenCalled();
    expect(ws.sentOfType("dictation_ready")).toHaveLength(1);
  });

  it("rejects unsupported chat messages on the audio stream", () => {
    const session = makeSession("s-audio", "w1");
    const { ctx } = createMockContext([session]);
    const manager = {
      handleControlMessage: vi.fn(),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new SessionAudioStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleWebSocket("w1", "s-audio", ws as unknown as WebSocket);

    ws.receive({ type: "prompt", message: "hello" } as ClientMessage);

    const errors = ws.sentOfType("dictation_error");
    expect(errors).toHaveLength(1);
    expect((errors[0] as { error?: string }).error).toContain("Unsupported audio stream message");
    expect(manager.handleControlMessage).not.toHaveBeenCalled();
  });

  it("closes missing session sockets without tracking them", () => {
    const { ctx } = createMockContext([]);
    const mux = new SessionAudioStreamMux(ctx);
    const ws = new FakeWebSocket();

    mux.handleWebSocket("w1", "missing", ws as unknown as WebSocket);

    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ctx.trackConnection).not.toHaveBeenCalled();
  });
});
