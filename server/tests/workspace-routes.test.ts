import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { getPiSessionsRoot } from "../src/local-sessions.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import type {
  Session,
  Workspace,
  WorkspaceReviewDiffResponse,
  WorkspaceReviewFilesResponse,
} from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function makeRouteSession(id: string, overrides: Partial<Session> = {}): Session {
  return {
    id,
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 0,
    lastActivity: 0,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

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

  it("includes compact git summaries only when requested", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-workspace-catalog-git-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "initial\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);
      writeFileSync(join(root, "README.md"), "changed\n");

      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const ctx = {
        storage: {
          listWorkspaces: vi.fn(() => [workspace]),
          listWorkspaceSessionSummarySnapshots: vi.fn(() => []),
          getWorkspace: vi.fn(() => workspace),
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set<string>()),
          getActiveSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());

      const defaultRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces"),
        req: {} as never,
        res: defaultRes as never,
      });
      expect(JSON.parse(defaultRes.body).summaries[0].gitSummary).toBeUndefined();

      const gitRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces?includeGitSummary=true"),
        req: {} as never,
        res: gitRes as never,
      });
      expect(JSON.parse(gitRes.body).summaries[0].gitSummary).toEqual({
        isGitRepo: true,
        changedCount: 1,
        ahead: null,
        behind: null,
      });

      const compactRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/git/summary",
        url: new URL("http://localhost/workspaces/ws-1/git/summary"),
        req: {} as never,
        res: compactRes as never,
      });
      expect(JSON.parse(compactRes.body)).toEqual({
        isGitRepo: true,
        changedCount: 1,
        ahead: null,
        behind: null,
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
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

  it("includes session counts in GET /workspaces/:id/worktrees", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-counts-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);

      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const stored = makeRouteSession("stored-main");
      const activeDuplicate = makeRouteSession("stored-main");
      const activeOnly = makeRouteSession("active-main");
      const taskRecord = makeRouteSession("task-main", {
        runtime: "pi-tui",
        name: "Agent#12345678",
      });
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          listAllWorkspaceSessionSnapshots: vi.fn(() => [stored, taskRecord]),
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set(["stored-main", "active-main"])),
          getActiveSession: vi.fn((sessionId: string) => {
            if (sessionId === "stored-main") return activeDuplicate;
            if (sessionId === "active-main") return activeOnly;
            return undefined;
          }),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/worktrees",
        url: new URL("http://localhost/workspaces/ws-1/worktrees"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        worktrees: Array<{ id: string; sessionCount?: number }>;
      };
      expect(body.worktrees.find((worktree) => worktree.id === "main")?.sessionCount).toBe(2);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("creates data-dir worktrees through POST /workspaces/:id/worktrees", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-create-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-create-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);

      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          listAllWorkspaceSessionSnapshots: vi.fn(() => []),
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set<string>()),
          getActiveSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/worktrees",
        url: new URL("http://localhost/workspaces/ws-1/worktrees"),
        req: makeRequest({ branch: "feature/route-create" }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(201);
      const body = JSON.parse(res.body) as { worktree: { path: string; managedByOppi?: boolean } };
      expect(body.worktree.path.startsWith(realpathSync(join(dataDir, "worktrees", "ws-1")))).toBe(
        true,
      );
      expect(body.worktree.managedByOppi).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("keeps workspace deletion available while durable usage purge retry is pending", async () => {
    const deleteWorkspace = vi.fn(() => true);
    const deleteUsage = vi.fn(async () => ({ status: "pending" }));
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => undefined),
        deleteWorkspace,
      },
      resourceUsage: { deleteWorkspace: deleteUsage },
    } as unknown as RouteContext;
    const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "DELETE",
      path: "/workspaces/ws-1",
      url: new URL("http://localhost/workspaces/ws-1"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(deleteUsage).toHaveBeenCalledWith("ws-1");
    expect(deleteWorkspace).toHaveBeenCalledWith("ws-1");
  });

  it("blocks workspace deletion while Oppi-managed worktrees exist", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-workspace-delete-worktree-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-workspace-delete-worktree-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const worktree = createWorkspaceWorktree(
        workspace,
        { branch: "feature/delete-block" },
        { dataDir },
      );
      const deleteWorkspace = vi.fn();
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          deleteWorkspace,
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "DELETE",
        path: "/workspaces/ws-1",
        url: new URL("http://localhost/workspaces/ws-1"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(409);
      expect(JSON.parse(res.body)).toEqual({
        error: "Workspace has Oppi-managed worktrees; remove them before deleting the workspace",
      });
      expect(deleteWorkspace).not.toHaveBeenCalled();
      expect(existsSync(worktree.path)).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("blocks workspace deletion when a managed worktree directory is stale or undiscoverable", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-workspace-delete-stale-worktree-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-workspace-delete-stale-worktree-data-"));
    try {
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      mkdirSync(join(dataDir, "worktrees", "ws-1", "wt_stale"), { recursive: true });
      const deleteWorkspace = vi.fn();
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          deleteWorkspace,
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "DELETE",
        path: "/workspaces/ws-1",
        url: new URL("http://localhost/workspaces/ws-1"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(409);
      expect(JSON.parse(res.body)).toEqual({
        error: "Workspace has Oppi-managed worktrees; remove them before deleting the workspace",
      });
      expect(deleteWorkspace).not.toHaveBeenCalled();
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("returns 404 for unknown worktree-scoped git status", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-bad-status-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-bad-status-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/git/status",
        url: new URL("http://localhost/workspaces/ws-1/git/status?worktreeId=missing"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Worktree not found" });
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("routes review changes and diffs through the selected session worktree", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-review-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-review-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "review.swift"), "let value = original\n", "utf8");
      git(root, ["add", "review.swift"]);
      git(root, ["commit", "-m", "initial"]);
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const worktree = createWorkspaceWorktree(
        workspace,
        { branch: "feature/review" },
        { dataDir },
      );
      writeFileSync(join(root, "review.swift"), "let value = main\n", "utf8");
      writeFileSync(join(worktree.path, "review.swift"), "let value = worktree\n", "utf8");
      const selectedSession = makeRouteSession("session-worktree", {
        worktreeId: worktree.id,
        changeStats: {
          mutatingToolCalls: 1,
          filesChanged: 1,
          changedFiles: ["review.swift"],
          addedLines: 1,
          removedLines: 1,
        },
      });
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          getSession: vi.fn((sessionId: string) =>
            sessionId === selectedSession.id ? selectedSession : undefined,
          ),
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const changesRes = makeResponse();

      await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/git/changes",
        url: new URL(
          "http://localhost/workspaces/ws-1/git/changes?selectedSessionId=session-worktree",
        ),
        req: {} as never,
        res: changesRes as never,
      });

      expect(changesRes.statusCode).toBe(200);
      const changes = JSON.parse(changesRes.body) as WorkspaceReviewFilesResponse;
      expect(changes.branch).toBe("feature/review");
      expect(changes.selectedSessionId).toBe("session-worktree");
      expect(changes.files).toEqual([
        expect.objectContaining({ path: "review.swift", selectedSessionTouched: true }),
      ]);

      const diffRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/git/diff",
        url: new URL(
          "http://localhost/workspaces/ws-1/git/diff?selectedSessionId=session-worktree&path=review.swift",
        ),
        req: {} as never,
        res: diffRes as never,
      });

      expect(diffRes.statusCode).toBe(200);
      const diff = JSON.parse(diffRes.body) as WorkspaceReviewDiffResponse;
      expect(diff.currentText).toBe("let value = worktree\n");
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("removes clean worktrees without deleting stopped session history", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-stopped-history-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-stopped-history-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const worktree = createWorkspaceWorktree(
        workspace,
        { branch: "feature/stopped-history" },
        { dataDir },
      );
      const stoppedSession = makeRouteSession("stopped-worktree", {
        status: "stopped",
        worktreeId: worktree.id,
      });
      const listSnapshots = vi.fn(() => [stoppedSession]);
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          listAllWorkspaceSessionSnapshots: listSnapshots,
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set<string>()),
          getActiveSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "DELETE",
        path: `/workspaces/ws-1/worktrees/${worktree.id}`,
        url: new URL(`http://localhost/workspaces/ws-1/worktrees/${worktree.id}`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body)).toMatchObject({ ok: true, workspaceId: "ws-1" });
      expect(existsSync(worktree.path)).toBe(false);
      expect(listSnapshots()).toEqual([stoppedSession]);

      const recreateRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/worktrees",
        url: new URL("http://localhost/workspaces/ws-1/worktrees"),
        req: makeRequest({ branch: "feature/stopped-history" }) as never,
        res: recreateRes as never,
      });
      expect(recreateRes.statusCode).toBe(409);
      expect(JSON.parse(recreateRes.body)).toEqual({
        error: "Worktree id is still referenced by session history",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("uses persisted nonterminal sessions and canonical ids for remove guards", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-remove-guard-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-remove-guard-data-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const worktree = createWorkspaceWorktree(
        workspace,
        { branch: "feature/remove-guard" },
        { dataDir },
      );
      const startingSession = makeRouteSession("starting-worktree", {
        status: "starting",
        worktreeId: worktree.id,
      });
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
          listAllWorkspaceSessionSnapshots: vi.fn(() => [startingSession]),
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set<string>()),
          getActiveSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;
      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const encodedId = encodeURIComponent(` ${worktree.id} `);

      const handled = await dispatch({
        method: "DELETE",
        path: `/workspaces/ws-1/worktrees/${encodedId}`,
        url: new URL(`http://localhost/workspaces/ws-1/worktrees/${encodedId}?force=true`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(409);
      expect(JSON.parse(res.body)).toEqual({
        error: "Cannot remove a worktree with active sessions",
      });
      expect(existsSync(worktree.path)).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects malformed worktree lifecycle bodies with 400", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-worktree-route-bad-body-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktree-route-bad-body-data-"));
    try {
      const workspace: Workspace = {
        id: "ws-1",
        name: "Default",
        hostMount: root,
        systemPromptMode: "append",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => workspace),
          getDataDir: vi.fn(() => dataDir),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/worktrees",
        url: new URL("http://localhost/workspaces/ws-1/worktrees"),
        req: makeRequest(null) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "Request body must be an object" });
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
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
