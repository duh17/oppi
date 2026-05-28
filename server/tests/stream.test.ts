import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "events";
import { WebSocket } from "ws";
import { BoundSessionStreamMux, SessionAudioStreamMux, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "../src/types.js";

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

class FakeWebSocket extends EventEmitter {
  readyState: number = WebSocket.OPEN;
  sent: ServerMessage[] = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  ping(): void {}

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  receive(msg: ClientMessage): void {
    this.emit("message", Buffer.from(JSON.stringify(msg)), false);
  }

  receiveBinary(data: Buffer): void {
    this.emit("message", data, true);
  }

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
      resolveDecision: vi.fn(() => true),
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

async function drain(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
}

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
        workspaceId: "w1",
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
  });

  it("does not auto-start a terminal mirror session when a client attaches", async () => {
    const session = { ...makeSession("sess-mirror", "w1"), runtime: "pi-tui-mirror" as const };
    const { ctx } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    ctx.mirrorRuntime = {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      subscribe: mirrorSubscribe,
    } as unknown as StreamContext["mirrorRuntime"];

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).not.toHaveBeenCalled();
    expect(ws.sentOfType("connected", "sess-mirror")[0]).toMatchObject({ currentSeq: 7 });
    expect(mirrorSubscribe).toHaveBeenCalledWith("sess-mirror", expect.any(Function));
  });

  it("includes server dictation availability in the split session bootstrap", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    ctx.dictationManager = {} as NonNullable<StreamContext["dictationManager"]>;

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    expect(ws.sentOfType("stream_connected")[0]).toMatchObject({ serverDictationAvailable: true });
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
