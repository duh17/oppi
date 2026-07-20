import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";
import { BoundSessionStreamMux, DictationStreamMux, type StreamContext } from "../src/stream.js";
import type { SessionCatchUpResponse } from "../src/session-broadcast.js";
import { Storage } from "../src/storage.js";
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
  closeCode?: number;
  onSend?: (message: ServerMessage) => void;

  send(data: string): void {
    const message = JSON.parse(data) as ServerMessage;
    this.sent.push(message);
    this.onSend?.(message);
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
    this.closeCode = code;
    this.emit("close", code, Buffer.from(""));
  }
}

type RuntimeOverride = {
  isSessionConnected?: (id: string) => boolean;
  isSessionLive?: (id: string) => boolean;
  getSessionSnapshot?: (id: string) => Session | undefined;
  getActiveSession?: (id: string) => Session | undefined;
  getCurrentSeq?: (id: string) => number;
  getCatchUp?: (id: string, sinceSeq: number) => SessionCatchUpResponse | null;
  subscribe?: (id: string, cb: (msg: ServerMessage) => void) => () => void;
  getPendingUIRequestMessages?: (id: string) => ServerMessage[];
};

function createMockContext(sessions: Session[]): {
  ctx: StreamContext;
  sessionMap: Map<string, Session>;
  subscribers: Map<string, Set<(msg: ServerMessage) => void>>;
  runtimeOverrides: Map<string, RuntimeOverride>;
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

  let ctx: StreamContext;
  const runtimeOverrides = new Map<string, RuntimeOverride>();
  const runtimeOverride = (id: string): RuntimeOverride =>
    sessionMap.get(id)?.runtime === "pi-tui" ? (runtimeOverrides.get(id) ?? {}) : {};
  const sessionRuntimes = {
    isSessionConnected: (id: string) => {
      const override = runtimeOverride(id);
      if (override.isSessionConnected) return override.isSessionConnected(id);
      const session = sessionMap.get(id);
      if (session?.runtime === "pi-tui") return false;
      return ctx.sessions.getActiveSession(id) !== undefined;
    },
    isSessionLive: (id: string) =>
      runtimeOverride(id).isSessionLive?.(id) ?? sessionRuntimes.isSessionConnected(id),
    getSessionSnapshot: (id: string) => {
      const override = runtimeOverride(id);
      return (
        override.getSessionSnapshot?.(id) ??
        override.getActiveSession?.(id) ??
        ctx.sessions.getActiveSession(id) ??
        sessionMap.get(id)
      );
    },
    getActiveSession: (id: string) => {
      const override = runtimeOverride(id);
      if (override.getActiveSession) return override.getActiveSession(id);
      const session = sessionMap.get(id);
      if (session?.runtime === "pi-tui" && !sessionRuntimes.isSessionConnected(id)) {
        return undefined;
      }
      return ctx.sessions.getActiveSession(id) ?? undefined;
    },
    getCurrentSeq: (id: string) =>
      runtimeOverride(id).getCurrentSeq?.(id) ?? ctx.sessions.getCurrentSeq(id),
    getCatchUp: (id: string, sinceSeq: number) => {
      const override = runtimeOverride(id);
      return override.getCatchUp
        ? override.getCatchUp(id, sinceSeq)
        : ctx.sessions.getCatchUp(id, sinceSeq);
    },
    subscribe: (id: string, cb: (msg: ServerMessage) => void) => {
      const override = runtimeOverride(id);
      if (override.subscribe) return override.subscribe(id, cb);
      const session = sessionMap.get(id);
      if (session?.runtime === "pi-tui") return () => {};
      return ctx.sessions.subscribe(id, cb);
    },
    getPendingUIRequestMessages: (id: string) =>
      runtimeOverride(id).getPendingUIRequestMessages?.(id) ??
      ctx.sessions.getPendingUIRequestMessages(id),
  } as unknown as StreamContext["sessionRuntimes"];

  ctx = {
    storage: {
      getOwnerName: () => "test-user",
      getSession: (id: string) => sessionMap.get(id) ?? null,
      saveSession: (session: Session) => {
        sessionMap.set(session.id, structuredClone(session));
      },
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
      getCatchUp: (id: string) => {
        const session = sessionMap.get(id);
        return session ? { events: [], currentSeq: 0, session, catchUpComplete: true } : null;
      },
      getPendingUIRequestMessages: () => [],
    } as unknown as StreamContext["sessions"],
    sessionRuntimes,
    ensureSessionContextWindow: (s: Session) => s,
    resolveWorkspaceForSession: () => undefined as Workspace | undefined,
    handleClientMessage: vi.fn(async () => {}),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
    createDictationManager: undefined,
  };

  return { ctx, sessionMap, subscribers, runtimeOverrides, broadcastTo };
}

async function drain(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

function mirrorRuntimeStubs(
  session: Session,
  currentSeq: number,
  catchUpAvailable = true,
): RuntimeOverride {
  return {
    getCatchUp: () =>
      catchUpAvailable ? { events: [], currentSeq, session, catchUpComplete: true } : null,
    getPendingUIRequestMessages: () => [],
  };
}

describe("BoundSessionStreamMux", () => {
  it("opens declared control streams and rejects both workspace and undeclared sessions", async () => {
    const control = {
      ...makeSession("control-session"),
      control: { domain: "agents" as const, intent: "create" as const },
    };
    const workspace = makeSession("workspace-session", "w1");
    const undeclared = makeSession("workspace-less-session");
    const { ctx } = createMockContext([control, workspace, undeclared]);
    const mux = new BoundSessionStreamMux(ctx);

    const accepted = new FakeWebSocket();
    await mux.handleControlWebSocket(control.id, accepted as unknown as WebSocket);
    expect(accepted.sentOfType("stream_connected")).toHaveLength(1);
    expect(accepted.sentOfType("connected", control.id)).toHaveLength(1);
    expect(ctx.sessions.startSession).toHaveBeenCalledWith(control.id, undefined);

    for (const session of [workspace, undeclared]) {
      const rejected = new FakeWebSocket();
      await mux.handleControlWebSocket(session.id, rejected as unknown as WebSocket);
      expect(rejected.closeCode).toBe(1008);
      expect(rejected.sent).toEqual([]);
    }
  });

  it("opens a control stream after the declared session is reloaded from SQLite", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-control-stream-store-"));

    try {
      const writer = new Storage(dir);
      const control = writer.createSession("Persisted control session");
      control.control = {
        domain: "schedules",
        intent: "revise",
        targetId: "schedule-1",
        targetName: "Nightly",
      };
      writer.saveSession(control);

      const reader = new Storage(dir);
      const persisted = reader.getSession(control.id);
      if (!persisted) throw new Error("Expected the control session to survive SQLite reload");
      expect(persisted.control).toEqual(control.control);
      expect(persisted.workspaceId).toBeUndefined();

      const { ctx } = createMockContext([persisted]);
      ctx.storage = reader;
      const mux = new BoundSessionStreamMux(ctx);
      const ws = new FakeWebSocket();

      await mux.handleControlWebSocket(control.id, ws as unknown as WebSocket);

      expect(ws.closeCode).toBeUndefined();
      expect(ws.sentOfType("stream_connected")).toHaveLength(1);
      expect(ws.sentOfType("connected", control.id)).toHaveLength(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

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
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws);
    expect(ctx.sessions.startSession).toHaveBeenCalledWith("sess-bound", undefined);

    ws.sent.length = 0;
    expect(
      mux.sendToSession("sess-bound", {
        type: "extension_ui_request",
        id: "ui-bound",
        sessionId: "sess-bound",
        method: "select",
        title: "approval",
      }),
    ).toBe(1);
    expect(ws.sentOfType("extension_ui_request", "sess-bound")).toHaveLength(1);

    ws.receive({ type: "reload", sessionId: "sess-bound", requestId: "reload-1" } as ClientMessage);
    await drain();

    expect(ctx.handleClientMessage).toHaveBeenCalledWith(
      expect.objectContaining({ id: "sess-bound" }),
      expect.objectContaining({ type: "reload", sessionId: "sess-bound", requestId: "reload-1" }),
      expect.any(Function),
      expect.any(Object),
    );
  });

  it("serializes commands that arrive while an earlier stream command is in flight", async () => {
    const session = makeSession("sess-command-race", "w1");
    const { ctx } = createMockContext([session]);
    let finishFirst: (() => void) | undefined;
    vi.mocked(ctx.handleClientMessage).mockImplementation(async (_session, msg, send) => {
      if (msg.requestId === "reload-1") {
        await new Promise<void>((resolve) => {
          finishFirst = resolve;
        });
      }
      send({
        type: "command_result",
        command: msg.type,
        requestId: msg.requestId,
        success: true,
      });
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);

    ws.receive({ type: "reload", sessionId: session.id, requestId: "reload-1" } as ClientMessage);
    await drain();
    ws.receive({ type: "reload", sessionId: session.id, requestId: "reload-2" } as ClientMessage);
    await drain();

    expect(ctx.handleClientMessage).toHaveBeenCalledTimes(1);
    expect(finishFirst).toBeDefined();
    expect(ws.sentOfType("command_result", session.id)).toHaveLength(0);

    finishFirst?.();
    await drain();
    await drain();

    expect(ctx.handleClientMessage).toHaveBeenCalledTimes(2);
    expect(
      ws
        .sentOfType("command_result", session.id)
        .map((message) => (message as { requestId?: string }).requestId),
    ).toEqual(["reload-1", "reload-2"]);
  });

  it("replays the opening gap exactly once before queued live delivery", async () => {
    const session = makeSession("sess-bootstrap-gap", "w1");
    const { ctx, subscribers, broadcastTo } = createMockContext([session]);
    const gapEvents: ServerMessage[] = [];
    let currentSeq = 10;
    let finishOpen: ((session: Session) => void) | undefined;
    const getCurrentSeq = vi.fn(() => currentSeq);
    const getCatchUp = vi.fn((_id: string, sinceSeq: number): SessionCatchUpResponse => {
      expect(sinceSeq).toBe(10);
      expect(subscribers.get(session.id)?.size).toBe(1);
      // seq 12 is both observed live and included in the ring snapshot. Bootstrap
      // must suppress that overlap while retaining post-snapshot live seq 13.
      broadcastTo(session.id, gapEvents[1]!);
      return {
        events: gapEvents,
        currentSeq,
        session,
        catchUpComplete: true,
      };
    });
    vi.mocked(ctx.sessions.startSession).mockImplementation(
      () =>
        new Promise<Session>((resolve) => {
          finishOpen = resolve;
        }),
    );
    (ctx.sessions as unknown as { getCurrentSeq: typeof getCurrentSeq }).getCurrentSeq =
      getCurrentSeq;
    (ctx.sessions as unknown as { getCatchUp: typeof getCatchUp }).getCatchUp = getCatchUp;

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    ws.onSend = (message) => {
      if (message.type !== "connected") return;
      broadcastTo(session.id, { type: "agent_end", seq: 13 } as ServerMessage);
    };
    const connect = mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);
    await drain();

    currentSeq = 12;
    gapEvents.push(
      {
        type: "tool_start",
        tool: "read",
        args: { path: "README.md" },
        toolCallId: "tool-gap",
        seq: 11,
      } as ServerMessage,
      {
        type: "tool_end",
        tool: "read",
        toolCallId: "tool-gap",
        seq: 12,
      } as ServerMessage,
    );
    finishOpen?.(session);
    await connect;

    const orderedSequenced = ws.sent
      .filter((message) => typeof (message as { seq?: number }).seq === "number")
      .map((message) => (message as { seq: number }).seq);

    expect(ws.sentOfType("connected", session.id)[0]).toMatchObject({ currentSeq: 12 });
    expect(ws.sentOfType("tool_start", session.id)).toHaveLength(1);
    expect(ws.sentOfType("tool_end", session.id)).toHaveLength(1);
    expect(ws.sentOfType("agent_end", session.id)).toHaveLength(1);
    expect(orderedSequenced).toEqual([11, 12, 13]);
    expect(getCurrentSeq).toHaveBeenCalledTimes(1);
    expect(getCatchUp).toHaveBeenCalledWith(session.id, 10);
  });

  it("uses the started runtime head and delivers post-subscribe events once", async () => {
    const session = makeSession("sess-bootstrap-started", "w1");
    const { ctx, broadcastTo } = createMockContext([session]);
    let active = false;
    const getCurrentSeq = vi.fn(() => (active ? 4 : 0));
    const getCatchUp = vi.fn((_id: string, sinceSeq: number): SessionCatchUpResponse => {
      expect(sinceSeq).toBe(4);
      return { events: [], currentSeq: 4, session, catchUpComplete: true };
    });
    (ctx.sessions as unknown as { getActiveSession: () => Session | undefined }).getActiveSession =
      () => (active ? session : undefined);
    vi.mocked(ctx.sessions.startSession).mockImplementation(async () => {
      active = true;
      return session;
    });
    (ctx.sessions as unknown as { getCurrentSeq: typeof getCurrentSeq }).getCurrentSeq =
      getCurrentSeq;
    (ctx.sessions as unknown as { getCatchUp: typeof getCatchUp }).getCatchUp = getCatchUp;

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    ws.onSend = (message) => {
      if (message.type !== "connected") return;
      broadcastTo(session.id, { type: "agent_start", seq: 5 } as ServerMessage);
    };
    await mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);

    expect(ws.sentOfType("connected", session.id)[0]).toMatchObject({ currentSeq: 4 });
    expect(ws.sentOfType("agent_start", session.id)).toHaveLength(1);
    expect(getCurrentSeq.mock.calls).toEqual([[session.id], [session.id]]);
    expect(getCatchUp).toHaveBeenCalledWith(session.id, 4);
  });

  it("closes on a ring miss and recovers from the new head on reconnect", async () => {
    const session = makeSession("sess-bootstrap-ring-miss", "w1");
    const { ctx, subscribers } = createMockContext([session]);
    let currentSeq = 10;
    const getCatchUp = vi.fn((_id: string, sinceSeq: number): SessionCatchUpResponse => {
      if (sinceSeq === 10) {
        currentSeq = 600;
        return { events: [], currentSeq, session, catchUpComplete: false };
      }
      return { events: [], currentSeq, session, catchUpComplete: true };
    });
    (ctx.sessions as unknown as { getCurrentSeq: () => number }).getCurrentSeq = () => currentSeq;
    (ctx.sessions as unknown as { getCatchUp: typeof getCatchUp }).getCatchUp = getCatchUp;

    const mux = new BoundSessionStreamMux(ctx);
    const missed = new FakeWebSocket();
    await mux.handleWebSocket("w1", session.id, missed as unknown as WebSocket);

    expect(missed.sentOfType("connected", session.id)).toHaveLength(0);
    expect(missed.closeCode).toBe(1011);
    expect(subscribers.get(session.id)?.size ?? 0).toBe(0);

    const recovered = new FakeWebSocket();
    await mux.handleWebSocket("w1", session.id, recovered as unknown as WebSocket);

    expect(recovered.closeCode).toBeUndefined();
    expect(recovered.sentOfType("connected", session.id)[0]).toMatchObject({ currentSeq: 600 });
    expect(subscribers.get(session.id)?.size).toBe(1);
    expect(getCatchUp.mock.calls).toEqual([
      [session.id, 10],
      [session.id, 600],
    ]);
  });

  it("tags replayed extension UI notifications with the bound session id", async () => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    const pendingReplay: ServerMessage = {
      type: "extension_ui_notification",
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["0 of 4 tasks completed"],
      widgetPlacement: "aboveEditor",
    };
    (
      ctx.sessions as unknown as {
        getPendingUIRequestMessages: (sessionId: string) => ServerMessage[];
      }
    ).getPendingUIRequestMessages = vi.fn(() => [pendingReplay]);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    expect(ws.sentOfType("extension_ui_notification", "sess-bound")).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        sessionId: "sess-bound",
        widgetKey: "goal",
        widgetLines: ["0 of 4 tasks completed"],
      }),
    ]);
  });

  it("does not auto-start a terminal mirror session when a client attaches", async () => {
    const session = { ...makeSession("sess-mirror", "w1"), runtime: "pi-tui" as const };
    const { ctx, runtimeOverrides } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    runtimeOverrides.set("sess-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      isSessionConnected: () => true,
      subscribe: mirrorSubscribe,
      ...mirrorRuntimeStubs(session, 7),
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).not.toHaveBeenCalled();
    expect(ws.sentOfType("connected", "sess-mirror")[0]).toMatchObject({ currentSeq: 7 });
    expect(mirrorSubscribe).toHaveBeenCalledWith("sess-mirror", expect.any(Function));
  });

  it("keeps a recently reloading terminal mirror session bound to the mirror runtime", async () => {
    const session = {
      ...makeSession("sess-reloading-mirror", "w1"),
      runtime: "pi-tui" as const,
      mirror: {
        status: "connected" as const,
        terminal: { disconnectedAt: Date.now(), disconnectReason: "reload" },
      },
      piSessionFile: "/tmp/reloading-session.jsonl",
    };
    const { ctx, runtimeOverrides } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    runtimeOverrides.set("sess-reloading-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 9,
      isSessionConnected: () => false,
      subscribe: mirrorSubscribe,
      ...mirrorRuntimeStubs(session, 9, false),
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-reloading-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).not.toHaveBeenCalled();
    expect(mirrorSubscribe).toHaveBeenCalledWith("sess-reloading-mirror", expect.any(Function));
    expect(ws.sentOfType("connected", "sess-reloading-mirror")[0]).toMatchObject({
      currentSeq: 9,
    });
    expect(ws.closeCode).toBeUndefined();
    expect(ws.readyState).toBe(WebSocket.OPEN);
  });

  it("keeps a stale terminal mirror session bound to mirror ownership", async () => {
    const session = {
      ...makeSession("sess-stale-mirror", "w1"),
      runtime: "pi-tui" as const,
      mirror: { status: "connected" as const },
      piSessionFile: "/tmp/stale-session.jsonl",
    };
    const { ctx, sessionMap, runtimeOverrides } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    runtimeOverrides.set("sess-stale-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      isSessionConnected: () => false,
      subscribe: mirrorSubscribe,
      ...mirrorRuntimeStubs(session, 7, false),
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-stale-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).not.toHaveBeenCalled();
    expect(mirrorSubscribe).toHaveBeenCalledWith("sess-stale-mirror", expect.any(Function));
    expect(sessionMap.get("sess-stale-mirror")?.runtime).toBe("pi-tui");
    expect(ws.sentOfType("connected", "sess-stale-mirror")[0]).toMatchObject({ currentSeq: 7 });
    expect(ws.closeCode).toBeUndefined();
  });

  it("resumes a stopped disconnected mirror session as an oppi imported session", async () => {
    const session = {
      ...makeSession("sess-stopped-mirror", "w1"),
      status: "stopped" as const,
      runtime: "pi-tui" as const,
      mirror: { status: "disconnected" as const },
      piSessionFile: "/tmp/stopped-session.jsonl",
    };
    const { ctx, sessionMap, runtimeOverrides } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    runtimeOverrides.set("sess-stopped-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      isSessionConnected: () => false,
      subscribe: mirrorSubscribe,
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-stopped-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).toHaveBeenCalledWith("sess-stopped-mirror", undefined);
    expect(mirrorSubscribe).not.toHaveBeenCalled();
    expect(sessionMap.get("sess-stopped-mirror")?.runtime).toBe("oppi");
    expect(sessionMap.get("sess-stopped-mirror")?.mirror).toBeUndefined();
  });

  it("resumes a ready disconnected mirror session as an oppi imported session", async () => {
    const session = {
      ...makeSession("sess-ready-mirror", "w1"),
      status: "ready" as const,
      runtime: "pi-tui" as const,
      mirror: { status: "disconnected" as const },
      piSessionFile: "/tmp/ready-session.jsonl",
    };
    const { ctx, sessionMap, runtimeOverrides } = createMockContext([session]);
    const mirrorSubscribe = vi.fn(() => () => {});
    runtimeOverrides.set("sess-ready-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      isSessionConnected: () => false,
      subscribe: mirrorSubscribe,
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-ready-mirror", ws as unknown as WebSocket);
    await drain();

    expect(ctx.sessions.startSession).toHaveBeenCalledWith("sess-ready-mirror", undefined);
    expect(mirrorSubscribe).not.toHaveBeenCalled();
    expect(sessionMap.get("sess-ready-mirror")?.runtime).toBe("oppi");
    expect(sessionMap.get("sess-ready-mirror")?.mirror).toBeUndefined();
  });

  it("keeps a mirror-bound stream open when the live bridge disconnects", async () => {
    const session = { ...makeSession("sess-live-mirror", "w1"), runtime: "pi-tui" as const };
    const { ctx, runtimeOverrides } = createMockContext([session]);
    let mirrorCallback: ((msg: ServerMessage) => void) | undefined;
    runtimeOverrides.set("sess-live-mirror", {
      getActiveSession: () => session,
      getCurrentSeq: () => 7,
      isSessionConnected: () => true,
      subscribe: (_id: string, cb: (msg: ServerMessage) => void) => {
        mirrorCallback = cb;
        return () => {};
      },
      ...mirrorRuntimeStubs(session, 7),
    });

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-live-mirror", ws as unknown as WebSocket);
    await drain();

    mirrorCallback?.({
      type: "state",
      session: {
        ...session,
        mirror: { status: "disconnected" },
      },
    });

    expect(ws.readyState).toBe(WebSocket.OPEN);
    expect(ws.sentOfType("state", "sess-live-mirror").at(-1)).toMatchObject({
      session: expect.objectContaining({ mirror: { status: "disconnected" } }),
    });
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

describe("DictationStreamMux", () => {
  it("routes dictation controls and binary audio to a per-connection manager", () => {
    const { ctx } = createMockContext([]);
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

    const mux = new DictationStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleServerWebSocket(ws as unknown as WebSocket);
    expect(ctx.trackConnection).toHaveBeenCalledWith(ws);

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

  it("rejects unsupported chat messages on the dictation stream", () => {
    const { ctx } = createMockContext([]);
    const manager = {
      handleControlMessage: vi.fn(),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new DictationStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleServerWebSocket(ws as unknown as WebSocket);

    ws.receive({ type: "prompt", message: "hello" } as ClientMessage);

    const errors = ws.sentOfType("dictation_error");
    expect(errors).toHaveLength(1);
    expect((errors[0] as { error?: string }).error).toContain(
      "Unsupported dictation stream message",
    );
    expect(manager.handleControlMessage).not.toHaveBeenCalled();
  });
});
