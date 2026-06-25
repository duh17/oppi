import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

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
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
        getActiveSession: vi.fn(() => undefined),
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

  it("dispatches generic session commands through the runtime command transport", async () => {
    const session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "busy",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const sendSteer = vi.fn(async () => undefined);
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
      },
      sessionRuntimes: {
        sendSteer,
      },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/sessions/s1/command",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/command"),
      req: makeRequest({ type: "steer", message: "hello", requestId: "req-1" }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(sendSteer).toHaveBeenCalledWith("s1", "hello", {
      attachments: undefined,
      clientTurnId: undefined,
      requestId: "req-1",
    });
    expect(JSON.parse(res.body)).toEqual({
      messages: [
        {
          type: "command_result",
          command: "steer",
          requestId: "req-1",
          success: true,
        },
      ],
    });
  });

  it("marks disconnected pi-tui mirror sessions stopped through the stop route", async () => {
    const session: Session = {
      id: "mirror-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      status: "ready",
      createdAt: 0,
      lastActivity: 10,
      currentTurnStartedAt: 5,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      mirror: {
        status: "disconnected",
        terminal: { lastSeenAt: 9 },
      },
    };
    const stopSession = vi.fn(async () => undefined);
    const saveSession = vi.fn((updated: Session) => {
      Object.assign(session, structuredClone(updated));
    });
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        saveSession,
      },
      sessionRuntimes: {
        isSessionConnected: vi.fn(() => false),
        isSessionLive: vi.fn(() => false),
        stopSession,
      },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/sessions/mirror-1/stop",
      url: new URL("http://localhost/workspaces/ws-1/sessions/mirror-1/stop"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(stopSession).not.toHaveBeenCalled();
    expect(saveSession).toHaveBeenCalledOnce();
    expect(session.status).toBe("stopped");
    expect(session.currentTurnStartedAt).toBeUndefined();
    expect(session.mirror?.status).toBe("disconnected");
    expect(session.mirror?.terminal?.disconnectReason).toBe("oppi_stop_disconnected_terminal");
    expect(JSON.parse(res.body).session.status).toBe("stopped");
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
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set(["active-1"])),
        getActiveSession: vi.fn(() => activeSession),
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

  it("maps overall diff current-file policy misses to HTTP errors", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-route-diff-"));
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-test-route-diff-workspace-"));
    const outsideRoot = mkdtempSync(join(tmpdir(), "oppi-test-route-diff-outside-"));
    try {
      const outsidePath = join(outsideRoot, "outside.txt");
      const tracePath = join(dataDir, "trace.jsonl");
      writeFileSync(outsidePath, "new", "utf8");
      writeFileSync(
        tracePath,
        [
          JSON.stringify({ type: "session", id: "pi-1", cwd: workspaceRoot }),
          JSON.stringify({
            type: "message",
            id: "assistant-1",
            message: {
              role: "assistant",
              content: [
                {
                  type: "toolCall",
                  id: "tc-edit",
                  name: "edit",
                  arguments: { path: outsidePath, oldText: "old", newText: "new" },
                },
              ],
            },
          }),
        ].join("\n") + "\n",
        "utf8",
      );

      const session = {
        id: "s1",
        workspaceId: "ws-1",
        piSessionFile: tracePath,
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test", hostMount: workspaceRoot })),
          getSession: vi.fn(() => session),
          getDataDir: vi.fn(() => dataDir),
        },
        sessionRuntimes: {},
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const url = new URL(
        `http://localhost/workspaces/ws-1/sessions/s1/diff?path=${encodeURIComponent(outsidePath)}`,
      );

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/s1/diff",
        url,
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(403);
      expect(JSON.parse(res.body)).toEqual({ error: "Current file path outside workspace" });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  });

  it("replays a pi-tui mirror JSONL trace without a live leaf id", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-mirror-trace-"));
    try {
      const tracePath = join(dataDir, "mirror.jsonl");
      writeFileSync(
        tracePath,
        [
          JSON.stringify({ type: "session", id: "pi-1", cwd: dataDir }),
          JSON.stringify({
            type: "message",
            id: "u1",
            message: { role: "user", content: [{ type: "text", text: "hello from tui" }] },
          }),
          JSON.stringify({
            type: "message",
            id: "a1",
            parentId: "u1",
            message: { role: "assistant", content: [{ type: "text", text: "hello from oppi" }] },
          }),
        ].join("\n"),
        "utf8",
      );

      const session = {
        id: "mirror-1",
        workspaceId: "ws-1",
        runtime: "pi-tui",
        status: "ready",
        createdAt: 0,
        lastActivity: 1,
        messageCount: 2,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        piSessionFile: tracePath,
        piSessionFiles: [tracePath],
        piSessionId: "pi-1",
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          getSession: vi.fn(() => session),
          getDataDir: vi.fn(() => dataDir),
        },
        sessionRuntimes: {
          refreshSessionState: vi.fn(async () => ({
            sessionFile: tracePath,
            sessionId: "pi-1",
            leafId: null,
          })),
        },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/mirror-1",
        url: new URL("http://localhost/workspaces/ws-1/sessions/mirror-1"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { trace: Array<{ type: string; text?: string }> };
      expect(body.trace.map((event) => [event.type, event.text])).toEqual([
        ["user", "hello from tui"],
        ["assistant", "hello from oppi"],
      ]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
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
