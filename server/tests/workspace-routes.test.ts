import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { getPiSessionsRoot } from "../src/local-sessions.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("workspaces module", () => {
  it("handles GET /workspaces in isolation", async () => {
    const ctx = {
      storage: {
        listWorkspaces: vi.fn(() => [{ id: "ws-1", name: "Default" }]),
        listWorkspaceSessionSummarySnapshots: vi.fn(() => [
          {
            workspaceId: "ws-1",
            activeCount: 1,
            stoppedCount: 2,
            hasErrorRoot: false,
            latestActivity: 1_700_000_000_000,
          },
        ]),
      },
      gate: { getPendingForUser: vi.fn(() => []) },
      sessions: { getActiveSessionIds: vi.fn(() => []) },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set<string>()),
        getActiveSession: vi.fn(() => undefined),
        getPendingUIRequestMessages: vi.fn(() => []),
      },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);

    const body = JSON.parse(res.body) as {
      workspaces: unknown[];
      summaries: Array<{ workspaceId: string; activeCount: number; stoppedCount: number }>;
    };
    expect(body.workspaces).toHaveLength(1);
    expect(body.summaries).toEqual([
      expect.objectContaining({ workspaceId: "ws-1", activeCount: 1, stoppedCount: 2 }),
    ]);
  });

  it("marks workspace summaries with pending mirror extension UI requests", async () => {
    const workspace = { id: "ws-1", name: "Default" };
    const session = {
      id: "mirror-1",
      workspaceId: "ws-1",
      status: "busy",
      createdAt: 1,
      lastActivity: 2,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        listWorkspaces: vi.fn(() => [workspace]),
        listWorkspaceSessionSummarySnapshots: vi.fn(() => [
          {
            workspaceId: "ws-1",
            activeCount: 1,
            stoppedCount: 0,
            hasErrorRoot: false,
            latestActivity: 2,
          },
        ]),
      },
      sessions: {
        getActiveSessionIds: vi.fn(() => new Set<string>()),
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set(["mirror-1"])),
        getActiveSession: vi.fn((sessionId: string) =>
          sessionId === "mirror-1" ? session : undefined,
        ),
        getPendingUIRequestMessages: vi.fn((sessionId: string) =>
          sessionId === "mirror-1"
            ? [
                {
                  type: "extension_ui_request",
                  id: "ui-1",
                  sessionId,
                  method: "select",
                  title: "Remote access",
                  options: ["Allow once", "Deny"],
                },
              ]
            : [],
        ),
      },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);

    const body = JSON.parse(res.body) as {
      summaries: Array<{ workspaceId: string; hasAttention: boolean }>;
    };
    expect(body.summaries).toEqual([
      expect.objectContaining({ workspaceId: "ws-1", hasAttention: true }),
    ]);
  });

  it("returns 404 for nonexistent workspace", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => undefined),
      },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/missing",
      url: new URL("http://localhost/workspaces/missing"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Workspace not found" });
  });

  it("handles GET /local-sessions as the global local session list", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-session-route-"));
    const testDir = join(getPiSessionsRoot(), "--test-route-local-sessions--");
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_route-local.jsonl");

    try {
      mkdirSync(testDir, { recursive: true });
      writeFileSync(
        filePath,
        [
          JSON.stringify({
            type: "session",
            id: "route-local",
            cwd: "/tmp/project",
            timestamp: "2026-02-20T00:00:00.000Z",
          }),
          JSON.stringify({
            type: "session_info",
            name: "Route Local Session",
          }),
        ].join("\n") + "\n",
      );

      const ctx = {
        storage: {
          listSessions: vi.fn(() => []),
          getDataDir: vi.fn(() => dataDir),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/local-sessions",
        url: new URL("http://localhost/local-sessions"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { sessions: Array<{ piSessionId: string }> };
      expect(body.sessions.some((session) => session.piSessionId === "route-local")).toBe(true);
    } finally {
      rmSync(testDir, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("filters GET /local-sessions by canonical Pi session identities", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-session-known-route-"));
    const testDir = join(getPiSessionsRoot(), "--test-route-local-sessions-known--");
    const filePath = join(testDir, "2026-02-20T00-00-00-000Z_route-known.jsonl");

    try {
      mkdirSync(testDir, { recursive: true });
      writeFileSync(
        filePath,
        [
          JSON.stringify({
            type: "session",
            id: "route-known",
            cwd: "/tmp/project",
            timestamp: "2026-02-20T00:00:00.000Z",
          }),
        ].join("\n") + "\n",
      );

      const ctx = {
        storage: {
          listSessions: vi.fn(() => [{ id: "managed-1", piSessionId: "route-known" }]),
          getDataDir: vi.fn(() => dataDir),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/local-sessions",
        url: new URL("http://localhost/local-sessions"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { sessions: Array<{ piSessionId: string }> };
      expect(body.sessions.some((session) => session.piSessionId === "route-known")).toBe(false);
    } finally {
      rmSync(testDir, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("validates name on POST /workspaces", async () => {
    const ctx = {} as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: makeRequest({}) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "name required" });
  });

  it("passes legacy resource fields through to storage for compatibility", async () => {
    const ctx = {
      storage: { createWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })) },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: makeRequest({ name: "Test", skills: ["fetch"], extensions: ["ask"] }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(201);
    expect(ctx.storage.createWorkspace).toHaveBeenCalledWith(
      expect.objectContaining({ skills: ["fetch"], extensions: ["ask"] }),
    );
  });

  it("rejects replace systemPromptMode on POST /workspaces", async () => {
    const ctx = {
      skillRegistry: { get: vi.fn() },
      storage: { createWorkspace: vi.fn() },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: makeRequest({ name: "Test", systemPromptMode: "replace" }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "systemPromptMode must be append" });
    expect(ctx.storage.createWorkspace).not.toHaveBeenCalled();
  });

  it("rejects replace systemPromptMode on PUT /workspaces/:id", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        updateWorkspace: vi.fn(),
      },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "PUT",
      path: "/workspaces/ws-1",
      url: new URL("http://localhost/workspaces/ws-1"),
      req: makeRequest({ systemPromptMode: "replace" }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "systemPromptMode must be append" });
    expect(ctx.storage.updateWorkspace).not.toHaveBeenCalled();
  });

  it("rejects missing hostMount on POST /workspaces", async () => {
    const missing = join(tmpdir(), `oppi-route-missing-workspace-${Date.now()}`);
    rmSync(missing, { recursive: true, force: true });
    const ctx = {
      skillRegistry: { get: vi.fn() },
      storage: { createWorkspace: vi.fn() },
    } as unknown as RouteContext;

    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces",
      url: new URL("http://localhost/workspaces"),
      req: makeRequest({ name: "Test", hostMount: missing }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toContain("Host working directory does not exist");
    expect(ctx.storage.createWorkspace).not.toHaveBeenCalled();
  });

  it("does not handle review comment routes", async () => {
    const dispatch = createWorkspaceRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/review/comments/attach-to-turn",
      url: new URL("http://localhost/workspaces/ws-1/review/comments/attach-to-turn"),
      req: makeRequest({ ids: ["rc-1"] }) as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });

  it("does not handle retired GET /tui-sessions route", async () => {
    const dispatch = createWorkspaceRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/tui-sessions",
      url: new URL("http://localhost/tui-sessions"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createWorkspaceRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/not/a/workspace",
      url: new URL("http://localhost/not/a/workspace"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});
