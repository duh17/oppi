import { describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RouteHandler, type RouteContext } from "../src/routes/index.js";
import type { Session, Workspace } from "../src/types.js";

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

function makeUser(): User {
  return {
    id: "u1",
    name: "Bob",
    token: "tok",
    createdAt: Date.now(),
  };
}

function makeSession(id: string): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeWorkspace(baseDir: string, session: Session): Workspace {
  const now = Date.now();
  return {
    id: session.workspaceId ?? "w1",
    name: "workspace",
    skills: [],
    hostMount: workspaceRootDir(baseDir, session),
    createdAt: now,
    updatedAt: now,
  };
}

function workspaceTraceDir(baseDir: string, session: Session): string {
  return join(
    baseDir,
    session.workspaceId!,
    "sessions",
    session.id,
    "agent",
    "sessions",
    "--work--",
  );
}

function workspaceRootDir(baseDir: string, session: Session): string {
  return join(baseDir, session.workspaceId!, "workspace");
}

describe("GET /workspaces/:wid/sessions/:id/overall-diff", () => {
  it("returns baseline/current text and net stats for edit revisions", async () => {
    const baseDir = mkdtempSync(join(tmpdir(), "oppi-server-overall-diff-"));
    const session = makeSession("s1");

    try {
      const traceDir = workspaceTraceDir(baseDir, session);
      mkdirSync(traceDir, { recursive: true });

      const workspaceDir = workspaceRootDir(baseDir, session);
      mkdirSync(workspaceDir, { recursive: true });
      writeFileSync(join(workspaceDir, "file.txt"), "B", "utf8");

      const jsonl = [
        JSON.stringify({ type: "session", id: "root", timestamp: "2026-02-11T02:00:00.000Z" }),
        JSON.stringify({
          type: "message",
          id: "u-msg",
          parentId: "root",
          timestamp: "2026-02-11T02:00:01.000Z",
          message: { role: "user", content: "edit file" },
        }),
        JSON.stringify({
          type: "message",
          id: "a-msg",
          parentId: "u-msg",
          timestamp: "2026-02-11T02:00:02.000Z",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "tc-edit-1",
                name: "edit",
                arguments: {
                  path: "file.txt",
                  oldText: "A",
                  newText: "B",
                },
              },
            ],
          },
        }),
      ].join("\n");

      writeFileSync(join(traceDir, "20260211_uuid.jsonl"), `${jsonl}\n`, "utf8");

      const ctx = {
        storage: {
          getSession: (sessionId: string) =>
            sessionId === session.id ? session : undefined,
          getWorkspace: () => makeWorkspace(baseDir, session),
          getDataDir: () => baseDir,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/sessions/s1/overall-diff",
        new URL("http://localhost/workspaces/w1/sessions/s1/overall-diff?path=file.txt"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        path: string;
        revisionCount: number;
        baselineText: string;
        currentText: string;
        addedLines: number;
        removedLines: number;
        diffLines: Array<{ kind: string; text: string }>;
      };

      expect(body.path).toBe("file.txt");
      expect(body.revisionCount).toBe(1);
      expect(body.baselineText).toBe("A");
      expect(body.currentText).toBe("B");
      expect(body.addedLines).toBe(1);
      expect(body.removedLines).toBe(1);
      expect(body.diffLines).toEqual([
        { kind: "removed", text: "A" },
        { kind: "added", text: "B" },
      ]);
    } finally {
      rmSync(baseDir, { recursive: true, force: true });
    }
  });

  it("returns 404 when requested path has no mutations", async () => {
    const baseDir = mkdtempSync(join(tmpdir(), "oppi-server-overall-diff-"));
    const session = makeSession("s1");

    try {
      const traceDir = workspaceTraceDir(baseDir, session);
      mkdirSync(traceDir, { recursive: true });
      writeFileSync(join(traceDir, "20260211_uuid.jsonl"), "", "utf8");

      const ctx = {
        storage: {
          getSession: () => session,
          getWorkspace: () => makeWorkspace(baseDir, session),
          getDataDir: () => baseDir,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/sessions/s1/overall-diff",
        new URL("http://localhost/workspaces/w1/sessions/s1/overall-diff?path=file.txt"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(404);
    } finally {
      rmSync(baseDir, { recursive: true, force: true });
    }
  });

  it("returns 400 when path query parameter is missing", async () => {
    const baseDir = mkdtempSync(join(tmpdir(), "oppi-server-overall-diff-"));
    const session = makeSession("s1");

    try {
      const ctx = {
        storage: {
          getSession: () => session,
          getWorkspace: () => makeWorkspace(baseDir, session),
          getDataDir: () => baseDir,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/sessions/s1/overall-diff",
        new URL("http://localhost/workspaces/w1/sessions/s1/overall-diff"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(400);
      expect(res.body).toContain("path parameter required");
    } finally {
      rmSync(baseDir, { recursive: true, force: true });
    }
  });

  it("supports namespaced write tool calls and ignores non-mutations", async () => {
    const baseDir = mkdtempSync(join(tmpdir(), "oppi-server-overall-diff-"));
    const session = makeSession("s1");

    try {
      const traceDir = workspaceTraceDir(baseDir, session);
      mkdirSync(traceDir, { recursive: true });

      const workspaceDir = workspaceRootDir(baseDir, session);
      mkdirSync(workspaceDir, { recursive: true });
      writeFileSync(join(workspaceDir, "file.txt"), "hello", "utf8");

      const jsonl = [
        JSON.stringify({ type: "session", id: "root", timestamp: "2026-02-11T02:00:00.000Z" }),
        JSON.stringify({
          type: "message",
          id: "a-msg",
          parentId: "root",
          timestamp: "2026-02-11T02:00:02.000Z",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "tc-read-ignore",
                name: "functions.read",
                arguments: {
                  path: "file.txt",
                },
              },
              {
                type: "toolCall",
                id: "tc-write-1",
                name: "functions.write",
                arguments: {
                  path: "file.txt",
                  content: "hello",
                },
              },
            ],
          },
        }),
      ].join("\n");

      writeFileSync(join(traceDir, "20260211_uuid.jsonl"), `${jsonl}\n`, "utf8");

      const ctx = {
        storage: {
          getSession: (sessionId: string) =>
            sessionId === session.id ? session : undefined,
          getWorkspace: () => makeWorkspace(baseDir, session),
          getDataDir: () => baseDir,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/sessions/s1/overall-diff",
        new URL("http://localhost/workspaces/w1/sessions/s1/overall-diff?path=file.txt"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        revisionCount: number;
        baselineText: string;
        currentText: string;
        addedLines: number;
        removedLines: number;
      };

      expect(body.revisionCount).toBe(1);
      expect(body.baselineText).toBe("");
      expect(body.currentText).toBe("hello");
      expect(body.addedLines).toBe(1);
      expect(body.removedLines).toBe(0);
    } finally {
      rmSync(baseDir, { recursive: true, force: true });
    }
  });

  it("supports workspace-scoped overall diff route", async () => {
    const baseDir = mkdtempSync(join(tmpdir(), "oppi-server-overall-diff-"));
    const session = makeSession("s1");

    try {
      const traceDir = workspaceTraceDir(baseDir, session);
      mkdirSync(traceDir, { recursive: true });

      const workspaceDir = workspaceRootDir(baseDir, session);
      mkdirSync(workspaceDir, { recursive: true });
      writeFileSync(join(workspaceDir, "file.txt"), "B", "utf8");

      const jsonl = [
        JSON.stringify({ type: "session", id: "root", timestamp: "2026-02-11T02:00:00.000Z" }),
        JSON.stringify({
          type: "message",
          id: "a-msg",
          parentId: "root",
          timestamp: "2026-02-11T02:00:02.000Z",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "tc-edit-1",
                name: "edit",
                arguments: {
                  path: "file.txt",
                  oldText: "A",
                  newText: "B",
                },
              },
            ],
          },
        }),
      ].join("\n");

      writeFileSync(join(traceDir, "20260211_uuid.jsonl"), `${jsonl}\n`, "utf8");

      const ctx = {
        storage: {
          getSession: (sessionId: string) =>
            sessionId === session.id ? session : undefined,
          getWorkspace: () => makeWorkspace(baseDir, session),
          getDataDir: () => baseDir,
        },
      } as unknown as RouteContext;

      const routes = new RouteHandler(ctx);
      const res = makeResponse();

      await routes.dispatch(
        "GET",
        "/workspaces/w1/sessions/s1/overall-diff",
        new URL("http://localhost/workspaces/w1/sessions/s1/overall-diff?path=file.txt"),
        {} as never,
        res as never,
      );

      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { path: string; baselineText: string; currentText: string };
      expect(body.path).toBe("file.txt");
      expect(body.baselineText).toBe("A");
      expect(body.currentText).toBe("B");
    } finally {
      rmSync(baseDir, { recursive: true, force: true });
    }
  });
});
