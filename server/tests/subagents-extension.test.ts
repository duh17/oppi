import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createOppiSubagentsExtension } from "../extensions/oppi-subagents.js";

interface RegisteredTool {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: unknown) => void,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    details?: Record<string, unknown>;
    isError?: boolean;
  }>;
}

interface CapturedRequest {
  method: string;
  path: string;
  body: Record<string, unknown>;
}

interface MockPi {
  tools: Map<string, RegisteredTool>;
  handlers: Map<string, Array<(event: unknown, ctx: MockExtensionContext) => unknown>>;
  sendMessage: ReturnType<typeof vi.fn>;
  getActiveTools: ReturnType<typeof vi.fn>;
  setActiveTools: ReturnType<typeof vi.fn>;
}

interface MockExtensionContext {
  cwd: string;
  sessionManager: {
    getSessionId: () => string;
    getSessionFile: () => string;
  };
  ui: {
    setWidget: ReturnType<typeof vi.fn>;
    notify: ReturnType<typeof vi.fn>;
  };
}

const shutdownHandlers: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const shutdown of shutdownHandlers.splice(0)) await shutdown();
});

function createMockPi(
  activeTools = ["read", "spawn_agent", "inspect_agent", "send_message"],
): MockPi {
  const tools = new Map<string, RegisteredTool>();
  const handlers = new Map<string, Array<(event: unknown, ctx: MockExtensionContext) => unknown>>();
  let currentActiveTools = [...activeTools];
  return {
    tools,
    handlers,
    sendMessage: vi.fn(),
    getActiveTools: vi.fn(() => currentActiveTools),
    setActiveTools: vi.fn((names: string[]) => {
      currentActiveTools = names;
    }),
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
    on(event: string, handler: (event: unknown, ctx: MockExtensionContext) => unknown) {
      const eventHandlers = handlers.get(event) ?? [];
      eventHandlers.push(handler);
      handlers.set(event, eventHandlers);
    },
  } as MockPi;
}

function createMockContext(): MockExtensionContext {
  return {
    cwd: "/workspace/project",
    sessionManager: {
      getSessionId: () => "pi-parent",
      getSessionFile: () => "/tmp/pi-parent.jsonl",
    },
    ui: {
      setWidget: vi.fn(),
      notify: vi.fn(),
    },
  };
}

async function emitSessionStart(
  pi: MockPi,
  ctx = createMockContext(),
): Promise<MockExtensionContext> {
  for (const handler of pi.handlers.get("session_start") ?? []) {
    await handler({ reason: "startup" }, ctx);
  }
  await new Promise((resolve) => setTimeout(resolve, 20));
  return ctx;
}

function emitSessionShutdown(pi: MockPi): void {
  for (const handler of pi.handlers.get("session_shutdown") ?? []) {
    handler({}, createMockContext());
  }
}

async function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? (JSON.parse(text) as Record<string, unknown>) : {};
}

function writeJson(res: ServerResponse, status: number, value: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(value));
}

async function startBridgeServer(
  handler: (req: IncomingMessage, res: ServerResponse, body: Record<string, unknown>) => void,
): Promise<{ baseUrl: string; requests: CapturedRequest[]; close: () => Promise<void> }> {
  const requests: CapturedRequest[] = [];
  const server = createServer((req, res) => {
    void readBody(req)
      .then((body) => {
        const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
        requests.push({ method: req.method ?? "GET", path, body });
        handler(req, res, body);
      })
      .catch((error: unknown) => {
        writeJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
      });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("server did not bind to a port");
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    requests,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

describe("oppi-subagents native extension", () => {
  it("registers the child-session tool subset when canSpawn is false", async () => {
    const bridge = await startBridgeServer((_req, res) => {
      writeJson(res, 200, { sessions: [] });
    });
    shutdownHandlers.push(bridge.close);
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: {
        version: 1,
        baseUrl: bridge.baseUrl,
        originSessionId: "child-1",
        workspaceId: "ws-1",
        canSpawn: false,
      },
    });
    const ctx = await emitSessionStart(pi);

    expect([...pi.tools.keys()].sort()).toEqual(["inspect_agent", "send_message"]);
    expect(ctx.ui.setWidget).toHaveBeenCalledWith("subagents", expect.any(Function), {
      placement: "aboveEditor",
    });
  });

  it("spawns through the public bridge and applies built-in profiles", async () => {
    const bridge = await startBridgeServer((req, res) => {
      const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
      if (path === "/sessions") {
        writeJson(res, 200, { sessions: [] });
        return;
      }
      if (path === "/spawn") {
        writeJson(res, 201, {
          session: {
            id: "child-1",
            name: "review auth",
            status: "starting",
            workspaceId: "ws-1",
            parentSessionId: "parent-1",
            createdAt: 1,
            lastActivity: 2,
            messageCount: 0,
          },
        });
        return;
      }
      writeJson(res, 404, { error: "not found" });
    });
    shutdownHandlers.push(bridge.close);
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: {
        version: 1,
        baseUrl: bridge.baseUrl,
        originSessionId: "parent-1",
        workspaceId: "ws-1",
        canSpawn: true,
      },
    });
    await emitSessionStart(pi);

    const result = await pi.tools.get("spawn_agent")?.execute("tc-1", {
      message: "Check auth changes",
      name: "review auth",
      profile: "review",
    });

    const spawnRequest = bridge.requests.find((request) => request.path === "/spawn");
    expect(spawnRequest?.body.originSessionId).toBe("parent-1");
    expect(spawnRequest?.body.prompt).toContain("[Subagent profile: review]");
    expect(spawnRequest?.body.prompt).toContain("Check auth changes");
    expect(result?.content[0].text).toContain('Spawned agent "review auth"');
  });

  it("uses bridge resolution to disable spawn_agent for child sessions without wrappers", async () => {
    const bridge = await startBridgeServer((req, res) => {
      const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
      if (path === "/resolve") {
        writeJson(res, 200, {
          descriptor: {
            version: 1,
            originSessionId: "child-1",
            workspaceId: "ws-1",
            runtime: "sdk",
            canSpawn: false,
          },
        });
        return;
      }
      if (path === "/sessions") {
        writeJson(res, 200, { sessions: [] });
        return;
      }
      writeJson(res, 404, { error: "not found" });
    });
    shutdownHandlers.push(bridge.close);
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: { version: 1, baseUrl: bridge.baseUrl, canSpawn: true },
    });
    await emitSessionStart(pi);

    expect(pi.tools.has("spawn_agent")).toBe(true);
    expect(pi.setActiveTools).toHaveBeenCalledWith(["read", "inspect_agent", "send_message"]);
    const resolveRequest = bridge.requests.find((request) => request.path === "/resolve");
    expect(resolveRequest?.body.piSessionId).toBe("pi-parent");
    expect(resolveRequest?.body.piSessionFile).toBe("/tmp/pi-parent.jsonl");
  });
});
