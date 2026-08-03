import { afterEach, describe, expect, it, vi } from "vitest";

import oppiPiMirror, { type MessageQueueState } from "./oppi-mirror.js";
import { OPPI_MIRROR_INPUT_PREFLIGHT_CAPABILITY } from "./oppi-mirror-contract.ts";

const wsMock = vi.hoisted(() => {
  type Handler = (...args: unknown[]) => void;

  class FakeWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    readonly sent: string[] = [];
    readyState = FakeWebSocket.CONNECTING;
    private readonly handlers = new Map<string, Handler[]>();

    constructor(
      readonly url: string,
      readonly options: Record<string, unknown>,
    ) {
      wsMock.instances.push(this);
    }

    on(event: string, handler: Handler): void {
      const handlers = this.handlers.get(event) ?? [];
      handlers.push(handler);
      this.handlers.set(event, handlers);
    }

    send(data: unknown): void {
      this.sent.push(String(data));
    }

    close(): void {
      this.readyState = FakeWebSocket.CLOSED;
      this.emit("close", 1000, Buffer.from(""));
    }

    open(): void {
      this.readyState = FakeWebSocket.OPEN;
      this.emit("open");
    }

    receive(data: unknown): void {
      this.emit("message", Buffer.from(String(data)));
    }

    private emit(event: string, ...args: unknown[]): void {
      for (const handler of this.handlers.get(event) ?? []) {
        handler(...args);
      }
    }
  }

  return { FakeWebSocket, instances: [] as FakeWebSocket[] };
});

vi.mock("ws", () => ({ WebSocket: wsMock.FakeWebSocket }));

const piAgentMock = vi.hoisted(() => {
  interface PendingPrompt {
    text: string;
    options: {
      streamingBehavior?: "steer" | "followUp";
      preflightResult?: (success: boolean) => void;
    };
    resolve: () => void;
    reject: (error: Error) => void;
    settled?: boolean;
  }

  class FakeAgentSession {
    static latest: FakeAgentSession | undefined;

    readonly promptCalls: PendingPrompt[] = [];
    readonly reload = vi.fn(async () => {});
    sessionId = "pi-session-1";
    sessionManager = { getSessionId: () => this.sessionId };
    _steeringMessages: string[] = [];
    _followUpMessages: string[] = [];
    agent = {
      clearAllQueues: vi.fn(),
      steer: vi.fn(),
      followUp: vi.fn(),
    };

    constructor() {
      FakeAgentSession.latest = this;
    }

    bindExtensions(): void {}
    _emit(_event: unknown): void {}
    _emitQueueUpdate(): void {}
    getSteeringMessages(): readonly string[] {
      return this._steeringMessages;
    }
    getFollowUpMessages(): readonly string[] {
      return this._followUpMessages;
    }

    replaceTerminalQueue(steering: string[], followUp: string[]): void {
      this._steeringMessages = [...steering];
      this._followUpMessages = [...followUp];
      this._emitQueueUpdate();
    }

    prompt(text: string, options: PendingPrompt["options"]): Promise<void> {
      return new Promise<void>((resolve, reject) => {
        this.promptCalls.push({ text, options, resolve, reject });
      });
    }

    acceptNext(): void {
      const pending = this.promptCalls.find((call) => !call.settled);
      if (!pending) throw new Error("Expected a pending Pi prompt");
      pending.settled = true;
      if (pending.options.streamingBehavior === "steer") {
        this._steeringMessages.push(pending.text);
        this._emitQueueUpdate();
      } else if (pending.options.streamingBehavior === "followUp") {
        this._followUpMessages.push(pending.text);
        this._emitQueueUpdate();
      }
      pending.options.preflightResult?.(true);
      pending.resolve();
    }

    rejectNext(error: Error): void {
      const pending = this.promptCalls.find((call) => !call.settled);
      if (!pending) throw new Error("Expected a pending Pi prompt");
      pending.settled = true;
      pending.options.preflightResult?.(false);
      pending.reject(error);
    }
  }

  return { FakeAgentSession, version: "0.81.1" };
});

vi.mock("@earendil-works/pi-coding-agent", () => ({
  AgentSession: piAgentMock.FakeAgentSession,
  get VERSION() {
    return piAgentMock.version;
  },
}));

type Handler = (
  event: Record<string, unknown>,
  ctx: MockExtensionContext,
) => unknown;

interface MockPi {
  handlers: Map<string, Handler[]>;
  commands: Map<
    string,
    { handler: (args: string, ctx: MockExtensionContext) => Promise<void> }
  >;
  on(event: string, handler: Handler): void;
  registerCommand(
    name: string,
    command: {
      handler: (args: string, ctx: MockExtensionContext) => Promise<void>;
    },
  ): void;
  appendEntry: ReturnType<typeof vi.fn>;
  getThinkingLevel: ReturnType<typeof vi.fn>;
  sendUserMessage: ReturnType<typeof vi.fn>;
}

interface MockExtensionContext {
  cwd: string;
  hasUI: boolean;
  mode: "tui" | "rpc";
  model: undefined;
  sessionManager: {
    getSessionFile: ReturnType<typeof vi.fn>;
    getSessionId: ReturnType<typeof vi.fn>;
    getSessionName: ReturnType<typeof vi.fn>;
    getLeafId: ReturnType<typeof vi.fn>;
    getEntries: ReturnType<typeof vi.fn>;
  };
  getContextUsage: ReturnType<typeof vi.fn>;
  isIdle: ReturnType<typeof vi.fn>;
  hasPendingMessages: ReturnType<typeof vi.fn>;
  abort: ReturnType<typeof vi.fn>;
  shutdown: ReturnType<typeof vi.fn>;
  ui: {
    theme: { fg: ReturnType<typeof vi.fn> };
    setWidget: ReturnType<typeof vi.fn>;
    setStatus: ReturnType<typeof vi.fn>;
    setWorkingMessage: ReturnType<typeof vi.fn>;
    setWorkingIndicator: ReturnType<typeof vi.fn>;
    setWorkingVisible: ReturnType<typeof vi.fn>;
    notify: ReturnType<typeof vi.fn>;
    confirm: ReturnType<typeof vi.fn>;
  };
}

function createMockPi(): MockPi {
  const handlers = new Map<string, Handler[]>();
  const commands = new Map<
    string,
    { handler: (args: string, ctx: MockExtensionContext) => Promise<void> }
  >();
  return {
    handlers,
    commands,
    on(event: string, handler: Handler) {
      const eventHandlers = handlers.get(event) ?? [];
      eventHandlers.push(handler);
      handlers.set(event, eventHandlers);
    },
    registerCommand(name, command) {
      commands.set(name, command);
    },
    appendEntry: vi.fn(),
    getThinkingLevel: vi.fn(() => "medium"),
    sendUserMessage: vi.fn(),
  };
}

function createMockContext(sessionId = "pi-session-1"): MockExtensionContext {
  const ui = {
    theme: { fg: vi.fn((_color: string, text: string) => text) },
    setWidget: vi.fn((_key: string, content: unknown) => {
      if (typeof content === "function") {
        const component = content({ requestRender: vi.fn() }, ui.theme) as {
          render?: (width: number) => string[];
        };
        component.render?.(88);
      }
    }),
    setStatus: vi.fn(),
    setWorkingMessage: vi.fn(),
    setWorkingIndicator: vi.fn(),
    setWorkingVisible: vi.fn(),
    notify: vi.fn(),
    confirm: vi.fn(async () => false),
  };
  return {
    cwd: "/workspace/project",
    hasUI: true,
    mode: "tui",
    model: undefined,
    sessionManager: {
      getSessionFile: vi.fn(() => "/tmp/session.jsonl"),
      getSessionId: vi.fn(() => sessionId),
      getSessionName: vi.fn(() => "Session"),
      getLeafId: vi.fn(() => "leaf-1"),
      getEntries: vi.fn(() => []),
    },
    getContextUsage: vi.fn(() => ({ tokens: 1, contextWindow: 100 })),
    isIdle: vi.fn(() => true),
    hasPendingMessages: vi.fn(() => false),
    abort: vi.fn(),
    shutdown: vi.fn(),
    ui,
  };
}

async function startSession(
  pi: MockPi,
  ctx: MockExtensionContext,
): Promise<void> {
  for (const handler of pi.handlers.get("session_start") ?? []) {
    await handler({ type: "session_start", reason: "startup" }, ctx);
  }
}

async function startMirror(
  pi: MockPi,
  ctx: MockExtensionContext,
  helloAck: Record<string, unknown> = {
    type: "hello_ack",
    protocolVersion: 2,
    sessionId: "s1",
    workspaceId: "w1",
  },
): Promise<(typeof wsMock.instances)[number]> {
  await pi.commands.get("oppi-mirror")?.handler("start", ctx);
  const socket = wsMock.instances.at(-1);
  if (!socket) throw new Error("Expected mirror websocket");
  socket.open();
  socket.receive(JSON.stringify(helloAck));
  await Promise.resolve();
  return socket;
}

function sentExtensionUIRequests(
  socket: (typeof wsMock.instances)[number],
): Record<string, unknown>[] {
  return socket.sent
    .map((line) => JSON.parse(line) as Record<string, unknown>)
    .filter((message) => message.type === "extension_ui_request");
}

function sentCommandResults(
  socket: (typeof wsMock.instances)[number],
  id?: string,
): Record<string, unknown>[] {
  return socket.sent
    .map((line) => JSON.parse(line) as Record<string, unknown>)
    .filter(
      (message) =>
        message.type === "command_result" &&
        (id === undefined || message.id === id),
    );
}

async function drainMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function withInteractiveTerminal(run: () => Promise<void>): Promise<void> {
  const stdinDescriptor = Object.getOwnPropertyDescriptor(
    process.stdin,
    "isTTY",
  );
  const stdoutDescriptor = Object.getOwnPropertyDescriptor(
    process.stdout,
    "isTTY",
  );
  Object.defineProperty(process.stdin, "isTTY", {
    configurable: true,
    value: true,
  });
  Object.defineProperty(process.stdout, "isTTY", {
    configurable: true,
    value: true,
  });
  return run().finally(() => {
    if (stdinDescriptor) {
      Object.defineProperty(process.stdin, "isTTY", stdinDescriptor);
    } else {
      delete (process.stdin as { isTTY?: boolean }).isTTY;
    }
    if (stdoutDescriptor) {
      Object.defineProperty(process.stdout, "isTTY", stdoutDescriptor);
    } else {
      delete (process.stdout as { isTTY?: boolean }).isTTY;
    }
  });
}

afterEach(() => {
  wsMock.instances.length = 0;
  piAgentMock.FakeAgentSession.latest = undefined;
  piAgentMock.version = "0.81.1";
  vi.unstubAllEnvs();
  vi.useRealTimers();
});

describe("oppi mirror input preflight", () => {
  it("bootstraps input when the AgentSession bound extensions before session_start", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const agentSession = new piAgentMock.FakeAgentSession();
      agentSession.sessionId = "pi-session-bootstrap";
      agentSession.bindExtensions();
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext(agentSession.sessionId);
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "bootstrap-prompt",
          command: {
            type: "prompt",
            message: "first phone prompt",
            clientTurnId: "turn-bootstrap",
          },
        }),
      );
      await drainMicrotasks();

      expect(pi.sendUserMessage).toHaveBeenCalledWith("first phone prompt", {});
      expect(sentCommandResults(socket, "bootstrap-prompt")).toEqual([
        expect.objectContaining({
          success: true,
          data: expect.objectContaining({ dispatched: true }),
        }),
      ]);

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "pending-bootstrap-prompt",
          command: {
            type: "prompt",
            message: "must wait for attachment",
            clientTurnId: "turn-pending-bootstrap",
          },
        }),
      );
      await drainMicrotasks();
      expect(sentCommandResults(socket, "pending-bootstrap-prompt")).toEqual([
        expect.objectContaining({
          success: false,
          error:
            "Terminal Pi runtime session control is attaching after bootstrap input",
        }),
      ]);
      expect(pi.sendUserMessage).toHaveBeenCalledTimes(1);

      const unrelatedSession = new piAgentMock.FakeAgentSession();
      unrelatedSession.sessionId = "pi-session-unrelated";
      unrelatedSession._emit({ type: "agent_start" });
      socket.receive(
        JSON.stringify({
          type: "command",
          id: "unrelated-session-prompt",
          command: {
            type: "prompt",
            message: "must not use unrelated control",
            clientTurnId: "turn-unrelated-session",
          },
        }),
      );
      await drainMicrotasks();
      expect(sentCommandResults(socket, "unrelated-session-prompt")).toEqual([
        expect.objectContaining({
          success: false,
          error:
            "Terminal Pi runtime session control is attaching after bootstrap input",
        }),
      ]);
      expect(pi.sendUserMessage).toHaveBeenCalledTimes(1);

      agentSession._emit({ type: "agent_start" });
      socket.receive(
        JSON.stringify({
          type: "command",
          id: "attached-prompt",
          command: {
            type: "prompt",
            message: "second phone prompt",
            clientTurnId: "turn-attached",
          },
        }),
      );
      await drainMicrotasks();

      expect(agentSession.promptCalls).toHaveLength(1);
      expect(pi.sendUserMessage).toHaveBeenCalledTimes(1);
      agentSession.acceptNext();
      await drainMicrotasks();
      expect(sentCommandResults(socket, "attached-prompt")).toEqual([
        expect.objectContaining({ success: true }),
      ]);
    });
  });

  it.each([
    ["malformed", { type: "hello_ack", sessionId: "s1", workspaceId: "w1" }],
    [
      "old",
      {
        type: "hello_ack",
        protocolVersion: 1,
        sessionId: "s1",
        workspaceId: "w1",
      },
    ],
  ] as const)(
    "fails closed for a %s hello acknowledgement",
    async (_name, helloAck) => {
      await withInteractiveTerminal(async () => {
        vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
        vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
        vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
        const pi = createMockPi();
        await oppiPiMirror(pi as never);
        const ctx = createMockContext();
        await startSession(pi, ctx);
        const agentSession = new piAgentMock.FakeAgentSession();
        agentSession.bindExtensions();
        const socket = await startMirror(pi, ctx, helloAck);

        expect(socket.readyState).toBe(wsMock.FakeWebSocket.CLOSED);
        expect(agentSession.promptCalls).toHaveLength(0);
      });
    },
  );

  it("advertises input preflight for Pi 0.81.1", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      const hello = socket.sent
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .find((message) => message.type === "hello");

      expect(hello).toEqual(
        expect.objectContaining({
          protocolVersion: 2,
          capabilities: expect.arrayContaining([
            OPPI_MIRROR_INPUT_PREFLIGHT_CAPABILITY,
          ]),
        }),
      );
    });
  });

  it("does not reconnect after the server permanently rejects bridge hello", async () => {
    await withInteractiveTerminal(async () => {
      vi.useFakeTimers();
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      const terminalNotify = ctx.ui.notify;
      await startSession(pi, ctx);

      await pi.commands.get("oppi-mirror")?.handler("start", ctx);
      const socket = wsMock.instances.at(-1);
      if (!socket) throw new Error("Expected mirror websocket");
      socket.open();
      socket.receive(
        JSON.stringify({
          type: "error",
          code: "invalid_bridge_hello",
          error:
            "Bridge hello protocolVersion must be an explicit supported safe integer; received <missing>; supported: 2",
          receivedProtocolVersion: "<missing>",
          receivedProtocolVersionType: "missing",
          supportedProtocolVersions: [2],
        }),
      );
      await Promise.resolve();
      socket.close();
      await vi.advanceTimersByTimeAsync(2_000);

      expect(wsMock.instances).toHaveLength(1);
      expect(terminalNotify).toHaveBeenCalledWith(
        expect.stringContaining("bridge protocol"),
        "warning",
      );
    });
  });

  it("correlates rejection and retry for prompt, steer, and follow-up", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const agentSession = new piAgentMock.FakeAgentSession();
      agentSession.bindExtensions();
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      for (const type of ["prompt", "steer", "follow_up"] as const) {
        const clientTurnId = `turn-${type}`;
        const rejectedId = `cmd-${type}-rejected`;
        socket.receive(
          JSON.stringify({
            type: "command",
            id: rejectedId,
            command: { type, message: `${type} message`, clientTurnId },
          }),
        );
        agentSession.rejectNext(new Error(`${type} preflight rejected`));
        await drainMicrotasks();

        expect(sentCommandResults(socket, rejectedId)).toEqual([
          expect.objectContaining({
            type: "command_result",
            id: rejectedId,
            success: false,
            error: `${type} preflight rejected`,
          }),
        ]);

        const retryId = `cmd-${type}-retry`;
        socket.receive(
          JSON.stringify({
            type: "command",
            id: retryId,
            command: { type, message: `${type} message`, clientTurnId },
          }),
        );
        agentSession.acceptNext();
        await drainMicrotasks();
        expect(sentCommandResults(socket, retryId)).toEqual([
          expect.objectContaining({
            type: "command_result",
            id: retryId,
            success: true,
          }),
        ]);

        const duplicateId = `cmd-${type}-accepted-duplicate`;
        socket.receive(
          JSON.stringify({
            type: "command",
            id: duplicateId,
            command: { type, message: `${type} message`, clientTurnId },
          }),
        );
        await drainMicrotasks();
        expect(sentCommandResults(socket, duplicateId)).toEqual([
          expect.objectContaining({
            type: "command_result",
            id: duplicateId,
            success: true,
          }),
        ]);
      }

      expect(agentSession.promptCalls).toHaveLength(6);
      expect(pi.sendUserMessage).not.toHaveBeenCalled();
    });
  });

  it("rejects stale set_queue at the terminal authority without losing local intent", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const agentSession = new piAgentMock.FakeAgentSession();
      agentSession.bindExtensions();
      const socket = await startMirror(pi, ctx);

      agentSession.replaceTerminalQueue(["A"], []);
      const queueAfterA = socket.sent
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .findLast((message) => message.type === "queue_state")
        ?.queue as MessageQueueState;
      agentSession.replaceTerminalQueue(["B"], []);
      const queueAfterB = socket.sent
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .findLast((message) => message.type === "queue_state")
        ?.queue as MessageQueueState;
      expect(queueAfterB.version).toBe(queueAfterA.version + 1);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "stale-set-queue",
          command: {
            type: "set_queue",
            baseVersion: queueAfterA.version,
            steering: [{ id: "stale", message: "stale replacement" }],
            followUp: [],
          },
        }),
      );
      await drainMicrotasks();

      expect(agentSession.getSteeringMessages()).toEqual(["B"]);
      expect(sentCommandResults(socket, "stale-set-queue")).toEqual([
        expect.objectContaining({
          success: false,
          error: `Queue version mismatch: expected ${queueAfterB.version}, got ${queueAfterA.version}`,
          data: {
            code: "queue_version_mismatch",
            queue: expect.objectContaining({
              version: queueAfterB.version,
              steering: [expect.objectContaining({ message: "B" })],
              followUp: [],
            }),
          },
        }),
      ]);
    });
  });

  it("coalesces pending duplicate clientTurnIds without double Pi dispatch", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const agentSession = new piAgentMock.FakeAgentSession();
      agentSession.bindExtensions();
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      for (const id of ["cmd-pending-1", "cmd-pending-2"]) {
        socket.receive(
          JSON.stringify({
            type: "command",
            id,
            command: {
              type: "prompt",
              message: "one Pi dispatch",
              clientTurnId: "turn-pending",
            },
          }),
        );
      }
      await drainMicrotasks();
      expect(agentSession.promptCalls).toHaveLength(1);
      expect(sentCommandResults(socket)).toHaveLength(0);

      agentSession.acceptNext();
      await drainMicrotasks();
      expect(sentCommandResults(socket)).toEqual([
        expect.objectContaining({ id: "cmd-pending-1", success: true }),
        expect.objectContaining({ id: "cmd-pending-2", success: true }),
      ]);
    });
  });
});

describe("oppi mirror extension UI replay", () => {
  it("does not initialize mirror runtime side effects for managed RPC sessions", async () => {
    vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
    const pi = createMockPi();
    await oppiPiMirror(pi as never);
    const ctx = createMockContext();
    ctx.mode = "rpc";
    const originalSetStatus = ctx.ui.setStatus;
    const originalSetWidget = ctx.ui.setWidget;

    await startSession(pi, ctx);

    expect(pi.commands.size).toBe(0);
    expect(Array.from(pi.handlers.keys())).toEqual(["session_start"]);
    expect(ctx.ui.setStatus).toBe(originalSetStatus);
    expect(ctx.ui.setWidget).toBe(originalSetWidget);
    expect(pi.appendEntry).not.toHaveBeenCalled();
    expect(wsMock.instances).toHaveLength(0);
  });

  it("persists Pi lifecycle evidence in TUI session entries", async () => {
    vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
    const pi = createMockPi();
    await oppiPiMirror(pi as never);
    const ctx = createMockContext();
    await startSession(pi, ctx);

    for (const handler of pi.handlers.get("tool_execution_end") ?? []) {
      await handler(
        {
          type: "tool_execution_end",
          toolCallId: "call-1",
          toolName: "bash",
          isError: false,
          result: { content: "not duplicated" },
        },
        ctx,
      );
    }
    for (const handler of pi.handlers.get("agent_settled") ?? []) {
      await handler({ type: "agent_settled" }, ctx);
    }

    expect(pi.appendEntry).toHaveBeenCalledWith("oppi-lifecycle", {
      version: 1,
      event: "tool_execution_end",
      toolCallId: "call-1",
      toolName: "bash",
      isError: false,
    });
    expect(pi.appendEntry).toHaveBeenCalledWith("oppi-lifecycle", {
      version: 1,
      event: "agent_settled",
    });
  });

  it("replays persistent status and widget state captured before bridge connect", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();

      await startSession(pi, ctx);
      ctx.ui.setStatus("build-status", "running");
      ctx.ui.setWidget(
        "task-list",
        () => ({
          render: () => ["Widget details"],
          invalidate: () => {},
        }),
        { placement: "aboveEditor" },
      );
      await Promise.resolve();

      const socket = await startMirror(pi, ctx);
      const requests = sentExtensionUIRequests(socket);

      expect(requests).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            method: "setStatus",
            statusKey: "build-status",
            statusText: "running",
          }),
          expect.objectContaining({
            method: "setWidget",
            widgetKey: "task-list",
            widgetLines: ["Widget details"],
            widgetPlacement: "aboveEditor",
          }),
        ]),
      );
    });
  });

  it("forwards working-state UI updates from the proxied terminal context", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      const terminalSetWorkingMessage = ctx.ui.setWorkingMessage;

      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      ctx.ui.setWorkingMessage("Tracing the logic");
      ctx.ui.setWorkingIndicator({ frames: ["●"], intervalMs: 120 });
      ctx.ui.setWorkingVisible(true);

      expect(terminalSetWorkingMessage).toHaveBeenCalledWith(
        "Tracing the logic",
      );
      expect(sentExtensionUIRequests(socket)).toEqual([
        expect.objectContaining({
          method: "setWorkingMessage",
          message: "Tracing the logic",
        }),
        expect.objectContaining({
          method: "setWorkingIndicator",
          workingIndicator: { frames: ["●"], intervalMs: 120 },
        }),
        expect.objectContaining({
          method: "setWorkingVisible",
          workingVisible: true,
        }),
      ]);
    });
  });

  it("replays pending blocking dialogs after bridge reconnect", async () => {
    await withInteractiveTerminal(async () => {
      vi.useFakeTimers();
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      ctx.ui.confirm = vi.fn(
        async (
          _title: string,
          _message?: string,
          opts?: { signal?: AbortSignal },
        ) =>
          new Promise<boolean>((resolve) => {
            opts?.signal?.addEventListener("abort", () => resolve(false), {
              once: true,
            });
          }),
      );

      await startSession(pi, ctx);
      const firstSocket = await startMirror(pi, ctx);
      firstSocket.sent.length = 0;

      const confirmPromise = ctx.ui.confirm("Install app?", "Approve install");
      await Promise.resolve();
      const firstRequest = sentExtensionUIRequests(firstSocket).find(
        (request) => request.method === "confirm",
      );
      expect(firstRequest).toEqual(
        expect.objectContaining({
          method: "confirm",
          title: "Install app?",
          message: "Approve install",
        }),
      );

      firstSocket.close();
      await vi.advanceTimersByTimeAsync(2_000);
      const secondSocket = wsMock.instances.at(-1);
      if (!secondSocket || secondSocket === firstSocket) {
        throw new Error("Expected reconnect websocket");
      }
      secondSocket.open();
      secondSocket.receive(
        JSON.stringify({
          type: "hello_ack",
          protocolVersion: 2,
          sessionId: "s1",
          workspaceId: "w1",
        }),
      );
      await Promise.resolve();

      expect(sentExtensionUIRequests(secondSocket)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: firstRequest?.id,
            method: "confirm",
            title: "Install app?",
            message: "Approve install",
          }),
        ]),
      );

      secondSocket.receive(
        JSON.stringify({
          type: "extension_ui_response",
          id: firstRequest?.id,
          confirmed: true,
        }),
      );

      await expect(confirmPromise).resolves.toBe(true);
    });
  });

  it("does not replay persistent UI that was cleared before bridge connect", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();

      await startSession(pi, ctx);
      ctx.ui.setStatus("build-status", "running");
      ctx.ui.setStatus("build-status", undefined);
      ctx.ui.setWidget("task-list", ["Widget details"], {
        placement: "aboveEditor",
      });
      ctx.ui.setWidget("task-list", undefined, { placement: "aboveEditor" });

      const socket = await startMirror(pi, ctx);
      const requests = sentExtensionUIRequests(socket);

      expect(requests).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            method: "setStatus",
            statusKey: "build-status",
          }),
          expect.objectContaining({
            method: "setWidget",
            widgetKey: "task-list",
          }),
        ]),
      );
    });
  });
});
