import { afterEach, describe, expect, it, vi } from "vitest";

import oppiPiMirror from "./oppi-mirror.js";

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
}

interface MockExtensionContext {
  cwd: string;
  hasUI: boolean;
  mode: "tui";
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
  };
}

function createMockContext(): MockExtensionContext {
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
      getSessionId: vi.fn(() => "pi-session-1"),
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
): Promise<(typeof wsMock.instances)[number]> {
  await pi.commands.get("oppi-mirror")?.handler("start", ctx);
  const socket = wsMock.instances.at(-1);
  if (!socket) throw new Error("Expected mirror websocket");
  socket.open();
  socket.receive(
    JSON.stringify({ type: "hello_ack", sessionId: "s1", workspaceId: "w1" }),
  );
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
  vi.unstubAllEnvs();
  vi.useRealTimers();
});

describe("oppi mirror extension UI replay", () => {
  it("persists Pi lifecycle evidence in TUI session entries", async () => {
    vi.stubEnv("OPPI_MIRROR_AUTO_START", "false");
    const pi = createMockPi();
    await oppiPiMirror(pi as never);
    const ctx = createMockContext();

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
