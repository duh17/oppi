import { describe, expect, it, vi } from "vitest";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Readable } from "node:stream";

import { RouteHandler, type RouteContext } from "../src/routes/index.js";
import type {
  Session,
  Workspace,
  WorkspaceReviewDiffResponse,
  WorkspaceReviewFilesResponse,
  WorkspaceReviewSessionResponse,
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
    skills: [],
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

describe("GET /workspaces/:wid/review/files", () => {
  it("returns git-backed review files with selected session annotations", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-"));

    try {
      gitIn(repoDir, "init -b main");
      gitIn(repoDir, 'config user.email "test@test.com"');
      gitIn(repoDir, 'config user.name "Test"');

      writeFileSync(join(repoDir, "tracked.txt"), "hello\n", "utf8");
      gitIn(repoDir, "add tracked.txt");
      gitIn(repoDir, 'commit -m "initial commit"');

      writeFileSync(join(repoDir, "tracked.txt"), "hello\nworld\n", "utf8");
      writeFileSync(join(repoDir, "staged.txt"), "staged\n", "utf8");
      gitIn(repoDir, "add staged.txt");
      writeFileSync(join(repoDir, "untracked.txt"), "new\n", "utf8");

      const session = makeSession("s1", "w1", [
        "tracked.txt",
        "./untracked.txt",
        join(repoDir, "staged.txt"),
      ]);

      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
          getSession: (sessionId: string) => (sessionId === "s1" ? session : undefined),
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/review/files",
        new URL("http://localhost/workspaces/w1/review/files?sessionId=s1"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as WorkspaceReviewFilesResponse;

      expect(body.workspaceId).toBe("w1");
      expect(body.isGitRepo).toBe(true);
      expect(body.branch).toBe("main");
      expect(body.changedFileCount).toBe(3);
      expect(body.stagedFileCount).toBe(1);
      expect(body.unstagedFileCount).toBe(1);
      expect(body.untrackedFileCount).toBe(1);
      expect(body.selectedSessionId).toBe("s1");
      expect(body.selectedSessionTouchedCount).toBe(3);

      expect(body.files).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            path: "tracked.txt",
            isStaged: false,
            isUnstaged: true,
            isUntracked: false,
            selectedSessionTouched: true,
          }),
          expect.objectContaining({
            path: "staged.txt",
            isStaged: true,
            isUnstaged: false,
            isUntracked: false,
            selectedSessionTouched: true,
          }),
          expect.objectContaining({
            path: "untracked.txt",
            isStaged: false,
            isUnstaged: false,
            isUntracked: true,
            selectedSessionTouched: true,
          }),
        ]),
      );
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("returns 404 when the selected session is not in the workspace", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-"));

    try {
      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
          getSession: (sessionId: string) =>
            sessionId === "s1" ? makeSession("s1", "other-workspace", ["file.txt"]) : undefined,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/review/files",
        new URL("http://localhost/workspaces/w1/review/files?sessionId=s1"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Session not found" });
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });
});

describe("GET /workspaces/:wid/review/diff", () => {
  it("returns baseline/current text and word-level spans", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-diff-"));

    try {
      gitIn(repoDir, "init -b main");
      gitIn(repoDir, 'config user.email "test@test.com"');
      gitIn(repoDir, 'config user.name "Test"');

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
        "/workspaces/w1/review/diff",
        new URL("http://localhost/workspaces/w1/review/diff?path=review.swift"),
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
      gitIn(repoDir, "init -b main");
      gitIn(repoDir, 'config user.email "test@test.com"');
      gitIn(repoDir, 'config user.name "Test"');

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
        "/workspaces/w1/review/diff",
        new URL("http://localhost/workspaces/w1/review/diff?path=missing.swift"),
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

describe("POST /workspaces/:wid/review/session", () => {
  it("creates a seeded review session from selected files", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-session-"));

    try {
      gitIn(repoDir, "init -b main");
      gitIn(repoDir, 'config user.email "test@test.com"');
      gitIn(repoDir, 'config user.name "Test"');

      writeFileSync(join(repoDir, "review.swift"), "let value = oldName\n", "utf8");
      gitIn(repoDir, "add review.swift");
      gitIn(repoDir, 'commit -m "initial commit"');

      writeFileSync(join(repoDir, "review.swift"), "let value = newName\n", "utf8");

      const createdSession = makeSession("new-session", "w1");
      let savedSession: Session | undefined;
      const setPendingPromptPreamble = vi.fn();
      const startSession = vi.fn(async () => createdSession);
      const sendPrompt = vi.fn(async () => undefined);
      const getActiveSession = vi.fn(() => createdSession);

      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
          getSession: () => undefined,
          createSession: () => createdSession,
          saveSession: (session: Session) => {
            savedSession = session;
          },
          deleteSession: vi.fn(),
        },
        sessions: {
          setPendingPromptPreamble,
          startSession,
          sendPrompt,
          getActiveSession,
          stopSession: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: (session: Session) => session,
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/review/session",
        new URL("http://localhost/workspaces/w1/review/session"),
        makeRequest({ action: "review", paths: ["review.swift"] }) as never,
        res as never,
      );

      expect(res.statusCode).toBe(201);
      const body = JSON.parse(res.body) as WorkspaceReviewSessionResponse;

      expect(body.action).toBe("review");
      expect(body.selectedPathCount).toBe(1);
      expect(body.session.id).toBe("new-session");
      expect(savedSession?.workspaceId).toBe("w1");
      expect(savedSession?.workspaceName).toBe("workspace");
      expect(startSession).toHaveBeenCalledWith("new-session", expect.objectContaining({ id: "w1" }));
      expect(sendPrompt).toHaveBeenCalledWith("new-session", "Review these selected changes.");
      expect(setPendingPromptPreamble).toHaveBeenCalledTimes(1);
      expect(setPendingPromptPreamble.mock.calls[0]?.[1]).toContain("Continue from Oppi Workspace Review.");
      expect(setPendingPromptPreamble.mock.calls[0]?.[1]).toContain("review.swift");
      expect(setPendingPromptPreamble.mock.calls[0]?.[1]).toContain("+let value = newName");
    } finally {
      rmSync(repoDir, { recursive: true, force: true });
    }
  });

  it("returns 400 when selected paths are no longer in the current review", async () => {
    const repoDir = mkdtempSync(join(tmpdir(), "oppi-workspace-review-session-"));

    try {
      gitIn(repoDir, "init -b main");
      gitIn(repoDir, 'config user.email "test@test.com"');
      gitIn(repoDir, 'config user.name "Test"');

      writeFileSync(join(repoDir, "tracked.swift"), "let value = 1\n", "utf8");
      gitIn(repoDir, "add tracked.swift");
      gitIn(repoDir, 'commit -m "initial commit"');

      const ctx = {
        storage: {
          getWorkspace: (workspaceId: string) =>
            workspaceId === "w1" ? makeWorkspace(repoDir) : undefined,
          getSession: () => undefined,
        },
        sessions: {},
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "POST",
        "/workspaces/w1/review/session",
        new URL("http://localhost/workspaces/w1/review/session"),
        makeRequest({ action: "review", paths: ["missing.swift"] }) as never,
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
