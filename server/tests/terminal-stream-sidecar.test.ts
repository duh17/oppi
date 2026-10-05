import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { createSessionTraceRouteHandlers } from "../src/routes/session-trace-handlers.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "../src/session-agent-events.js";
import { SessionEventProcessor } from "../src/session-events.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import type { Storage } from "../src/storage.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { ServerMessage, Session } from "../src/types.js";

type ToolOutput = Extract<ServerMessage, { type: "tool_output" }>;

const cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const fn of cleanup.splice(0).reverse()) await fn();
});

/**
 * The real event coordinator (path publication), translator, trace service and sidecar
 * route handler, wired as the managed runtime wires them.
 */
async function harness() {
  const root = mkdtempSync(join(tmpdir(), "oppi-terminal-sidecar-"));
  cleanup.push(() => rmSync(root, { recursive: true, force: true }));
  const jsonl = join(root, "session.jsonl");
  writeFileSync(jsonl, "");
  const session = {
    id: "sess-1",
    workspaceId: "w1",
    status: "busy",
    piSessionFile: jsonl,
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  } as Session;
  const active: SessionAgentEventState = {
    session,
    pendingUIRequests: new Map(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    streamingToolUpdatesSeen: new Map(),
    shellPreviewLastSent: new Map(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    sdkBackend: { sessionTree: () => undefined, toolDefinition: () => undefined } as never,
    subscribers: new Set(),
    toolFullOutputPaths: new Map(),
  } as unknown as SessionAgentEventState;
  const registry = new MobileRendererRegistry();
  const received: ServerMessage[] = [];
  const coordinator = new SessionAgentEventCoordinator({
    getActiveSession: vi.fn(() => active),
    eventProcessor: new SessionEventProcessor({
      mobileRenderers: registry,
      storage: { getWorkspace: vi.fn(() => null) } as unknown as Storage,
      broadcast: (_key, message) => received.push(message),
      persistSessionNow: vi.fn(),
      markSessionDirty: vi.fn(),
    }),
    stopCoordinator: { finishPendingStopOnAgentEnd: vi.fn() } as never,
    turnCoordinator: { markNextTurnStarted: vi.fn() } as never,
    broadcast: (_key, message) => received.push(message),
    resetIdleTimer: vi.fn(),
  });
  const runtimes = {
    getToolFullOutputPath: (_sessionId: string, id: string) =>
      active.toolFullOutputPaths.get(id) ?? null,
    getToolPartialOutput: (_sessionId: string, id: string) =>
      active.toolOutputSnapshots.fullOutput(id),
    refreshSessionState: async () => session,
  };
  const storage = {
    getDataDir: () => root,
    getSession: () => session,
    getWorkspace: () => undefined,
  };
  const service = new SessionTraceService({
    storage,
    sessionRuntimes: runtimes,
    ensureSessionContextWindow: (s) => s,
    mobileRenderers: registry,
  });
  const helpers = {
    error: (res: ServerResponse, status: number, error: string) => {
      res.writeHead(status);
      res.end(error);
    },
    compressedJson: (_req: IncomingMessage, res: ServerResponse, value: unknown) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(value));
    },
  };
  const handlers = createSessionTraceRouteHandlers(
    {
      storage,
      sessionRuntimes: runtimes,
      sessions: { mobileRenderer: registry },
      ensureSessionContextWindow: (s: Session) => s,
    } as never,
    helpers as never,
    () => session,
    () => session,
  );
  const server: Server = createServer((req, res) => {
    void handlers
      .handleGetFullToolOutput("w1", "sess-1", "tc", req, res, req.method)
      .catch((error) => res.destroy(error));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanup.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing HTTP address");
  const url = `http://127.0.0.1:${address.port}/full`;

  const ingest = (event: Record<string, unknown>): ToolOutput[] => {
    const before = received.length;
    coordinator.handlePiEvent(session.id, {
      toolCallId: "tc",
      toolName: "bash",
      ...event,
    } as unknown as SessionBackendEvent);
    return received.slice(before).filter((m): m is ToolOutput => m.type === "tool_output");
  };
  const range = async (start: number, end: number) => {
    const response = await fetch(url, { headers: { Range: `bytes=${start}-${end}` } });
    return { status: response.status, bytes: Buffer.from(await response.arrayBuffer()) };
  };
  return { active, received, ingest, range, url, root };
}

const streamed = (chunks: ToolOutput[]) =>
  Buffer.from(chunks.map((c) => c.output).join(""), "utf8");

const phase1 = Array.from({ length: 40 }, (_, i) => `row-${i} 🙂\n`).join("");
const truncatedDetails = (path: string) => ({
  truncation: { truncated: true, totalBytes: 200_000 },
  fullOutputPath: path,
});

describe("terminal preview sidecar source", () => {
  it("publishes a named Pi file immediately and serves that file, even when it is short", async () => {
    const h = await harness();
    const path = join(h.root, "pi-bash.log");
    h.ingest({ type: "tool_execution_start", args: {} });
    const first = h.ingest({
      type: "tool_execution_update",
      partialResult: { content: [{ type: "text", text: phase1 }], details: {} },
    });
    expect(first.some((message) => "outputStream" in message)).toBe(false);
    expect(streamed(first).toString("utf8")).toBe(phase1);

    writeFileSync(path, "row-0");
    h.ingest({
      type: "tool_execution_update",
      partialResult: {
        content: [{ type: "text", text: "tail of a truncated view" }],
        details: truncatedDetails(path),
      },
    });
    expect(h.active.toolFullOutputPaths.get("tc")).toBe(path);
    const head = await fetch(h.url, { method: "HEAD" });
    expect(Number(head.headers.get("content-length"))).toBe(Buffer.byteLength("row-0"));
    const window = await h.range(0, 4);
    expect(window.status).toBe(206);
    expect(window.bytes.toString("utf8")).toBe("row-0");
  });

  it("does not invent a byte cursor when the named file is missing", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const h = await harness();
    const missing = join(h.root, "never-written.log");
    h.ingest({ type: "tool_execution_start", args: {} });
    h.ingest({
      type: "tool_execution_update",
      partialResult: { content: [{ type: "text", text: phase1 }], details: {} },
    });
    h.ingest({
      type: "tool_execution_update",
      partialResult: {
        content: [{ type: "text", text: "tail" }],
        details: truncatedDetails(missing),
      },
    });
    const done = h.received.length;
    h.ingest({
      type: "tool_execution_end",
      isError: false,
      result: {
        content: [{ type: "text", text: "tail\n\n[Showing lines. Full output: x]" }],
        details: truncatedDetails(missing),
      },
    });
    const end = h.received.slice(done).find((m) => m.type === "tool_end");
    expect(end).not.toHaveProperty("outputStream");
    expect(h.active.toolFullOutputPaths.get("tc")).toBe(missing);
    expect(h.received.some((message) => "outputStream" in message)).toBe(false);
    const logged = stderr.mock.calls.map(([line]) => String(line)).join("");
    expect(logged).not.toContain("terminal_stream.file_read_failed");
    expect(logged).not.toContain(missing);

    h.ingest({ type: "turn_end", toolCallId: undefined });
    expect(h.active.toolOutputSnapshots.size).toBe(0);
  });
});
