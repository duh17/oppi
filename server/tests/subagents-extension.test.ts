import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createOppiSubagentsExtension } from "../extensions/oppi-subagents.js";

interface RegisteredTool {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: unknown) => void,
    ctx?: MockExtensionContext,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    details?: Record<string, unknown>;
    isError?: boolean;
  }>;
}

interface CapturedRequest {
  method: string;
  path: string;
  search: string;
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
  hasUI: boolean;
  sessionManager: {
    getSessionId: () => string;
    getSessionFile: () => string;
  };
  isIdle: ReturnType<typeof vi.fn>;
  hasPendingMessages: ReturnType<typeof vi.fn>;
  ui: {
    setWidget: ReturnType<typeof vi.fn>;
    notify: ReturnType<typeof vi.fn>;
  };
}

const shutdownHandlers: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const shutdown of shutdownHandlers.splice(0)) await shutdown();
});

function createMockPi(activeTools = ["read", "spawn_agent", "inspect_agent", "send_message"]): MockPi {
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

function createMockContext(
  options: { idle?: boolean; hasPendingMessages?: boolean } = {},
): MockExtensionContext {
  return {
    cwd: "/workspace/project",
    hasUI: true,
    sessionManager: {
      getSessionId: () => "pi-parent",
      getSessionFile: () => "/tmp/pi-parent.jsonl",
    },
    isIdle: vi.fn(() => options.idle ?? true),
    hasPendingMessages: vi.fn(() => options.hasPendingMessages ?? false),
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

async function startApiServer(
  handler: (req: IncomingMessage, res: ServerResponse, body: Record<string, unknown>) => void,
): Promise<{ baseUrl: string; requests: CapturedRequest[]; close: () => Promise<void> }> {
  const requests: CapturedRequest[] = [];
  const server = createServer((req, res) => {
    void readBody(req)
      .then((body) => {
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        requests.push({
          method: req.method ?? "GET",
          path: url.pathname,
          search: url.search,
          body,
        });
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

async function waitUntil(predicate: () => boolean, timeoutMs = 500): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("Timed out waiting for predicate");
}

function session(overrides: Record<string, unknown>): Record<string, unknown> {
  return {
    id: "session-1",
    name: "Session",
    status: "ready",
    workspaceId: "ws-1",
    createdAt: 1,
    lastActivity: 2,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

describe("oppi-subagents native extension", () => {
  it("spawns through generic workspace sessions and renders only minimal status metadata", async () => {
    const parent = session({ id: "parent-1", name: "Parent", piSessionId: "pi-parent" });
    const child = session({
      id: "child-1",
      name: "review auth",
      status: "starting",
      parentSessionId: "parent-1",
      messageCount: 1,
      contextTokens: 4_000,
      contextWindow: 8_000,
      lastMessage: "tool command snapshot that should not be ambient UI",
    });
    const api = await startApiServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (url.pathname === "/sessions/recent") {
        writeJson(res, 200, { sessions: [parent] });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions" && req.method === "GET") {
        writeJson(res, 200, { active: [] });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions" && req.method === "POST") {
        writeJson(res, 201, { session: child });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions/child-1") {
        writeJson(res, 200, { session: child, trace: [] });
        return;
      }
      writeJson(res, 404, { error: "not found" });
    });
    shutdownHandlers.push(api.close);
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: { version: 1, baseUrl: api.baseUrl, canSpawn: true },
    });
    const ctx = await emitSessionStart(pi);
    await waitUntil(() => api.requests.some((request) => request.path === "/sessions/recent"));

    const result = await pi.tools.get("spawn_agent")?.execute(
      "tc-1",
      {
        message: "Check auth changes",
        name: "review auth",
        profile: "review",
      },
      undefined,
      undefined,
      ctx,
    );

    const createRequest = api.requests.find(
      (request) => request.method === "POST" && request.path === "/workspaces/ws-1/sessions",
    );
    expect(createRequest?.body.parentSessionId).toBe("parent-1");
    expect(createRequest?.body.prompt).toContain("[Subagent profile: review]");
    expect(createRequest?.body.prompt).toContain("Check auth changes");
    expect(api.requests.some((request) => request.path.includes("/subagents/bridge"))).toBe(false);
    expect(result?.content[0].text).toContain('Spawned agent "review auth"');

    const widgetFactory = ctx.ui.setWidget.mock.calls[0]?.[1] as (tui: unknown) => {
      renderNative: () => { blocks: Array<{ rows: Array<Record<string, unknown>> }> };
    };
    const native = widgetFactory({ requestRender: vi.fn() }).renderNative();
    const row = native.blocks[0].rows[0];
    expect(row.title).toBe("review auth");
    expect(row.subtitle).toBe("Starting · 4k/8k ctx");
    expect(JSON.stringify(row)).not.toContain("tool command snapshot");

    emitSessionShutdown(pi);
  });

  it("sends messages through the generic session command endpoint", async () => {
    const parent = session({ id: "parent-1", name: "Parent Agent" });
    const target = session({ id: "target-1", name: "Target", status: "busy" });
    const api = await startApiServer((req, res, body) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (url.pathname === "/workspaces/ws-1/sessions/parent-1") {
        writeJson(res, 200, { session: parent, trace: [] });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions/target-1" && req.method === "GET") {
        writeJson(res, 200, { session: target, trace: [] });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions/target-1/command") {
        writeJson(res, 200, {
          messages: [
            {
              type: "command_result",
              requestId: body.requestId,
              command: body.type,
              success: true,
            },
          ],
        });
        return;
      }
      if (url.pathname === "/workspaces/ws-1/sessions" && req.method === "GET") {
        writeJson(res, 200, { active: [target] });
        return;
      }
      writeJson(res, 404, { error: "not found" });
    });
    shutdownHandlers.push(api.close);
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: {
        version: 1,
        baseUrl: api.baseUrl,
        originSessionId: "parent-1",
        workspaceId: "ws-1",
        canSpawn: true,
      },
    });
    const ctx = await emitSessionStart(pi);
    await waitUntil(() => api.requests.some((request) => request.path === "/workspaces/ws-1/sessions/parent-1"));

    const result = await pi.tools.get("send_message")?.execute(
      "tc-send",
      { id: "target-1", message: "please inspect this" },
      undefined,
      undefined,
      ctx,
    );

    const commandRequest = api.requests.find(
      (request) => request.method === "POST" && request.path === "/workspaces/ws-1/sessions/target-1/command",
    );
    expect(commandRequest?.body.type).toBe("steer");
    expect(commandRequest?.body.message).toContain('[From agent "Parent Agent" (parent-1)]');
    expect(commandRequest?.body.message).toContain("please inspect this");
    expect(api.requests.some((request) => request.path.includes("/subagents/bridge"))).toBe(false);
    expect(result?.content[0].text).toContain("Message sent to target-1");

    emitSessionShutdown(pi);
  });

  it("registers the non-spawning subset when canSpawn is false", () => {
    const pi = createMockPi();

    createOppiSubagentsExtension(pi as never, {
      descriptor: {
        version: 1,
        baseUrl: "http://127.0.0.1:1",
        originSessionId: "child-1",
        workspaceId: "ws-1",
        canSpawn: false,
      },
    });

    expect([...pi.tools.keys()].sort()).toEqual(["inspect_agent", "send_message"]);
  });

  it("does not register the retired subagents bridge route module", () => {
    const routesIndex = readFileSync(new URL("../src/routes/index.ts", import.meta.url), "utf8");

    expect(routesIndex).not.toContain("subagents-bridge");
    expect(routesIndex).not.toContain("createSubagentsBridgeRoutes");
  });
});
