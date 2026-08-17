import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function makeGitWorkspace(root: string): Workspace {
  git(root, ["init", "--initial-branch=main"]);
  git(root, ["config", "user.email", "oppi-test@example.invalid"]);
  git(root, ["config", "user.name", "Oppi Test"]);
  writeFileSync(join(root, "README.md"), "main checkout\n");
  git(root, ["add", "README.md"]);
  git(root, ["commit", "-m", "initial"]);
  return {
    id: "ws-1",
    name: "Test",
    hostMount: root,
    systemPromptMode: "append",
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
}

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
  }, 30_000);

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

  it.each([
    {
      name: "non-object body",
      body: ["steer"],
      status: 400,
      response: { error: "Command body must be an object" },
    },
    {
      name: "missing type",
      body: { requestId: "req-type" },
      status: 400,
      response: { error: "Command type required" },
    },
    {
      name: "missing set_session_name.name",
      body: { type: "set_session_name", requestId: "req-name" },
      status: 400,
      response: { error: "Invalid payload: expected name" },
    },
    {
      name: "unknown type",
      body: { type: "future_command_v99", requestId: "req-unknown" },
      status: 200,
      response: {
        messages: [
          {
            type: "command_result",
            command: "future_command_v99",
            requestId: "req-unknown",
            success: false,
            error: "Unsupported command type: future_command_v99",
          },
        ],
      },
    },
  ])("preserves HTTP command ingress surfaces: $name", async ({ body, status, response }) => {
    const session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "ready",
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
      },
      sessionRuntimes: {},
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/sessions/s1/command",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/command"),
      req: makeRequest(body) as never,
      res: res as never,
    });

    expect(res.statusCode).toBe(status);
    expect(JSON.parse(res.body)).toEqual(response);
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

  it("creates sessions in data-dir managed worktrees", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-session-route-worktree-root-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-route-worktree-data-"));
    try {
      const workspace = makeGitWorkspace(root);
      const worktree = createWorkspaceWorktree(
        workspace,
        { branch: "feature/session-route-worktree" },
        { dataDir },
      );
      const session: Session = {
        id: "created-1",
        workspaceId: workspace.id,
        status: "ready",
        createdAt: 1,
        lastActivity: 1,
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          createSession: vi.fn(() => session),
          saveSession: vi.fn((updated: Session) => Object.assign(session, updated)),
          listSessions: vi.fn(() => []),
          findSessionByLaunchIdempotencyKey: vi.fn(() => undefined),
          claimSessionLaunchRecovery: vi.fn(() => undefined),
        },
        sessions: {
          startSession: vi.fn(async () => session),
          sendPrompt: vi.fn(async () => undefined),
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set()),
          getActiveSession: vi.fn(() => undefined),
          getPendingUIRequestMessages: vi.fn(() => []),
        },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/sessions",
        url: new URL("http://localhost/workspaces/ws-1/sessions"),
        req: makeRequest({ name: "Worktree session", worktreeId: worktree.id }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(201);
      expect(ctx.storage.createSession).toHaveBeenCalledOnce();
      expect(session.worktreeId).toBe(worktree.id);
      expect(JSON.parse(res.body).session.worktreeId).toBe(worktree.id);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("fails visibly without dispatching when an explicit session model is unavailable", async () => {
    const modelError = new Error(
      'Required model "openai-codex/gpt-5.6-sol" is not available; refusing model fallback',
    );
    const session: Session = {
      id: "created-1",
      status: "ready",
      createdAt: 1,
      lastActivity: 1,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const saveSession = vi.fn((updated: Session) => Object.assign(session, updated));
    const sendPrompt = vi.fn(async () => undefined);
    const emitSessionCreated = vi.fn();
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getDataDir: vi.fn(() => tmpdir()),
        createSession: vi.fn((name?: string, model?: string) => {
          session.name = name;
          session.model = model;
          return session;
        }),
        saveSession,
        listSessions: vi.fn(() => [session]),
        findSessionByLaunchIdempotencyKey: vi.fn(() => undefined),
        claimSessionLaunchRecovery: vi.fn(() => undefined),
      },
      sessions: {
        startSession: vi.fn(async () => {
          throw modelError;
        }),
        sendPrompt,
      },
      sessionRuntimes: {},
      ensureSessionContextWindow: vi.fn((value: Session) => value),
      appEvents: { emitSessionCreated, emitSessionSummary: vi.fn() },
    } as unknown as RouteContext;
    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/sessions",
      url: new URL("http://localhost/workspaces/ws-1/sessions"),
      req: makeRequest({
        model: "openai-codex/gpt-5.6-sol",
        prompt: "private implementation prompt",
      }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(409);
    expect(JSON.parse(res.body)).toEqual({
      error: modelError.message,
      sessionId: "created-1",
    });
    expect(sendPrompt).not.toHaveBeenCalled();
    expect(emitSessionCreated).toHaveBeenCalledWith(
      expect.objectContaining({
        id: "created-1",
        status: "error",
        launch: expect.objectContaining({ status: "failed", modelPolicy: "required" }),
      }),
    );
    expect(session).toMatchObject({
      model: "openai-codex/gpt-5.6-sol",
      status: "error",
      launch: {
        modelPolicy: "required",
        status: "failed",
        promptDispatch: "not_sent",
        promptError: modelError.message,
      },
    });
  });

  it("returns conflict instead of resuming removed-worktree sessions in main", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-session-route-removed-worktree-root-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-route-removed-worktree-data-"));
    try {
      const workspace = makeGitWorkspace(root);
      const session: Session = {
        id: "stopped-1",
        workspaceId: workspace.id,
        worktreeId: "wt_removed",
        status: "stopped",
        createdAt: 1,
        lastActivity: 1,
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
      };
      const startSession = vi.fn(async () => session);
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getSession: vi.fn(() => session),
          getDataDir: vi.fn(() => dataDir),
        },
        sessions: { startSession },
        sessionRuntimes: {
          isSessionConnected: vi.fn(() => false),
        },
        ensureSessionContextWindow: vi.fn((value: Session) => value),
      } as unknown as RouteContext;
      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/sessions/stopped-1/resume",
        url: new URL("http://localhost/workspaces/ws-1/sessions/stopped-1/resume"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(409);
      expect(JSON.parse(res.body)).toEqual({
        error: "Session worktree is no longer available",
      });
      expect(startSession).not.toHaveBeenCalled();
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
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

  it("handles session attachment routes without workspace scope", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-generic-session-attachment-"));
    try {
      const ctx = {
        storage: {
          getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
          getDataDir: vi.fn(() => dataDir),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const handled = await dispatch({
        method: "GET",
        path: "/sessions/s1/attachments/missing",
        url: new URL("http://localhost/sessions/s1/attachments/missing"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Attachment not found" });
      expect(ctx.storage.getSession).toHaveBeenCalledWith("s1");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
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

  it("lists sessions on the generic app-control route with workspace/worktree filters", async () => {
    const storedSession = {
      id: "s1",
      workspaceId: "ws-1",
      worktreeId: "main",
      status: "stopped",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const activeSession = {
      id: "s2",
      workspaceId: "ws-1",
      worktreeId: "main",
      status: "busy",
      createdAt: 0,
      lastActivity: 20,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        listSessions: vi.fn(() => [storedSession]),
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set(["s2"])),
        getActiveSession: vi.fn(() => activeSession),
      },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/sessions",
      url: new URL("http://localhost/sessions?workspaceId=ws-1&worktreeId=main&status=active"),
      req: { url: "/sessions?workspaceId=ws-1&worktreeId=main&status=active" } as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).sessions.map((session: { id: string }) => session.id)).toEqual([
      "s2",
    ]);
  });

  it("exposes generic session get/read/events/command/stop routes for CLI use", async () => {
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
    const stopSession = vi.fn(async () => ({ session, storedStopOnly: true }));
    const ctx = {
      storage: {
        getSession: vi.fn(() => session),
      },
      sessionRuntimes: {
        sendSteer,
        refreshSessionState: vi.fn(async () => undefined),
        getCatchUp: vi.fn(() => ({
          events: [{ seq: 1, type: "session_updated" }],
          currentSeq: 1,
          session,
          catchUpComplete: true,
        })),
        isSessionConnected: vi.fn(() => true),
        stopSession: vi.fn(async () => undefined),
      },
      sessions: {
        stopSession,
      },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
      appEvents: { emitStopConfirmed: vi.fn() },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());

    const getRes = makeResponse();
    expect(
      await dispatch({
        method: "GET",
        path: "/sessions/s1",
        url: new URL("http://localhost/sessions/s1"),
        req: {} as never,
        res: getRes as never,
      }),
    ).toBe(true);
    expect(JSON.parse(getRes.body)).toEqual({ session });

    const readRes = makeResponse();
    expect(
      await dispatch({
        method: "GET",
        path: "/sessions/s1/read",
        url: new URL("http://localhost/sessions/s1/read?tail=50"),
        req: {} as never,
        res: readRes as never,
      }),
    ).toBe(true);
    expect(JSON.parse(readRes.body)).toMatchObject({ session, trace: [] });

    const eventsRes = makeResponse();
    expect(
      await dispatch({
        method: "GET",
        path: "/sessions/s1/events",
        url: new URL("http://localhost/sessions/s1/events?since=1"),
        req: {} as never,
        res: eventsRes as never,
      }),
    ).toBe(true);
    expect(JSON.parse(eventsRes.body).currentSeq).toBe(1);

    const commandRes = makeResponse();
    expect(
      await dispatch({
        method: "POST",
        path: "/sessions/s1/command",
        url: new URL("http://localhost/sessions/s1/command"),
        req: makeRequest({ type: "steer", message: "hello" }) as never,
        res: commandRes as never,
      }),
    ).toBe(true);
    expect(sendSteer).toHaveBeenCalledWith("s1", "hello", {
      attachments: undefined,
      clientTurnId: undefined,
      requestId: undefined,
    });

    const stopRes = makeResponse();
    expect(
      await dispatch({
        method: "POST",
        path: "/sessions/s1/stop",
        url: new URL("http://localhost/sessions/s1/stop"),
        req: {} as never,
        res: stopRes as never,
      }),
    ).toBe(true);
    expect(JSON.parse(stopRes.body)).toMatchObject({ ok: true, session });
  });

  it("filters generic session trace entries by include parts", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-generic-trace-include-"));
    try {
      const tracePath = join(dataDir, "trace.jsonl");
      writeFileSync(
        tracePath,
        [
          JSON.stringify({ type: "session", id: "pi-1", cwd: dataDir }),
          JSON.stringify({
            type: "message",
            id: "u1",
            message: { role: "user", content: [{ type: "text", text: "hello" }] },
          }),
          JSON.stringify({
            type: "message",
            id: "a1",
            parentId: "u1",
            message: {
              role: "assistant",
              content: [
                { type: "text", text: "hi" },
                { type: "toolCall", id: "tc-1", name: "bash", arguments: { command: "pwd" } },
              ],
            },
          }),
          JSON.stringify({
            type: "message",
            id: "tr1",
            parentId: "a1",
            message: {
              role: "toolResult",
              toolCallId: "tc-1",
              toolName: "bash",
              content: [{ type: "text", text: dataDir }],
            },
          }),
        ].join("\n") + "\n",
        "utf8",
      );

      const session = {
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
          getSession: vi.fn(() => session),
          getDataDir: vi.fn(() => dataDir),
        },
        sessionRuntimes: {
          refreshSessionState: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: "/sessions/s1/trace",
          url: new URL("http://localhost/sessions/s1/trace?include=tools"),
          req: {} as never,
          res: res as never,
        }),
      ).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body).trace.map((event: { type: string }) => event.type)).toEqual([
        "toolCall",
        "toolResult",
      ]);

      const invalidRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: "/sessions/s1/trace",
          url: new URL("http://localhost/sessions/s1/trace?include=everything"),
          req: {} as never,
          res: invalidRes as never,
        }),
      ).toBe(true);
      expect(invalidRes.statusCode).toBe(400);
      expect(JSON.parse(invalidRes.body)).toEqual({
        error: "include must contain only all, messages, summary, system, thinking, or tools",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("lists pending user-reply dialogs on the generic session dialogs route", async () => {
    const ctx = {
      storage: {
        getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
      },
      sessionRuntimes: {
        getPendingUIRequestMessages: vi.fn(() => [
          {
            type: "extension_ui_notification",
            method: "setStatus",
            statusKey: "k",
            statusText: "live",
          },
          {
            type: "extension_ui_request",
            id: "ask-1",
            sessionId: "s1",
            method: "ask",
            questions: [{ id: "q", question: "Which?", options: [{ value: "a", label: "A" }] }],
            allowCustom: false,
            timeout: 1000,
          },
          {
            type: "extension_ui_request",
            id: "sel-1",
            sessionId: "s1",
            method: "select",
            title: "Pick",
            options: ["x", "y"],
          },
          // ask without questions is not a pending user-reply request
          { type: "extension_ui_request", id: "ask-empty", sessionId: "s1", method: "ask" },
        ]),
      },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "GET",
      path: "/sessions/s1/dialogs",
      url: new URL("http://localhost/sessions/s1/dialogs"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      dialogs: Array<Record<string, unknown>>;
    };
    expect(body.dialogs.map((dialog) => [dialog.id, dialog.method])).toEqual([
      ["ask-1", "ask"],
      ["sel-1", "select"],
    ]);
    expect(body.dialogs[0]).toMatchObject({ method: "ask", allowCustom: false, timeout: 1000 });
    expect(body.dialogs[1]).toMatchObject({ method: "select", title: "Pick", options: ["x", "y"] });
  });

  it("returns 404 for dialogs on a missing session", async () => {
    const ctx = {
      storage: { getSession: vi.fn(() => undefined) },
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    await dispatch({
      method: "GET",
      path: "/sessions/missing/dialogs",
      url: new URL("http://localhost/sessions/missing/dialogs"),
      req: {} as never,
      res: res as never,
    });

    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Session not found" });
  });

  it("maps follow_up and abort commands through the runtime transport", async () => {
    const session = { id: "s1", workspaceId: "ws-1", status: "busy" };
    const sendFollowUp = vi.fn(async () => undefined);
    const sendAbort = vi.fn(async () => undefined);
    const ctx = {
      storage: { getSession: vi.fn(() => session) },
      sessionRuntimes: { sendFollowUp, sendAbort },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());

    const followRes = makeResponse();
    await dispatch({
      method: "POST",
      path: "/sessions/s1/command",
      url: new URL("http://localhost/sessions/s1/command"),
      req: makeRequest({ type: "follow_up", message: "later" }) as never,
      res: followRes as never,
    });
    expect(sendFollowUp).toHaveBeenCalledWith("s1", "later", {
      attachments: undefined,
      clientTurnId: undefined,
      requestId: undefined,
    });

    const abortRes = makeResponse();
    await dispatch({
      method: "POST",
      path: "/sessions/s1/command",
      url: new URL("http://localhost/sessions/s1/command"),
      req: makeRequest({ type: "abort" }) as never,
      res: abortRes as never,
    });
    expect(sendAbort).toHaveBeenCalledWith("s1");
    expect(JSON.parse(abortRes.body)).toEqual({ messages: [] });
  });

  it("routes extension_ui_response through respondToUIRequest and reports not-found", async () => {
    const session = { id: "s1", workspaceId: "ws-1", status: "busy" };
    const respondToUIRequest = vi.fn(() => true);
    const ctx = {
      storage: { getSession: vi.fn(() => session) },
      sessionRuntimes: { respondToUIRequest },
      ensureSessionContextWindow: vi.fn((s: unknown) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());

    const okRes = makeResponse();
    await dispatch({
      method: "POST",
      path: "/sessions/s1/command",
      url: new URL("http://localhost/sessions/s1/command"),
      req: makeRequest({
        type: "extension_ui_response",
        id: "ask-1",
        value: JSON.stringify({ approach: "unit" }),
      }) as never,
      res: okRes as never,
    });
    expect(respondToUIRequest).toHaveBeenCalledWith("s1", {
      type: "extension_ui_response",
      id: "ask-1",
      value: JSON.stringify({ approach: "unit" }),
      confirmed: undefined,
      cancelled: undefined,
    });
    expect(JSON.parse(okRes.body)).toEqual({ messages: [] });

    respondToUIRequest.mockReturnValueOnce(false);
    const missRes = makeResponse();
    await dispatch({
      method: "POST",
      path: "/sessions/s1/command",
      url: new URL("http://localhost/sessions/s1/command"),
      req: makeRequest({ type: "extension_ui_response", id: "ghost" }) as never,
      res: missRes as never,
    });
    expect(JSON.parse(missRes.body)).toEqual({
      messages: [{ type: "error", error: "UI request not found: ghost" }],
    });
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
