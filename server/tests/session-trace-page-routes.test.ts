import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let tmpDir: string | undefined;

afterEach(() => {
  if (tmpDir) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = undefined;
  }
});

function writeTrace(): string {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-page-route-test-"));
  const path = join(tmpDir, "session.jsonl");
  const timestamp = "2026-01-01T00:00:00.000Z";
  const lines = [
    {
      type: "message",
      id: "u1",
      parentId: null,
      timestamp,
      message: { role: "user", content: "first" },
    },
    {
      type: "message",
      id: "a1",
      parentId: "u1",
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: "tc-1", name: "bash", arguments: { command: "echo" } }],
      },
    },
    {
      type: "message",
      id: "r1",
      parentId: "a1",
      timestamp,
      message: {
        role: "toolResult",
        toolCallId: "tc-1",
        toolName: "bash",
        content: "abcdefghijklmnopqrstuvwxyz",
      },
    },
  ];
  writeFileSync(path, lines.map((line) => JSON.stringify(line)).join("\n"));
  return path;
}

function writeCanonicalTraceFiles(dataDir: string, workspaceId: string, sessionId: string): void {
  const traceDir = join(
    dataDir,
    workspaceId,
    "sessions",
    sessionId,
    "agent",
    "sessions",
    "--work--",
  );
  mkdirSync(traceDir, { recursive: true });
  const timestamp = "2026-01-01T00:00:00.000Z";
  const firstFile = [
    {
      type: "message",
      id: "u1",
      parentId: null,
      timestamp,
      message: { role: "user", content: "first prompt" },
    },
    {
      type: "message",
      id: "a1",
      parentId: "u1",
      timestamp,
      message: { role: "assistant", content: [{ type: "text", text: "first answer" }] },
    },
  ];
  const secondFile = [
    {
      type: "message",
      id: "u2",
      parentId: "a1",
      timestamp,
      message: { role: "user", content: "second prompt" },
    },
    {
      type: "message",
      id: "a2",
      parentId: "u2",
      timestamp,
      message: { role: "assistant", content: [{ type: "text", text: "second answer" }] },
    },
  ];

  writeFileSync(
    join(traceDir, "20260101T000000Z-first.jsonl"),
    firstFile.map((line) => JSON.stringify(line)).join("\n"),
  );
  writeFileSync(
    join(traceDir, "20260101T000100Z-second.jsonl"),
    secondFile.map((line) => JSON.stringify(line)).join("\n"),
  );
}

describe("workspace session trace page route", () => {
  it("returns an empty trace page so clients can use first-message fallback", async () => {
    const session: Session = {
      id: "empty",
      workspaceId: "ws-1",
      status: "ready",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      firstMessage: "Hello from summary",
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => null),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/empty/trace-page",
      url: new URL(
        "http://localhost/workspaces/ws-1/sessions/empty/trace-page?targetEvents=1&previewBytes=8",
      ),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      session: { firstMessage?: string };
      trace: unknown[];
      page: { hasOlder: boolean; olderCursor: string | null; staleCursor: boolean };
    };
    expect(body.session.firstMessage).toBe("Hello from summary");
    expect(body.trace).toEqual([]);
    expect(body.page).toMatchObject({ hasOlder: false, olderCursor: null, staleCursor: false });
  });

  it("reads canonical multi-file trace directories when the session has no explicit JSONL path", async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "trace-page-canonical-test-"));
    writeCanonicalTraceFiles(tmpDir, "ws-1", "s1");
    const session: Session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "stopped",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => null),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/trace-page",
      url: new URL(
        "http://localhost/workspaces/ws-1/sessions/s1/trace-page?targetEvents=10&previewBytes=8",
      ),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      trace: Array<{ id: string; text?: string }>;
      page: { hasOlder: boolean; staleCursor: boolean };
    };
    expect(body.trace.map((event) => event.id)).toEqual(["u1", "a1-text-0", "u2", "a2-text-0"]);
    expect(body.trace.map((event) => event.text)).toEqual([
      "first prompt",
      "first answer",
      "second prompt",
      "second answer",
    ]);
    expect(body.page).toMatchObject({ hasOlder: false, staleCursor: false });
  });

  it("returns a page around a requested outline entry", async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "trace-page-around-route-test-"));
    writeCanonicalTraceFiles(tmpDir, "ws-1", "s1");
    const session: Session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "stopped",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => null),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/trace-page",
      url: new URL(
        "http://localhost/workspaces/ws-1/sessions/s1/trace-page?aroundEntryId=u2&targetEvents=2&previewBytes=8",
      ),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      trace: Array<{ id: string; text?: string }>;
      page: { hasOlder: boolean; staleCursor: boolean };
    };
    expect(body.trace.map((event) => event.id)).toContain("u2");
    expect(body.trace.some((event) => event.id === "a2-text-0")).toBe(false);
    expect(body.page).toMatchObject({ hasOlder: true, staleCursor: false });
  });

  it("rejects an initial page when the live tree leaf is missing from the trace", async () => {
    const tracePath = writeTrace();
    const session: Session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "ready",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      piSessionFile: tracePath,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => ({
          sessionFile: tracePath,
          leafId: "missing-live-leaf",
        })),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/trace-page",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/trace-page?targetEvents=2"),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(409);
    expect(res.body).toContain("Session trace is not synchronized with the active tree leaf");
  });

  it("returns an opt-in latest trace page without changing the full session route", async () => {
    const tracePath = writeTrace();
    const session: Session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "stopped",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      piSessionFile: tracePath,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => null),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/trace-page",
      url: new URL(
        "http://localhost/workspaces/ws-1/sessions/s1/trace-page?targetEvents=1&previewBytes=8",
      ),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      session: { id: string };
      trace: Array<{ id: string; output?: string; outputTruncated?: boolean }>;
      page: { hasOlder: boolean; olderCursor: string | null; previewBytes: number };
      metrics: {
        traceEventCount: number;
        selectedRawEntryCount: number;
        jsonBytes: number;
        gzipBytes: number;
        stringifyMs: number;
        gzipMs: number;
      };
    };
    expect(body.session.id).toBe("s1");
    expect(body.trace.map((event) => event.id)).toEqual(["tc-1", "result-r1"]);
    expect(body.trace[1]?.output).toBe("abcdefgh");
    expect(body.trace[1]?.outputTruncated).toBe(true);
    expect(body.page.previewBytes).toBe(8);
    expect(body.metrics.traceEventCount).toBe(2);
    expect(body.metrics.jsonBytes).toBeGreaterThan(0);
    expect(body.metrics.gzipBytes).toBeGreaterThan(0);
    expect(body.metrics.stringifyMs).toBeGreaterThanOrEqual(0);
    expect(body.metrics.gzipMs).toBeGreaterThanOrEqual(0);
  });
});
