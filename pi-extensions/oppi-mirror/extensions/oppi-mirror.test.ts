import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import oppiPiMirror, { type MessageQueueState } from "./oppi-mirror.js";
import { OPPI_MIRROR_INPUT_PREFLIGHT_CAPABILITY } from "./oppi-mirror-contract.ts";

const OPPI_CALLER_SESSION_ID_ENV = "OPPI_CALLER_SESSION_ID";
const originalCallerSessionId = process.env[OPPI_CALLER_SESSION_ID_ENV];

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
      // Pi accepts this flag; the mirror must never set it, or Pi stops
      // resolving "/name" against its command registry.
      expandPromptTemplates?: boolean;
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
    readonly getAvailableThinkingLevels = vi.fn(() => [
      "off",
      "low",
      "medium",
      "high",
    ]);
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
  setThinkingLevel: ReturnType<typeof vi.fn>;
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
    getLeafEntry: ReturnType<typeof vi.fn>;
    getEntry: ReturnType<typeof vi.fn>;
    getEntries: ReturnType<typeof vi.fn>;
  };
  getContextUsage: ReturnType<typeof vi.fn>;
  isIdle: ReturnType<typeof vi.fn>;
  hasPendingMessages: ReturnType<typeof vi.fn>;
  abort: ReturnType<typeof vi.fn>;
  shutdown: ReturnType<typeof vi.fn>;
  navigateTree?: ReturnType<typeof vi.fn>;
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
  let thinkingLevel = "medium";
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
    getThinkingLevel: vi.fn(() => thinkingLevel),
    setThinkingLevel: vi.fn((level: string) => {
      thinkingLevel = level;
    }),
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
      getLeafEntry: vi.fn(() => undefined),
      getEntry: vi.fn(() => undefined),
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

async function shutdownSession(
  pi: MockPi,
  ctx: MockExtensionContext,
  reason: "quit" | "reload" | "new" | "resume" | "fork",
): Promise<void> {
  for (const handler of pi.handlers.get("session_shutdown") ?? []) {
    await handler({ type: "session_shutdown", reason }, ctx);
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

function preferredLocalApiSocketPath(dataDir: string): string {
  return join(dataDir, "run", "oppi.sock");
}

function fallbackLocalApiSocketPath(dataDir: string): string {
  const uid = process.getuid?.() ?? "user";
  const dataDirHash = createHash("sha256")
    .update(resolve(dataDir))
    .digest("hex")
    .slice(0, 16);
  return join("/tmp", `oppi-${uid}`, `${dataDirHash}.sock`);
}

function writeOppiConfig(
  overrides: Record<string, unknown> = {},
): { dataDir: string; configPath: string } {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-mirror-config-"));
  const configPath = join(dataDir, "config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      host: "0.0.0.0",
      port: 7749,
      tls: { mode: "tailscale" },
      token: "sk_unused_owner_token",
      ...overrides,
    }),
  );
  return { dataDir, configPath };
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
  const queueBridge = (
    globalThis as typeof globalThis & {
      __oppiMirrorQueueUpdateBridge?: {
        listeners: Set<unknown>;
        internalEventListeners: Set<unknown>;
        sessions: Map<unknown, unknown>;
        last?: unknown;
        lastSession?: unknown;
      };
    }
  ).__oppiMirrorQueueUpdateBridge;
  queueBridge?.listeners.clear();
  queueBridge?.internalEventListeners.clear();
  queueBridge?.sessions.clear();
  if (queueBridge) {
    delete queueBridge.last;
    delete queueBridge.lastSession;
  }
  delete (
    globalThis as typeof globalThis & {
      __oppiMirrorCallerSessionIdentity?: unknown;
    }
  ).__oppiMirrorCallerSessionIdentity;
  vi.unstubAllEnvs();
  if (originalCallerSessionId === undefined) {
    delete process.env[OPPI_CALLER_SESSION_ID_ENV];
  } else {
    process.env[OPPI_CALLER_SESSION_ID_ENV] = originalCallerSessionId;
  }
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

      expect(pi.sendUserMessage).toHaveBeenCalledWith("first phone prompt", {
        expandPromptTemplates: true,
      });
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
    [
      "missing-session-id",
      {
        type: "hello_ack",
        protocolVersion: 2,
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

  it("routes remote tree navigation through the terminal command context", async () => {
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
      const navigateTree = vi.fn(async () => ({ cancelled: false }));
      pi.sendUserMessage.mockImplementation((text: string) => {
        const args = text.replace(/^\/oppi-mirror\s*/, "");
        void pi.commands
          .get("oppi-mirror")
          ?.handler(args, { ...ctx, navigateTree });
      });
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "navigate-tree-terminal-sync",
          command: {
            type: "navigate_tree",
            targetId: "entry-1",
            summarize: false,
          },
        }),
      );
      await drainMicrotasks();

      expect(navigateTree).toHaveBeenCalledWith("entry-1", {
        summarize: false,
        customInstructions: undefined,
        replaceInstructions: undefined,
        label: undefined,
      });
      expect(pi.sendUserMessage).toHaveBeenCalledWith(
        expect.stringMatching(
          /^\/oppi-mirror __navigate-tree [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
        ),
        { expandPromptTemplates: true },
      );
      expect(sentCommandResults(socket, "navigate-tree-terminal-sync")).toEqual(
        [
          expect.objectContaining({
            success: true,
            data: { cancelled: false },
          }),
        ],
      );
    });
  });

  it("rejects concurrent remote tree navigation", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      for (const [id, targetId] of [
        ["navigate-first", "entry-1"],
        ["navigate-second", "entry-2"],
      ]) {
        socket.receive(
          JSON.stringify({
            type: "command",
            id,
            command: { type: "navigate_tree", targetId },
          }),
        );
      }
      await drainMicrotasks();

      expect(pi.sendUserMessage).toHaveBeenCalledTimes(1);
      expect(sentCommandResults(socket, "navigate-second")).toEqual([
        expect.objectContaining({
          success: false,
          error: "A session-tree navigation is already in progress.",
        }),
      ]);

      await pi.commands.get("oppi-mirror")?.handler("stop", ctx);
      await drainMicrotasks();
    });
  });

  it("rejects tree navigation if Pi becomes busy before command dispatch", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "navigate-became-busy",
          command: { type: "navigate_tree", targetId: "entry-1" },
        }),
      );
      await drainMicrotasks();
      const dispatched = pi.sendUserMessage.mock.calls[0]?.[0];
      expect(dispatched).toEqual(expect.any(String));
      ctx.isIdle.mockReturnValue(false);
      const navigateTree = vi.fn();
      await pi.commands
        .get("oppi-mirror")
        ?.handler(String(dispatched).replace(/^\/oppi-mirror\s*/, ""), {
          ...ctx,
          navigateTree,
        });
      await drainMicrotasks();

      expect(navigateTree).not.toHaveBeenCalled();
      expect(sentCommandResults(socket, "navigate-became-busy")).toEqual([
        expect.objectContaining({
          success: false,
          error:
            "Wait for the current response to finish before navigating the session tree.",
        }),
      ]);
    });
  });

  it("keeps the navigation lock across mirror stop and restart", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      let finishNavigation = () => {};
      const navigateTree = vi.fn(
        () =>
          new Promise<{ cancelled: false }>((resolve) => {
            finishNavigation = () => resolve({ cancelled: false });
          }),
      );
      const commandContext = { ...ctx, navigateTree };
      pi.sendUserMessage.mockImplementation((text: string) => {
        void pi.commands
          .get("oppi-mirror")
          ?.handler(text.replace(/^\/oppi-mirror\s*/, ""), commandContext);
      });
      const firstSocket = await startMirror(pi, ctx);

      firstSocket.receive(
        JSON.stringify({
          type: "command",
          id: "navigate-before-stop",
          command: { type: "navigate_tree", targetId: "entry-1" },
        }),
      );
      await drainMicrotasks();
      expect(navigateTree).toHaveBeenCalledTimes(1);

      await pi.commands.get("oppi-mirror")?.handler("stop", ctx);
      const secondSocket = await startMirror(pi, ctx);
      secondSocket.sent.length = 0;
      secondSocket.receive(
        JSON.stringify({
          type: "command",
          id: "navigate-after-restart",
          command: { type: "navigate_tree", targetId: "entry-2" },
        }),
      );
      await drainMicrotasks();

      expect(
        sentCommandResults(secondSocket, "navigate-after-restart"),
      ).toEqual([
        expect.objectContaining({
          success: false,
          error: "A session-tree navigation is already in progress.",
        }),
      ]);
      expect(navigateTree).toHaveBeenCalledTimes(1);

      finishNavigation();
      await drainMicrotasks();
    });
  });

  it("fails a remote tree navigation when Pi does not dispatch its command", async () => {
    await withInteractiveTerminal(async () => {
      vi.useFakeTimers();
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "navigate-not-dispatched",
          command: { type: "navigate_tree", targetId: "entry-1" },
        }),
      );
      await vi.advanceTimersByTimeAsync(10_000);

      expect(sentCommandResults(socket, "navigate-not-dispatched")).toEqual([
        expect.objectContaining({
          success: false,
          error: "Pi did not start the session-tree navigation command",
        }),
      ]);
    });
  });

  it("cycles thinking levels through the attached AgentSession", async () => {
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

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "cycle-thinking",
          command: { type: "cycle_thinking_level" },
        }),
      );
      await drainMicrotasks();

      expect(agentSession.getAvailableThinkingLevels).toHaveBeenCalledOnce();
      expect(pi.setThinkingLevel).toHaveBeenCalledWith("high");
      expect(sentCommandResults(socket, "cycle-thinking")).toEqual([
        expect.objectContaining({ success: true, data: { level: "high" } }),
      ]);
    });
  });

  it("rejects persist on set_model and set_thinking_level instead of claiming success", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "persist-model",
          command: {
            type: "set_model",
            provider: "anthropic",
            modelId: "claude-sonnet-4",
            persist: true,
          },
        }),
      );
      socket.receive(
        JSON.stringify({
          type: "command",
          id: "persist-thinking",
          command: { type: "set_thinking_level", level: "high", persist: true },
        }),
      );
      await drainMicrotasks();

      expect(sentCommandResults(socket, "persist-model")).toEqual([
        expect.objectContaining({
          success: false,
          error: "Mirrored Pi sessions cannot save a global default.",
        }),
      ]);
      expect(sentCommandResults(socket, "persist-thinking")).toEqual([
        expect.objectContaining({
          success: false,
          error: "Mirrored Pi sessions cannot save a global default.",
        }),
      ]);
      expect(pi.setThinkingLevel).not.toHaveBeenCalled();
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

describe("oppi mirror slash dispatch", () => {
  it("lets Pi resolve slash input for prompt, steer, and follow-up", async () => {
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
        socket.receive(
          JSON.stringify({
            type: "command",
            id: `cmd-${type}-slash`,
            command: {
              type,
              message: "/cursor-fast",
              clientTurnId: `turn-${type}-slash`,
            },
          }),
        );
        agentSession.acceptNext();
        await drainMicrotasks();

        expect(sentCommandResults(socket, `cmd-${type}-slash`)).toEqual([
          expect.objectContaining({ success: true }),
        ]);
      }

      expect(agentSession.promptCalls).toHaveLength(3);
      for (const call of agentSession.promptCalls) {
        // Verbatim text and expansion left on are what let Pi run the command
        // instead of sending "/cursor-fast" to the model as a user message.
        expect(call.text).toBe("/cursor-fast");
        expect(call.options.expandPromptTemplates).toBeUndefined();
      }
      expect(pi.sendUserMessage).not.toHaveBeenCalled();
    });
  });

  it("does not queue slash input that Pi consumed as a command", async () => {
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

      socket.receive(
        JSON.stringify({
          type: "command",
          id: "cmd-command-during-turn",
          command: {
            type: "follow_up",
            message: "/cursor-fast",
            clientTurnId: "turn-command-during-turn",
          },
        }),
      );
      // Pi executes extension commands immediately and returns without
      // queueing, so the accepted dispatch must leave the queue untouched.
      const pending = agentSession.promptCalls.at(-1);
      if (!pending) throw new Error("Expected a pending Pi prompt");
      pending.settled = true;
      pending.options.preflightResult?.(true);
      pending.resolve();
      await drainMicrotasks();

      const results = sentCommandResults(socket, "cmd-command-during-turn");
      expect(results).toEqual([expect.objectContaining({ success: true })]);
      expect(
        (results[0]?.data as { queue?: MessageQueueState } | undefined)?.queue,
      ).toEqual(
        expect.objectContaining({ steering: [], followUp: [] }),
      );
      expect(agentSession.getFollowUpMessages()).toEqual([]);
    });
  });
});

describe("oppi mirror caller session identity", () => {
  it("binds the authoritative hello_ack session id and clears it on disconnect", async () => {
    await withInteractiveTerminal(async () => {
      vi.useFakeTimers();
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      delete process.env[OPPI_CALLER_SESSION_ID_ENV];
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);

      await pi.commands.get("oppi-mirror")?.handler("start", ctx);
      const socket = wsMock.instances.at(-1);
      if (!socket) throw new Error("Expected mirror websocket");
      socket.open();
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBeUndefined();

      socket.receive(
        JSON.stringify({
          type: "hello_ack",
          protocolVersion: 2,
          sessionId: "mirror-session-1",
          workspaceId: "w1",
        }),
      );
      await drainMicrotasks();
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-1");

      socket.close();
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBeUndefined();

      await vi.advanceTimersByTimeAsync(2_000);
      const reconnectSocket = wsMock.instances.at(-1);
      if (!reconnectSocket || reconnectSocket === socket) {
        throw new Error("Expected mirror reconnect websocket");
      }
      reconnectSocket.open();
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBeUndefined();
      reconnectSocket.receive(
        JSON.stringify({
          type: "hello_ack",
          protocolVersion: 2,
          sessionId: "mirror-session-2",
          workspaceId: "w1",
        }),
      );
      await drainMicrotasks();
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-2");
    });
  });

  it("restores a pre-existing caller id when mirroring stops", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      process.env[OPPI_CALLER_SESSION_ID_ENV] = "parent-session";
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      await startMirror(pi, ctx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-1",
        workspaceId: "w1",
      });

      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-1");
      await pi.commands.get("oppi-mirror")?.handler("stop", ctx);
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("parent-session");
    });
  });

  it("does not overwrite a newer environment owner when mirroring stops", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      process.env[OPPI_CALLER_SESSION_ID_ENV] = "parent-session";
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      await startMirror(pi, ctx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-1",
        workspaceId: "w1",
      });

      process.env[OPPI_CALLER_SESSION_ID_ENV] = "newer-owner";
      await pi.commands.get("oppi-mirror")?.handler("stop", ctx);
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("newer-owner");
    });
  });

  it("does not restore a stale id when mirror runtimes overlap", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      process.env[OPPI_CALLER_SESSION_ID_ENV] = "parent-session";

      const firstPi = createMockPi();
      await oppiPiMirror(firstPi as never);
      const firstCtx = createMockContext("pi-session-1");
      await startSession(firstPi, firstCtx);
      await startMirror(firstPi, firstCtx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-1",
        workspaceId: "w1",
      });

      const secondPi = createMockPi();
      await oppiPiMirror(secondPi as never);
      const secondCtx = createMockContext("pi-session-2");
      await startSession(secondPi, secondCtx);
      await startMirror(secondPi, secondCtx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-2",
        workspaceId: "w1",
      });
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-2");

      await firstPi.commands.get("oppi-mirror")?.handler("stop", firstCtx);
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-2");

      await secondPi.commands.get("oppi-mirror")?.handler("stop", secondCtx);
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("parent-session");
    });
  });

  it("clears stale identity and re-registers when Pi switches sessions", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      delete process.env[OPPI_CALLER_SESSION_ID_ENV];
      const firstPi = createMockPi();
      await oppiPiMirror(firstPi as never);
      const firstCtx = createMockContext("pi-session-1");
      await startSession(firstPi, firstCtx);
      const firstSocket = await startMirror(firstPi, firstCtx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-1",
        workspaceId: "w1",
      });
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-1");

      await shutdownSession(firstPi, firstCtx, "new");
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBeUndefined();
      expect(firstSocket.readyState).toBe(wsMock.FakeWebSocket.CLOSED);

      const secondPi = createMockPi();
      await oppiPiMirror(secondPi as never);
      const secondCtx = createMockContext("pi-session-2");
      await startSession(secondPi, secondCtx);
      const secondSocket = await startMirror(secondPi, secondCtx, {
        type: "hello_ack",
        protocolVersion: 2,
        sessionId: "mirror-session-2",
        workspaceId: "w1",
      });
      const hello = secondSocket.sent
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .find((message) => message.type === "hello");
      expect(hello?.state).toMatchObject({ piSessionId: "pi-session-2" });
      expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("mirror-session-2");
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

describe("oppi mirror unix socket connect", () => {
  it("auto-discovers the owner Unix socket and omits the owner bearer token", async () => {
    await withInteractiveTerminal(async () => {
      const { dataDir, configPath } = writeOppiConfig();
      vi.stubEnv("OPPI_CONFIG_PATH", configPath);
      vi.stubEnv("OPPI_DATA_DIR", dataDir);
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      await pi.commands.get("oppi-mirror")?.handler("start", ctx);
      const socket = wsMock.instances.at(-1);
      if (!socket) throw new Error("Expected mirror websocket");

      const socketPath = preferredLocalApiSocketPath(dataDir);
      expect(socket.url).toBe(`ws+unix:${socketPath}:/mirror/v1/bridge`);
      expect(socket.options.headers).toBeUndefined();
    });
  });

  it("uses the same long-path Unix socket fallback as the Oppi server", async () => {
    await withInteractiveTerminal(async () => {
      const { dataDir } = writeOppiConfig();
      const longDataDir = join(dataDir, "x".repeat(90));
      mkdirSync(longDataDir, { recursive: true });
      const configPath = join(longDataDir, "config.json");
      writeFileSync(
        configPath,
        JSON.stringify({
          host: "0.0.0.0",
          port: 7749,
          tls: { mode: "tailscale" },
          token: "sk_unused_owner_token",
        }),
      );
      vi.stubEnv("OPPI_CONFIG_PATH", configPath);
      vi.stubEnv("OPPI_DATA_DIR", longDataDir);
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      await pi.commands.get("oppi-mirror")?.handler("start", ctx);
      const socket = wsMock.instances.at(-1);
      if (!socket) throw new Error("Expected mirror websocket");

      const socketPath = fallbackLocalApiSocketPath(longDataDir);
      expect(preferredLocalApiSocketPath(longDataDir).length).toBeGreaterThan(
        100,
      );
      expect(socket.url).toBe(`ws+unix:${socketPath}:/mirror/v1/bridge`);
      expect(socket.options.headers).toBeUndefined();
    });
  });
});

describe("oppi mirror canonical flush wiring", () => {
  it("flushes enriched message_end before an internal auto_retry_end", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      const entries = new Map<
        string,
        {
          type: string;
          id: string;
          parentId: string | null;
          message?: { role: string; content: unknown };
        }
      >();
      let leafId: string | null = "root";
      ctx.sessionManager.getLeafId = vi.fn(() => leafId);
      ctx.sessionManager.getLeafEntry = vi.fn(() =>
        leafId ? entries.get(leafId) : undefined,
      );
      ctx.sessionManager.getEntry = vi.fn((id: string) => entries.get(id));

      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      const message = { role: "assistant", content: "done" };
      for (const handler of pi.handlers.get("message_end") ?? []) {
        await handler({ type: "message_end", message }, ctx);
      }
      entries.set("persisted-1", {
        type: "message",
        id: "persisted-1",
        parentId: "root",
        message,
      });
      leafId = "persisted-1";

      const bridge = (
        globalThis as typeof globalThis & {
          __oppiMirrorQueueUpdateBridge?: {
            internalEventListeners: Set<(event: unknown) => void>;
          };
        }
      ).__oppiMirrorQueueUpdateBridge;
      expect(bridge).toBeDefined();
      for (const listener of bridge?.internalEventListeners ?? []) {
        listener({ type: "auto_retry_end", success: true, attempt: 1 });
      }

      const events = socket.sent
        .map((line) => JSON.parse(line) as { type?: string; event?: { type?: string; entryId?: string } })
        .filter((frame) => frame.type === "event")
        .map((frame) => frame.event);
      const types = events.map((event) => event?.type);
      expect(types.indexOf("message_end")).toBeGreaterThanOrEqual(0);
      expect(types.indexOf("auto_retry_end")).toBeGreaterThanOrEqual(0);
      expect(types.indexOf("message_end")).toBeLessThan(types.indexOf("auto_retry_end"));
      expect(events.find((event) => event?.type === "message_end")?.entryId).toBe(
        "persisted-1",
      );
    });
  });

  it("forwards non-user/assistant message_end immediately without a pending flush", async () => {
    await withInteractiveTerminal(async () => {
      vi.stubEnv("OPPI_MIRROR_URL", "http://127.0.0.1:1234");
      vi.stubEnv("OPPI_MIRROR_TOKEN", "test-token");
      vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
      const pi = createMockPi();
      await oppiPiMirror(pi as never);
      const ctx = createMockContext();
      await startSession(pi, ctx);
      const socket = await startMirror(pi, ctx);
      socket.sent.length = 0;

      for (const handler of pi.handlers.get("message_end") ?? []) {
        await handler(
          { type: "message_end", message: { role: "custom", content: "lifecycle" } },
          ctx,
        );
      }
      for (const handler of pi.handlers.get("turn_end") ?? []) {
        await handler({ type: "turn_end" }, ctx);
      }

      const events = socket.sent
        .map((line) => JSON.parse(line) as { type?: string; event?: { type?: string; role?: string } })
        .filter((frame) => frame.type === "event")
        .map((frame) => frame.event?.type);
      expect(events.filter((type) => type === "message_end")).toHaveLength(1);
      expect(events.indexOf("message_end")).toBeLessThan(events.indexOf("turn_end"));
    });
  });
});
