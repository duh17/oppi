import { describe, expect, it, vi } from "vitest";
import { EventEmitter } from "events";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";
import { AgentConfigurationError } from "../src/agent-launch-errors.js";
import { CLOCK_SKEW_MS } from "../src/storage/device-auth.js";
import { BoundSessionStreamMux, DictationStreamMux, type StreamContext } from "../src/stream.js";
import type { SessionCatchUpResponse } from "../src/session-broadcast.js";
import { SessionLifecycleService } from "../src/session-lifecycle-service.js";
import { Storage } from "../src/storage.js";
import type { ClientMessage, ServerMessage, Session, Workspace } from "../src/types.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import { buildExtensionUIRequestMessage } from "../src/extension-ui-contract.js";
import { SessionManager } from "../src/sessions.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

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
    subscribeStartupUI: (id: string, send: (message: ServerMessage) => void) =>
      ctx.sessions.subscribeStartupUI?.(id, send) ?? (() => {}),
    stopSession: vi.fn(async () => {}),
    stopSessionIfActive: vi.fn(async () => {}),
  } as unknown as StreamContext["sessionRuntimes"];

  ctx = {
    storage: {
      getOwnerName: () => "test-user",
      getSession: (id: string) => sessionMap.get(id) ?? null,
      saveSession: (session: Session) => {
        sessionMap.set(session.id, structuredClone(session));
      },
      getDataDir: () => tmpdir(),
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
  it("delivers startup dialogs and accepts answers ahead of buffered session commands", async () => {
    const session = makeSession("startup-trust", "w1");
    const { ctx } = createMockContext([session]);
    let sendStartup: ((message: ServerMessage) => void) | undefined;
    const detach = vi.fn();
    ctx.sessions.subscribeStartupUI = vi.fn((_id, send) => {
      sendStartup = send;
      return detach;
    });
    const bridge = new SdkUiBridge(
      (event) => {
        if (event.type === "extension_ui_request")
          sendStartup?.(buildExtensionUIRequestMessage(session.id, event));
      },
      () => false,
    );
    let answer: string | undefined;
    vi.mocked(ctx.sessions.startSession).mockImplementation(async () => {
      answer = await bridge
        .createContext()
        .select("Trust project?", ["Trust", "Don't trust"], { timeout: 1000 });
      return session;
    });
    ctx.handleClientMessage = vi.fn(async (_session, message) => {
      if (message.type === "extension_ui_response") {
        expect(bridge.respond(message)).toBe(true);
      }
    });
    const ws = new FakeWebSocket();
    ws.onSend = (message) => {
      if (message.type !== "extension_ui_request") return;
      expect(ws.sentOfType("connected")).toHaveLength(0);
      ws.receive({ type: "get_state" });
      ws.receive({ type: "extension_ui_response", id: message.id, value: "Don't trust" });
    };
    try {
      await new BoundSessionStreamMux(ctx).handleWebSocket(
        "w1",
        session.id,
        ws as unknown as WebSocket,
      );
      await drain();
      expect(answer).toBe("Don't trust");
      expect(ws.sentOfType("connected")).toHaveLength(1);
      expect(vi.mocked(ctx.handleClientMessage).mock.calls.map((call) => call[1].type)).toEqual([
        "extension_ui_response",
        "get_state",
      ]);
      expect(detach).toHaveBeenCalled();
    } finally {
      ws.close();
      bridge.dispose();
    }
  });
  it("closing an opened stream does not detach a second stream's startup UI", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-stream-startup-"));
    const rendererLoad = vi
      .spyOn(MobileRendererRegistry.prototype, "loadAllRenderers")
      .mockResolvedValue({ loaded: [], errors: [] });
    const manager = new SessionManager(new Storage(dir));
    const session = makeSession("two-startup-streams", "w1");
    const { ctx } = createMockContext([session]);
    let staleDetach!: () => void;
    ctx.sessions.subscribeStartupUI = (id, send) => {
      const detach = manager.subscribeStartupUI(id, send);
      staleDetach ??= detach;
      return detach;
    };
    const mux = new BoundSessionStreamMux(ctx);
    const first = new FakeWebSocket();
    const second = new FakeWebSocket();
    let finish!: (session: Session) => void;
    try {
      await mux.handleWebSocket("w1", session.id, first as unknown as WebSocket);
      vi.mocked(ctx.sessions.startSession).mockImplementation(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      );
      const opening = mux.handleWebSocket("w1", session.id, second as unknown as WebSocket);
      await drain();
      staleDetach(); // Explicit repeated disposal must also be safe outside stream cleanup.
      first.close();
      // Drive the real subscription owner, not a mock subscriber registry.
      const relay = manager as unknown as {
        broadcastStartupUI: (id: string, message: ServerMessage) => void;
      };
      relay.broadcastStartupUI(session.id, {
        type: "extension_ui_request",
        id: "second-dialog",
        method: "select",
        title: "Trust?",
        options: ["yes", "no"],
      });
      expect(second.sentOfType("extension_ui_request")).toHaveLength(1);
      finish(session);
      await opening;
      expect(second.sentOfType("connected")).toHaveLength(1);
    } finally {
      first.close();
      second.close();
      rendererLoad.mockRestore();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("buffers 100 startup frames and closes on the next without replaying commands", async () => {
    const session = makeSession("startup-cap", "w1");
    const { ctx } = createMockContext([session]);
    const detach = vi.fn();
    ctx.sessions.subscribeStartupUI = vi.fn(() => detach);
    let finish!: (session: Session) => void;
    vi.mocked(ctx.sessions.startSession).mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const ws = new FakeWebSocket();
    const opening = new BoundSessionStreamMux(ctx).handleWebSocket(
      "w1",
      session.id,
      ws as unknown as WebSocket,
    );
    await drain();
    for (let i = 0; i < 100; i++) ws.receive({ type: "get_state" });
    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.receive({ type: "get_state" });
    expect(ws.closeCode).toBe(1008);
    expect(detach).toHaveBeenCalledTimes(1);
    expect(ws.listenerCount("message")).toBe(0);
    finish(session);
    await opening;
    expect(ctx.handleClientMessage).not.toHaveBeenCalled();
    expect(ws.sentOfType("connected")).toHaveLength(0);
  });

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

  it("closes terminal Agent configuration failures without timeline errors or retries", async () => {
    const session = makeSession("agent-config-failure", "w1");
    const { ctx } = createMockContext([session]);
    vi.mocked(ctx.sessions.startSession).mockRejectedValue(
      new AgentConfigurationError("agent_extensions_unavailable", {
        unavailableExtensions: ["/extensions/research-bundle.ts"],
      }),
    );

    const ws = new FakeWebSocket();
    await new BoundSessionStreamMux(ctx).handleWebSocket(
      "w1",
      session.id,
      ws as unknown as WebSocket,
    );

    expect(ws.closeCode).toBe(1008);
    expect(ws.sentOfType("error", session.id)).toHaveLength(0);
    expect(ws.sentOfType("connected", session.id)).toHaveLength(0);
  });

  it("rebinds a removed-worktree focused session onto main and emits a live notice", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-stream-removed-worktree-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-stream-removed-worktree-data-"));
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: root });
    execFileSync("git", ["config", "user.email", "oppi-test@example.invalid"], { cwd: root });
    execFileSync("git", ["config", "user.name", "Oppi Test"], { cwd: root });
    writeFileSync(join(root, "README.md"), "main\n");
    execFileSync("git", ["add", "README.md"], { cwd: root });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: root });
    const workspace: Workspace = {
      id: "w1",
      name: "Workspace",
      hostMount: root,
      systemPromptMode: "append",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const session = {
      ...makeSession("sess-removed", "w1"),
      runtime: "oppi" as const,
      worktreeId: "wt_removed",
      status: "stopped" as const,
    };
    const { ctx, sessionMap } = createMockContext([session]);
    ctx.storage.getDataDir = () => dataDir;
    ctx.resolveWorkspaceForSession = () => workspace;
    vi.mocked(ctx.sessions.startSession).mockImplementation(async (id: string) => {
      const current = sessionMap.get(id) ?? session;
      current.status = "ready";
      return current;
    });

    try {
      const ws = new FakeWebSocket();
      await new BoundSessionStreamMux(ctx).handleWebSocket(
        "w1",
        session.id,
        ws as unknown as WebSocket,
      );
      await drain();

      expect(ws.closeCode).toBeUndefined();
      expect(ws.sentOfType("stream_connected")).toHaveLength(1);
      expect(sessionMap.get(session.id)?.worktreeId).toBe("main");
      expect(sessionMap.get(session.id)?.warnings).toBeUndefined();
      expect(ctx.sessions.startSession).toHaveBeenCalledWith(session.id, workspace);
      expect(ws.sentOfType("cache_miss")).toHaveLength(0);
      const notices = ws.sentOfType("notice");
      expect(notices).toHaveLength(1);
      expect(notices[0]).toMatchObject({
        type: "notice",
        id: `worktree-rebind:${session.id}`,
        message: "Resuming on Main checkout. The worktree is gone.",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("emits the live notice after HTTP resume already rebound the session", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-stream-resume-then-open-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-stream-resume-then-open-data-"));
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: root });
    execFileSync("git", ["config", "user.email", "oppi-test@example.invalid"], { cwd: root });
    execFileSync("git", ["config", "user.name", "Oppi Test"], { cwd: root });
    writeFileSync(join(root, "README.md"), "main\n");
    execFileSync("git", ["add", "README.md"], { cwd: root });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: root });
    const workspace: Workspace = {
      id: "w1",
      name: "Workspace",
      hostMount: root,
      systemPromptMode: "append",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const session = {
      ...makeSession("sess-resume-then-open", "w1"),
      runtime: "oppi" as const,
      worktreeId: "wt_removed",
      status: "stopped" as const,
    };
    const { ctx, sessionMap } = createMockContext([session]);
    ctx.storage.getDataDir = () => dataDir;
    ctx.resolveWorkspaceForSession = () => workspace;
    vi.mocked(ctx.sessions.startSession).mockImplementation(async (id: string) => {
      const current = sessionMap.get(id) ?? session;
      current.status = "ready";
      return current;
    });
    const lifecycle = new SessionLifecycleService({
      storage: ctx.storage,
      sessions: ctx.sessions,
      sessionRuntimes: ctx.sessionRuntimes,
      ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    });

    try {
      const resume = await lifecycle.resumeWorkspaceSession({ session, workspace });
      expect(resume.rebound).toBe(true);
      expect(sessionMap.get(session.id)?.worktreeId).toBe("main");
      expect(sessionMap.get(session.id)?.warnings).toBeUndefined();

      const ws = new FakeWebSocket();
      await new BoundSessionStreamMux(ctx).handleWebSocket(
        "w1",
        session.id,
        ws as unknown as WebSocket,
      );
      await drain();

      expect(ws.closeCode).toBeUndefined();
      expect(ws.sentOfType("cache_miss")).toHaveLength(0);
      expect(ws.sentOfType("notice")).toEqual([
        expect.objectContaining({
          type: "notice",
          id: `worktree-rebind:${session.id}`,
          message: "Resuming on Main checkout. The worktree is gone.",
        }),
      ]);

      const second = new FakeWebSocket();
      await new BoundSessionStreamMux(ctx).handleWebSocket(
        "w1",
        session.id,
        second as unknown as WebSocket,
      );
      await drain();
      expect(second.sentOfType("cache_miss")).toHaveLength(0);
      expect(second.sentOfType("notice")).toHaveLength(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
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

  it.each([
    {
      name: "malformed required field",
      payload: { type: "fork", requestId: "req-fork" },
      expected: {
        type: "command_result",
        command: "fork",
        requestId: "req-fork",
        success: false,
        error: "Invalid payload: expected entryId",
        sessionId: "sess-bound",
      },
    },
    {
      name: "malformed required field without requestId",
      payload: { type: "fork" },
      expected: {
        type: "error",
        error: "Invalid payload: expected entryId",
        sessionId: "sess-bound",
      },
    },
    {
      name: "unknown type",
      payload: { type: "future_command_v99", requestId: "req-unknown" },
      expected: {
        type: "command_result",
        command: "future_command_v99",
        requestId: "req-unknown",
        success: false,
        error: "Unsupported command type: future_command_v99",
        sessionId: "sess-bound",
      },
    },
    {
      name: "missing type",
      payload: { requestId: "req-type" },
      expected: {
        type: "error",
        error: "Message type is required",
        sessionId: "sess-bound",
      },
    },
  ])("preserves session stream command ingress surfaces: $name", async ({ payload, expected }) => {
    const session = makeSession("sess-bound", "w1");
    const { ctx } = createMockContext([session]);
    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    await mux.handleWebSocket("w1", "sess-bound", ws as unknown as WebSocket);
    await drain();

    ws.sent.length = 0;
    ws.emit("message", Buffer.from(JSON.stringify(payload)), false);
    await drain();

    expect(ctx.handleClientMessage).not.toHaveBeenCalled();
    expect(ws.sent).toEqual([expected]);
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
    const detach = vi.fn();
    ctx.sessions.subscribeStartupUI = vi.fn(() => detach);
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
    expect(detach).toHaveBeenCalledTimes(1);
    expect(ws.listenerCount("message")).toBe(0);
    ws.receive({ type: "get_state" });
    expect(ctx.handleClientMessage).not.toHaveBeenCalled();
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

  it("sends complete tool previews immediately and coalesces later snapshots per socket", async () => {
    vi.useFakeTimers();
    const first = new FakeWebSocket();
    const second = new FakeWebSocket();
    try {
      const session = makeSession("sess-tool-preview", "w1");
      const { ctx, broadcastTo } = createMockContext([session]);
      const mux = new BoundSessionStreamMux(ctx);
      await mux.handleWebSocket("w1", session.id, first as unknown as WebSocket);
      await mux.handleWebSocket("w1", session.id, second as unknown as WebSocket);
      first.sent.length = 0;
      second.sent.length = 0;

      const update = (toolCallId: string, content: string): ServerMessage => ({
        type: "tool_update",
        tool: "write",
        toolCallId,
        args: { path: "note.txt", content },
        callSegments: [{ text: content }],
      });
      const emit = (message: ServerMessage) => broadcastTo(session.id, message);
      emit(update("a", "first"));
      expect(first.sent).toEqual([{ ...update("a", "first"), sessionId: session.id }]);
      expect(second.sent).toEqual(first.sent);

      await vi.advanceTimersByTimeAsync(10);
      emit(update("a", "second"));
      await vi.advanceTimersByTimeAsync(10);
      emit(update("a", "third"));
      expect(first.sent).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(29);
      expect(first.sent).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(first.sent).toEqual([
        { ...update("a", "first"), sessionId: session.id },
        { ...update("a", "third"), sessionId: session.id },
      ]);
      expect(second.sent).toEqual(first.sent);

      // The timer's send anchors a fresh 50ms window for the next burst.
      await vi.advanceTimersByTimeAsync(10);
      emit(update("a", "after flush"));
      expect(first.sent).toHaveLength(2);
      await vi.advanceTimersByTimeAsync(10);
      emit(update("a", "latest after flush"));
      expect(first.sent).toHaveLength(2);
      await vi.advanceTimersByTimeAsync(29);
      expect(first.sent).toHaveLength(2);
      await vi.advanceTimersByTimeAsync(1);
      expect(first.sent).toEqual([
        { ...update("a", "first"), sessionId: session.id },
        { ...update("a", "third"), sessionId: session.id },
        { ...update("a", "latest after flush"), sessionId: session.id },
      ]);
      expect(second.sent).toEqual(first.sent);

      // An 80ms producer cadence must not lose any complete snapshot.
      await vi.advanceTimersByTimeAsync(80);
      emit(update("a", "fourth"));
      expect(first.sent.at(-1)).toEqual({ ...update("a", "fourth"), sessionId: session.id });
      await vi.advanceTimersByTimeAsync(80);
      emit(update("a", "fifth"));
      expect(first.sent.at(-1)).toEqual({ ...update("a", "fifth"), sessionId: session.id });
      await vi.advanceTimersByTimeAsync(10);
      emit(update("a", "sixth"));
      emit({ type: "tool_start", tool: "write", toolCallId: "a", args: {} });
      expect(first.sent.slice(-2)).toEqual([
        { ...update("a", "sixth"), sessionId: session.id },
        { type: "tool_start", tool: "write", toolCallId: "a", args: {}, sessionId: session.id },
      ]);
      await vi.advanceTimersByTimeAsync(100);
      expect(first.sent.at(-1)?.type).toBe("tool_start");

      emit(update("b", "other first"));
      await vi.advanceTimersByTimeAsync(10);
      emit(update("b", "other held"));
      emit(update("c", "new call"));
      expect(first.sent.slice(-2)).toEqual([
        { ...update("b", "other held"), sessionId: session.id },
        { ...update("c", "new call"), sessionId: session.id },
      ]);
      await vi.advanceTimersByTimeAsync(10);
      emit(update("c", "pending end"));
      emit({ type: "tool_end", tool: "write", toolCallId: "c" });
      expect(first.sent.slice(-2)).toEqual([
        { ...update("c", "pending end"), sessionId: session.id },
        { type: "tool_end", tool: "write", toolCallId: "c", sessionId: session.id },
      ]);

      // One socket may close with a held preview while the other still flushes.
      emit(update("d", "open"));
      await vi.advanceTimersByTimeAsync(10);
      emit(update("d", "held"));
      first.close();
      const beforeCloseCount = first.sent.length;
      await vi.advanceTimersByTimeAsync(40);
      expect(first.sent).toHaveLength(beforeCloseCount);
      expect(second.sent.at(-1)).toEqual({ ...update("d", "held"), sessionId: session.id });
    } finally {
      if (first.readyState === WebSocket.OPEN) first.close();
      if (second.readyState === WebSocket.OPEN) second.close();
      vi.useRealTimers();
    }
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

    ws.receive({ type: "dictation_start", contextualStrings: ["Foo Bar"] } as ClientMessage);
    ws.receiveBinary(Buffer.from([1, 2, 3]));
    ws.close(1000);

    expect(manager.handleControlMessage).toHaveBeenCalledWith(
      { type: "dictation_start", contextualStrings: ["Foo Bar"] },
      expect.any(Function),
    );
    expect(manager.handleAudioData).toHaveBeenCalledWith(Buffer.from([1, 2, 3]));
    expect(manager.handleDisconnect).toHaveBeenCalled();
    expect(ws.sentOfType("dictation_ready")).toHaveLength(1);
  });

  it("rejects malformed contextualStrings without starting STT", () => {
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

    ws.receive({
      type: "dictation_start",
      contextualStrings: ["bad\nphrase"],
    } as ClientMessage);

    const errors = ws.sentOfType("dictation_error");
    expect(errors).toHaveLength(1);
    expect((errors[0] as { error?: string }).error).toBe(
      "dictation contextualStrings cannot include control characters",
    );
    expect((errors[0] as { error?: string }).error).not.toContain("bad");
    expect(manager.handleControlMessage).not.toHaveBeenCalled();
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

  it("rejects dictation_start on an expired access token without starting STT", () => {
    const { ctx } = createMockContext([]);
    const manager = {
      handleControlMessage: vi.fn(),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
      isActive: vi.fn(() => false),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new DictationStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleServerWebSocket(ws as unknown as WebSocket, undefined, {
      expiresAt: Date.now() - CLOCK_SKEW_MS - 1,
    });

    ws.receive({ type: "dictation_start" } as ClientMessage);

    const errors = ws.sentOfType("dictation_error");
    expect(errors).toHaveLength(1);
    expect((errors[0] as { error?: string }).error).toContain("Access token expired");
    expect(manager.handleControlMessage).not.toHaveBeenCalled();
  });

  it("lets an active recording finish after expiry and rejects a later start", () => {
    const { ctx } = createMockContext([]);
    let active = true;
    const manager = {
      handleControlMessage: vi.fn((msg: { type: string }) => {
        if (msg.type === "dictation_stop" || msg.type === "dictation_cancel") {
          active = false;
        }
      }),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
      isActive: vi.fn(() => active),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new DictationStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleServerWebSocket(ws as unknown as WebSocket, undefined, {
      expiresAt: Date.now() + 60_000,
    });
    ws.receive({ type: "dictation_start" } as ClientMessage);
    expect(manager.handleControlMessage).toHaveBeenCalledTimes(1);

    mux.markAuthExpired(ws as unknown as WebSocket);
    expect(ws.closeCode).toBeUndefined();
    expect(ws.readyState).toBe(WebSocket.OPEN);

    ws.receive({ type: "dictation_start" } as ClientMessage);
    expect(manager.handleControlMessage).toHaveBeenCalledTimes(1);
    expect(ws.sentOfType("dictation_error")).toHaveLength(1);

    ws.receive({ type: "dictation_stop" } as ClientMessage);
    expect(manager.handleControlMessage).toHaveBeenCalledTimes(2);
    expect(ws.closeCode).toBe(4001);
  });

  it("delivers dictation_final before closing 4001 after expiry", async () => {
    const { ctx } = createMockContext([]);
    let active = true;
    const manager = {
      handleControlMessage: vi.fn(
        (msg: { type: string }, send: (m: { type: string; text?: string }) => void) => {
          if (msg.type === "dictation_stop") {
            queueMicrotask(() => {
              send({ type: "dictation_final", text: "hello" });
              active = false;
            });
          }
        },
      ),
      handleAudioData: vi.fn(),
      handleDisconnect: vi.fn(),
      isActive: vi.fn(() => active),
    };
    ctx.createDictationManager = () =>
      manager as unknown as ReturnType<NonNullable<StreamContext["createDictationManager"]>>;

    const mux = new DictationStreamMux(ctx);
    const ws = new FakeWebSocket();
    mux.handleServerWebSocket(ws as unknown as WebSocket, undefined, {
      expiresAt: Date.now() + 60_000,
    });
    ws.receive({ type: "dictation_start" } as ClientMessage);
    mux.markAuthExpired(ws as unknown as WebSocket);
    expect(ws.closeCode).toBeUndefined();

    const order: string[] = [];
    ws.onSend = (message) => {
      order.push(message.type);
      if (ws.closeCode !== undefined) order.push("closed");
    };

    ws.receive({ type: "dictation_stop" } as ClientMessage);
    expect(ws.closeCode).toBeUndefined();
    expect(ws.sentOfType("dictation_final")).toHaveLength(0);

    await drain();
    expect(order).toEqual(["dictation_final"]);
    expect(ws.sentOfType("dictation_final")).toHaveLength(1);
    expect(ws.closeCode).toBe(4001);
  });
});
