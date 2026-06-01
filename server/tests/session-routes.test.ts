import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeResponse } from "./harness/route-test-helpers.js";

describe("sessions module", () => {
  it("handles GET workspace sessions in isolation", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        listAllWorkspaceSessionSnapshots: vi.fn(() => [
          {
            id: "s1",
            workspaceId: "ws-1",
            status: "ready",
            createdAt: 0,
            lastActivity: 10,
            messageCount: 0,
            tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            cost: 0,
          },
        ]),
        listStoppedWorkspaceTimeRangeSessionSnapshots: vi.fn(() => [
          {
            id: "stopped-1",
            workspaceId: "ws-1",
            status: "stopped",
            createdAt: 0,
            lastActivity: 20,
            messageCount: 0,
            tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            cost: 0,
          },
        ]),
        listSessions: vi.fn(() => []),
        getDataDir: vi.fn(() => tmpdir()),
      },
      sessions: {
        getActiveSessionIds: vi.fn(() => new Set()),
        getActiveSession: vi.fn(() => undefined),
        getPendingAskMessage: vi.fn(() => undefined),
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
        getActiveSession: vi.fn(() => undefined),
        getPendingAskMessage: vi.fn(() => undefined),
        getPendingUIRequestMessages: vi.fn(() => []),
      },
      gate: { getPendingForUser: vi.fn(() => []) },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions",
      url: new URL(
        "http://localhost/workspaces/ws-1/sessions?status=active,stopped&sinceMs=0&untilMs=1000",
      ),
      req: {
        url: "/workspaces/ws-1/sessions?status=active,stopped&sinceMs=0&untilMs=1000",
      } as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);

    const body = JSON.parse(res.body) as {
      active: Array<{ id: string }>;
      stopped: Array<{ id: string }>;
    };
    expect(body.active.map((session) => session.id)).toEqual(["s1"]);
    expect(body.stopped.map((session) => session.id)).toEqual(["stopped-1"]);
  });

  it("merges active in-memory sessions into workspace session snapshots", async () => {
    const activeSession = {
      id: "active-1",
      workspaceId: "ws-1",
      status: "busy",
      createdAt: 0,
      lastActivity: 20,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        listAllWorkspaceSessionSnapshots: vi.fn(() => []),
        listSessions: vi.fn(() => []),
        getDataDir: vi.fn(() => tmpdir()),
      },
      sessions: {
        getActiveSessionIds: vi.fn(() => new Set(["active-1"])),
        getActiveSession: vi.fn(() => activeSession),
        getPendingAskMessage: vi.fn(() => undefined),
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set(["active-1"])),
        getActiveSession: vi.fn(() => activeSession),
        getPendingAskMessage: vi.fn(() => undefined),
        getPendingUIRequestMessages: vi.fn(() => []),
      },
      gate: { getPendingForUser: vi.fn(() => []) },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions",
      url: new URL("http://localhost/workspaces/ws-1/sessions?status=active"),
      req: { url: "/workspaces/ws-1/sessions?status=active" } as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as { active: Array<{ id: string }> };
    expect(body.active.map((session) => session.id)).toEqual(["active-1"]);
  });

  it("returns 404 for workspace sessions in nonexistent workspace", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => undefined),
      },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/missing/sessions",
      url: new URL("http://localhost/workspaces/missing/sessions?status=active"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Workspace not found" });
  });

  it("returns 404 for tool output with missing session", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => undefined),
      },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/tool-output/tc-1",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/tool-output/tc-1"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Session not found" });
  });

  it("returns full tool output from disk", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-tool-output-full-"));
    try {
      const fullOutputPath = join(dataDir, "tc-1.full.txt");
      writeFileSync(fullOutputPath, "complete tool output", "utf8");

      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
        },
        sessions: {
          getToolFullOutputPath: vi.fn(() => fullOutputPath),
        },
        sessionRuntimes: {
          getToolFullOutputPath: vi.fn(() => fullOutputPath),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/s1/tool-output/tc-1",
        url: new URL("http://localhost/workspaces/ws-1/sessions/s1/tool-output/tc-1?full=true"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body)).toEqual({
        toolCallId: "tc-1",
        output: "complete tool output",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("lists session changes on the resource-shaped route", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => ({
          id: "s1",
          workspaceId: "ws-1",
          changeStats: {
            filesChanged: 2,
            changedFiles: ["src/App.swift", "README.md"],
            changedFilesOverflow: 1,
          },
        })),
      },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/changes",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/changes"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      workspaceId: "ws-1",
      sessionId: "s1",
      files: [{ path: "src/App.swift" }, { path: "README.md" }],
      changedFileCount: 2,
      changedFilesOverflow: 1,
    });
  });

  it("routes pi-tui mirror session event catch-up through mirror runtime", async () => {
    const session = {
      id: "mirror-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      status: "busy",
      createdAt: 0,
      lastActivity: 1,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const mirrorCatchUp = {
      events: [{ type: "compaction_start", reason: "threshold", seq: 4 }],
      currentSeq: 4,
      session,
      catchUpComplete: true,
    };
    const managedGetCatchUp = vi.fn();
    const mirrorGetCatchUp = vi.fn(() => mirrorCatchUp);
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
      },
      sessions: {
        getCatchUp: managedGetCatchUp,
      },
      sessionRuntimes: {
        getCatchUp: mirrorGetCatchUp,
      },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/mirror-1/events",
      url: new URL("http://localhost/workspaces/ws-1/sessions/mirror-1/events?since=3"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(mirrorGetCatchUp).toHaveBeenCalledWith("mirror-1", 3);
    expect(managedGetCatchUp).not.toHaveBeenCalled();
    expect(JSON.parse(res.body)).toEqual(mirrorCatchUp);
  });

  it("validates since param on session events", async () => {
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
      },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/events",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/events?since=-5"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "since must be a non-negative integer" });
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createSessionRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/not/sessions",
      url: new URL("http://localhost/not/sessions"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});
