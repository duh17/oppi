import { describe, expect, it, vi } from "vitest";
import { execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Readable } from "node:stream";

import { RouteHandler, type RouteContext } from "../src/routes/index.js";
import type {
  Session,
  Workspace,
  WorkspaceQuickActionsResponse,
  WorkspaceQuickActionSelectionResponse,
  WorkspaceQuickActionSessionResponse,
  WorkspaceReviewDiffResponse,
} from "../src/types.js";

interface MockResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status: number, headers: Record<string, string>): MockResponse {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeRequest(body?: unknown): Readable {
  const text = body === undefined ? "" : JSON.stringify(body);
  return Readable.from(text ? [text] : []);
}

function gitIn(dir: string, cmd: string): string {
  return execSync(`git ${cmd}`, { cwd: dir, encoding: "utf-8" }).trim();
}

function makeWorkspace(repoDir: string): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "workspace",
    hostMount: repoDir,
    createdAt: now,
    updatedAt: now,
  };
}

function makeSession(id: string, workspaceId = "w1", changedFiles: string[] = []): Session {
  const now = Date.now();
  return {
    id,
    workspaceId,
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    changeStats: {
      mutatingToolCalls: changedFiles.length,
      filesChanged: changedFiles.length,
      changedFiles,
      addedLines: 0,
      removedLines: 0,
    },
  };
}

function initRepo(repoDir: string): void {
  gitIn(repoDir, "init -b main");
  gitIn(repoDir, 'config user.email "test@test.com"');
  gitIn(repoDir, 'config user.name "Test"');
}

function makeQuickActionContext(
  repoDir: string,
  overrides: Partial<RouteContext> = {},
): RouteContext {
  return {
    storage: {
      getWorkspace: (workspaceId: string) =>
        workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
      getSession: () => undefined,
      createSession: vi.fn(),
    },
    sessions: { startSession: vi.fn() },
    sessionRuntimes: {
      getActiveSessionIds: () => new Set<string>(),
      getActiveSession: () => undefined,
      getPendingUIRequestMessages: () => [],
      getSessionSnapshot: (sessionId: string) =>
        (
          overrides.sessions as
            | { getActiveSession?: (id: string) => Session | undefined }
            | undefined
        )?.getActiveSession?.(sessionId) ??
        (
          overrides.storage as { getSession?: (id: string) => Session | undefined } | undefined
        )?.getSession?.(sessionId),
    },
    ensureSessionContextWindow: (session: Session) => session,
    ...overrides,
  } as unknown as RouteContext;
}

describe("GET /workspaces/:wid/git/diff", () => {
  it("returns baseline/current text and word-level spans", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-diff-"));

    try {
      initRepo(repoDir);

      writeFileSync(
        join(repoDir, "review.swift"),
        "let value = oldName\nlet keep = true\n",
        "utf8",
      );
      gitIn(repoDir, "add review.swift");
      gitIn(repoDir, 'commit -m "initial commit"');

      writeFileSync(
        join(repoDir, "review.swift"),
        "let value = newName\nlet keep = true\n",
        "utf8",
      );

      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/git/diff",
        new URL("http://localhost/workspaces/w1/git/diff?path=review.swift"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as WorkspaceReviewDiffResponse;

      expect(body.workspaceId).toBe("w1");
      expect(body.path).toBe("review.swift");
      expect(body.baselineText).toContain("oldName");
      expect(body.currentText).toContain("newName");
      expect(body.addedLines).toBe(1);
      expect(body.removedLines).toBe(1);
      expect(body.hunks).toHaveLength(1);

      const hunk = body.hunks[0]!;
      expect(hunk.lines).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "removed", text: "let value = oldName" }),
          expect.objectContaining({ kind: "added", text: "let value = newName" }),
          expect.objectContaining({ kind: "context", text: "let keep = true" }),
        ]),
      );

      const removed = hunk.lines.find((line) => line.kind === "removed");
      const added = hunk.lines.find((line) => line.kind === "added");
      expect(removed?.spans?.length).toBeGreaterThan(0);
      expect(added?.spans?.length).toBeGreaterThan(0);
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("returns 404 when the file is absent from HEAD and working tree", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-diff-"));

    try {
      initRepo(repoDir);

      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/git/diff",
        new URL("http://localhost/workspaces/w1/git/diff?path=missing.swift"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "File not found for review" });
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });
});

describe("GET /workspaces/:wid/quick-actions", () => {
  it("returns prompt templates as the selected-file quick-action options", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-quick-actions-"));

    try {
      mkdirSync(join(repoDir, ".pi", "prompts"), { recursive: true });
      writeFileSync(
        join(repoDir, ".pi", "prompts", "grill-me.md"),
        [
          "---",
          "description: Stress-test the selected files",
          "argument-hint: FILES",
          "---",
          "Review these files: $ARGUMENTS",
        ].join("\n"),
        "utf8",
      );
      writeFileSync(
        join(repoDir, ".pi", "prompts", "prepare-commit.md"),
        "Prepare a commit for: $ARGUMENTS\n",
        "utf8",
      );

      const routes = new RouteHandler(makeQuickActionContext(repoDir));
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/quick-actions",
        new URL("http://localhost/workspaces/w1/quick-actions"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as WorkspaceQuickActionsResponse;

      expect(body.actions).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: "prompt:grill-me",
            title: "Grill Me",
            commandName: "grill-me",
            description: "Stress-test the selected files",
            argumentHint: "FILES",
            source: "prompt",
            sourceScope: "project",
            promptTemplateName: "grill-me",
          }),
          expect.objectContaining({
            id: "prompt:prepare-commit",
            title: "Prepare Commit",
            commandName: "prepare-commit",
            source: "prompt",
            sourceScope: "project",
            promptTemplateName: "prepare-commit",
          }),
        ]),
      );
      expect(
        body.actions.map((action) => action.source).every((source) => source === "prompt"),
      ).toBe(true);
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("does not expose the legacy prompt-templates endpoint", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-quick-actions-legacy-"));

    try {
      const routes = new RouteHandler(makeQuickActionContext(repoDir));
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/prompt-templates",
        new URL("http://localhost/workspaces/w1/prompt-templates"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Not found" });
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });
});

describe("workspace prompt-template quick actions", () => {
  it("substitutes selected paths into prompt-template arguments", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-template-"));

    try {
      initRepo(repoDir);

      mkdirSync(join(repoDir, ".pi", "prompts"), { recursive: true });
      writeFileSync(
        join(repoDir, ".pi", "prompts", "grill-me.md"),
        "Start an interactive grilling session for this topic:\n\n$ARGUMENTS\n",
        "utf8",
      );
      writeFileSync(join(repoDir, "first.swift"), "let value = oldName\n", "utf8");
      writeFileSync(join(repoDir, "second.swift"), "let other = oldName\n", "utf8");
      gitIn(repoDir, "add first.swift second.swift .pi/prompts/grill-me.md");
      gitIn(repoDir, 'commit -m "initial commit"');

      writeFileSync(join(repoDir, "first.swift"), "let value = newName\n", "utf8");
      writeFileSync(join(repoDir, "second.swift"), "let other = newName\n", "utf8");

      const routes = new RouteHandler(makeQuickActionContext(repoDir));
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/quick-actions/selection",
        new URL("http://localhost/workspaces/w1/quick-actions/selection"),
        makeRequest({
          paths: ["first.swift", "second.swift"],
          promptTemplateName: "grill-me",
        }) as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as WorkspaceQuickActionSelectionResponse;

      expect(body.promptTemplateName).toBe("grill-me");
      expect(body.visiblePrompt).toBe(
        "Start an interactive grilling session for this topic:\n\nfirst.swift second.swift",
      );
      expect(body.filePaths).toEqual(["first.swift", "second.swift"]);

      writeFileSync(
        join(repoDir, ".pi", "prompts", "grill-me.md"),
        "Reloaded prompt for:\n\n$ARGUMENTS\n",
        "utf8",
      );

      const reloadedRes = makeResponse();
      await routes.dispatch(
        "POST",
        "/workspaces/w1/quick-actions/selection",
        new URL("http://localhost/workspaces/w1/quick-actions/selection"),
        makeRequest({
          paths: ["second.swift"],
          promptTemplateName: "grill-me",
        }) as never,
        reloadedRes as never,
      );

      expect(reloadedRes.statusCode).toBe(200);
      const reloadedBody = JSON.parse(reloadedRes.body) as WorkspaceQuickActionSelectionResponse;
      expect(reloadedBody.promptTemplateName).toBe("grill-me");
      expect(reloadedBody.visiblePrompt).toBe("Reloaded prompt for:\n\nsecond.swift");
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("creates a seeded quick-action session from a prompt template and selected files", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-quick-action-session-"));

    try {
      initRepo(repoDir);

      mkdirSync(join(repoDir, ".pi", "prompts"), { recursive: true });
      writeFileSync(
        join(repoDir, ".pi", "prompts", "grill-me.md"),
        "Inspect the selected files:\n\n$ARGUMENTS\n",
        "utf8",
      );
      writeFileSync(join(repoDir, "review.swift"), "let value = oldName\n", "utf8");
      gitIn(repoDir, "add review.swift .pi/prompts/grill-me.md");
      gitIn(repoDir, 'commit -m "initial commit"');

      writeFileSync(join(repoDir, "review.swift"), "let value = newName\n", "utf8");

      const createdSession = makeSession("new-session", "w1");
      let savedSession: Session | undefined;
      const startSession = vi.fn(async () => createdSession);
      const getActiveSession = vi.fn(() => createdSession);
      const createSession = vi.fn(() => createdSession);
      const workspace = { ...makeWorkspace(repoDir), defaultModel: "ds4/deepseek-v4-flash" };

      const ctx = makeQuickActionContext(repoDir, {
        storage: {
          getWorkspace: (workspaceId: string) => (workspaceId === "w1" ? workspace : undefined),
          getSession: () => undefined,
          createSession,
          saveSession: (session: Session) => {
            savedSession = session;
          },
          deleteSession: vi.fn(),
        },
        sessions: {
          setPendingExtensionFactories: vi.fn(),
          startSession,
          getActiveSession,
          stopSession: vi.fn(async () => undefined),
        },
      });

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/quick-actions/session",
        new URL("http://localhost/workspaces/w1/quick-actions/session"),
        makeRequest({ paths: ["review.swift"], promptTemplateName: "grill-me" }) as never,
        res as never,
      );

      expect(res.statusCode).toBe(201);
      const body = JSON.parse(res.body) as WorkspaceQuickActionSessionResponse;

      expect(body.promptTemplateName).toBe("grill-me");
      expect(body.selectedPathCount).toBe(1);
      expect(body.session.id).toBe("new-session");
      expect(createSession).toHaveBeenCalledWith(expect.any(String), "ds4/deepseek-v4-flash");
      expect(savedSession?.workspaceId).toBe("w1");
      expect(savedSession?.workspaceName).toBe("workspace");
      expect(startSession).toHaveBeenCalledWith(
        "new-session",
        expect.objectContaining({ id: "w1" }),
      );
      expect(body.visiblePrompt).toBe("Inspect the selected files:\n\nreview.swift");
      expect(body.filePaths).toEqual(["review.swift"]);
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("returns 400 when promptTemplateName is missing", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-quick-action-session-"));

    try {
      initRepo(repoDir);
      const routes = new RouteHandler(makeQuickActionContext(repoDir));
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/quick-actions/session",
        new URL("http://localhost/workspaces/w1/quick-actions/session"),
        makeRequest({ paths: ["review.swift"] }) as never,
        res as never,
      );

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "promptTemplateName required" });
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("returns 400 when selected paths are no longer in the current review", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-quick-action-session-"));

    try {
      initRepo(repoDir);

      mkdirSync(join(repoDir, ".pi", "prompts"), { recursive: true });
      writeFileSync(
        join(repoDir, ".pi", "prompts", "grill-me.md"),
        "Inspect: $ARGUMENTS\n",
        "utf8",
      );
      writeFileSync(join(repoDir, "tracked.swift"), "let value = 1\n", "utf8");
      gitIn(repoDir, "add tracked.swift .pi/prompts/grill-me.md");
      gitIn(repoDir, 'commit -m "initial commit"');

      const routes = new RouteHandler(makeQuickActionContext(repoDir));
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/quick-actions/session",
        new URL("http://localhost/workspaces/w1/quick-actions/session"),
        makeRequest({ paths: ["missing.swift"], promptTemplateName: "grill-me" }) as never,
        res as never,
      );

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({
        error: "Selected files are no longer available in the current review: missing.swift",
      });
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });
});
