import { afterEach, describe, expect, it } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { once } from "node:events";

import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import { createSessionFileHandlers } from "../src/routes/session-files.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";

class MockWritableResponse extends PassThrough {
  statusCode = 0;
  headers: Record<string, string> = {};
  body = Buffer.alloc(0);

  constructor() {
    super();
    this.on("data", (chunk) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      this.body = Buffer.concat([this.body, buffer]);
    });
  }

  writeHead(statusCode: number, headers: Record<string, string | number> = {}): this {
    this.statusCode = statusCode;
    this.headers = Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [key, String(value)]),
    );
    return this;
  }
}

function makeWorkspace(root: string, id = "ws-1"): Workspace {
  return {
    id,
    name: id === "ws-1" ? "workspace" : `workspace ${id}`,
    hostMount: root,
  } as Workspace;
}

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeHelpers(errors: Array<{ status: number; message: string }>): RouteHelpers {
  return {
    parseBody: async <T>() => ({}) as T,
    json: () => undefined,
    compressedJson: () => undefined,
    error: (res, status, message) => {
      errors.push({ status, message });
      res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(message);
    },
  };
}

function makeContext(
  workspace: Workspace,
  session: Session,
  extraWorkspaces: Workspace[] = [],
): RouteContext {
  const workspaces = [workspace, ...extraWorkspaces];
  return {
    storage: {
      getWorkspace: (workspaceId: string) => workspaces.find((item) => item.id === workspaceId),
      getSession: (sessionId: string) => (sessionId === session.id ? session : undefined),
      listWorkspaces: () => workspaces,
      getDataDir: () => tmpdir(),
    },
  } as unknown as RouteContext;
}

function makeIncoming(headers: Record<string, string> = {}): IncomingMessage {
  return { headers } as IncomingMessage;
}

describe("file transport security parity", () => {
  let root: string;

  afterEach(() => {
    if (root) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("serves workspace raw .env and session raw .env when the file stays inside the workspace", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-"));
    writeFileSync(join(root, ".env"), "SECRET=yes\n", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession({
      changeStats: { changedFiles: [".env"], filesChanged: 1 } as Session["changeStats"],
    });
    const errors: Array<{ status: number; message: string }> = [];
    const helpers = makeHelpers(errors);
    const ctx = makeContext(workspace, session);

    const workspaceRoutes = createWorkspaceFileRoutes(ctx, helpers);
    const workspaceRes = new MockWritableResponse();
    const workspaceFinished = once(workspaceRes, "finish");
    const handledRaw = await workspaceRoutes({
      method: "GET",
      path: "/workspaces/ws-1/raw/.env",
      url: new URL("https://localhost/workspaces/ws-1/raw/.env"),
      req: new PassThrough() as unknown as IncomingMessage,
      res: workspaceRes as unknown as ServerResponse,
    });
    await workspaceFinished;

    const sessionHandlers = createSessionFileHandlers(ctx, helpers);
    const sessionRes = new MockWritableResponse();
    const sessionFinished = once(sessionRes, "finish");
    await sessionHandlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      ".env",
      sessionRes as unknown as ServerResponse,
    );
    await sessionFinished;

    expect(handledRaw).toBe(true);
    expect(errors).toEqual([]);
    expect(workspaceRes.statusCode).toBe(200);
    expect(workspaceRes.body.toString("utf8")).toBe("SECRET=yes\n");
    expect(sessionRes.statusCode).toBe(200);
    expect(sessionRes.body.toString("utf8")).toBe("SECRET=yes\n");
  });

  it("decodes percent-encoded workspace raw route paths before filesystem resolution", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-encoded-"));
    mkdirSync(join(root, "folder one", "plus+?hash#percent%&"), { recursive: true });
    writeFileSync(
      join(root, "folder one", "plus+?hash#percent%&", "日本語 notes.txt"),
      "encoded path works\n",
      "utf8",
    );

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const route = createWorkspaceFileRoutes(makeContext(workspace, session), makeHelpers(errors));
    const rawPath =
      "/workspaces/ws-1/raw/folder%20one/plus%2B%3Fhash%23percent%25%26/%E6%97%A5%E6%9C%AC%E8%AA%9E%20notes.txt";
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "GET",
      path: rawPath,
      url: new URL(`https://localhost${rawPath}`),
      req: new PassThrough() as unknown as IncomingMessage,
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(200);
    expect(res.body.toString("utf8")).toBe("encoded path works\n");
  });

  it("keeps normal non-sensitive session raw previews working", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-ok-"));
    mkdirSync(join(root, "notes"), { recursive: true });
    writeFileSync(join(root, "notes", "hello world.txt"), "hi from oppi\n", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const helpers = makeHelpers(errors);
    const handlers = createSessionFileHandlers(makeContext(workspace, session), helpers);

    const rawRes = new MockWritableResponse();
    const rawFinished = once(rawRes, "finish");
    await handlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      "notes/hello world.txt",
      rawRes as unknown as ServerResponse,
    );
    await rawFinished;

    expect(errors).toEqual([]);
    expect(rawRes.statusCode).toBe(200);
    expect(rawRes.body.toString("utf8")).toBe("hi from oppi\n");
  });

  it("serves session raw byte ranges and HEAD without buffering media", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-session-file-range-"));
    writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const handlers = createSessionFileHandlers(
      makeContext(workspace, session),
      makeHelpers(errors),
    );

    const rangeRes = new MockWritableResponse();
    const rangeFinished = once(rangeRes, "finish");
    await handlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      "clip.mp4",
      rangeRes as unknown as ServerResponse,
      makeIncoming({ range: "bytes=2-5" }),
      "GET",
    );
    await rangeFinished;

    expect(rangeRes.statusCode).toBe(206);
    expect(rangeRes.headers["Accept-Ranges"]).toBe("bytes");
    expect(rangeRes.headers["Content-Range"]).toBe("bytes 2-5/10");
    expect(rangeRes.headers["Content-Length"]).toBe("4");
    expect(rangeRes.body.toString("utf8")).toBe("2345");

    const headRes = new MockWritableResponse();
    const headFinished = once(headRes, "finish");
    await handlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      "clip.mp4",
      headRes as unknown as ServerResponse,
      makeIncoming(),
      "HEAD",
    );
    await headFinished;

    expect(errors).toEqual([]);
    expect(headRes.statusCode).toBe(200);
    expect(headRes.headers["Content-Type"]).toBe("video/mp4");
    expect(headRes.headers["Accept-Ranges"]).toBe("bytes");
    expect(headRes.headers["Content-Length"]).toBe("10");
    expect(headRes.body).toHaveLength(0);
  });

  it("rejects unsatisfiable session raw ranges with the file size", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-session-file-range-invalid-"));
    writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");
    const workspace = makeWorkspace(root);
    const errors: Array<{ status: number; message: string }> = [];
    const handlers = createSessionFileHandlers(
      makeContext(workspace, makeSession()),
      makeHelpers(errors),
    );
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    await handlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      "clip.mp4",
      res as unknown as ServerResponse,
      makeIncoming({ range: "bytes=50-60" }),
      "GET",
    );
    await finished;

    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(416);
    expect(res.headers["Content-Range"]).toBe("bytes */10");
    expect(res.headers["Content-Length"]).toBe("0");
    expect(res.body).toHaveLength(0);
  });

  it("reports session raw stream open errors before sending success headers", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-stream-error-"));
    const workspace = makeWorkspace(root);
    const session = makeSession({
      changeStats: {
        changedFiles: ["missing.txt"],
        filesChanged: 1,
      } as Session["changeStats"],
    });
    const errors: Array<{ status: number; message: string }> = [];
    const helpers = makeHelpers(errors);
    const traceService = {
      listSessionChanges: () => ({
        workspaceId: "ws-1",
        sessionId: "sess-1",
        files: [],
        changedFileCount: 0,
        changedFilesOverflow: 0,
      }),
      getSessionRawFile: async () => ({
        kind: "ok" as const,
        filePath: join(root, "missing.txt"),
        contentType: "text/plain; charset=utf-8",
        size: 1,
      }),
    } as unknown as SessionTraceService;
    const handlers = createSessionFileHandlers(
      makeContext(workspace, session),
      helpers,
      traceService,
    );

    const rawRes = new MockWritableResponse();
    const rawFinished = once(rawRes, "finish");
    await handlers.handleGetSessionRaw(
      "ws-1",
      "sess-1",
      "missing.txt",
      rawRes as unknown as ServerResponse,
    );
    await rawFinished;

    expect(errors).toEqual([{ status: 500, message: "Failed to read file" }]);
    expect(rawRes.statusCode).toBe(500);
  });

  it("serves workspace raw byte ranges with partial-content headers", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-range-"));
    writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const route = createWorkspaceFileRoutes(makeContext(workspace, session), makeHelpers(errors));
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "GET",
      path: "/workspaces/ws-1/raw/clip.mp4",
      url: new URL("https://localhost/workspaces/ws-1/raw/clip.mp4"),
      req: makeIncoming({ range: "bytes=2-5" }),
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(206);
    expect(res.headers["Content-Type"]).toBe("video/mp4");
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Range"]).toBe("bytes 2-5/10");
    expect(res.headers["Content-Length"]).toBe("4");
    expect(res.body.toString("utf8")).toBe("2345");
  });

  it("advertises range support on full workspace raw responses", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-range-full-"));
    writeFileSync(join(root, "notes.txt"), "hello", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const route = createWorkspaceFileRoutes(makeContext(workspace, session), makeHelpers(errors));
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "GET",
      path: "/workspaces/ws-1/raw/notes.txt",
      url: new URL("https://localhost/workspaces/ws-1/raw/notes.txt"),
      req: makeIncoming(),
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(200);
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Length"]).toBe("5");
    expect(res.body.toString("utf8")).toBe("hello");
  });

  it("returns 416 for unsatisfiable workspace raw byte ranges", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-range-416-"));
    writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const route = createWorkspaceFileRoutes(makeContext(workspace, session), makeHelpers(errors));
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "GET",
      path: "/workspaces/ws-1/raw/clip.mp4",
      url: new URL("https://localhost/workspaces/ws-1/raw/clip.mp4"),
      req: makeIncoming({ range: "bytes=99-100" }),
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(416);
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Range"]).toBe("bytes */10");
    expect(res.headers["Content-Length"]).toBe("0");
    expect(res.body).toHaveLength(0);
  });

  it("handles workspace raw HEAD requests without a body", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-range-head-"));
    writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession();
    const errors: Array<{ status: number; message: string }> = [];
    const route = createWorkspaceFileRoutes(makeContext(workspace, session), makeHelpers(errors));
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "HEAD",
      path: "/workspaces/ws-1/raw/clip.mp4",
      url: new URL("https://localhost/workspaces/ws-1/raw/clip.mp4"),
      req: makeIncoming(),
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(200);
    expect(res.headers["Content-Type"]).toBe("video/mp4");
    expect(res.headers["Accept-Ranges"]).toBe("bytes");
    expect(res.headers["Content-Length"]).toBe("10");
    expect(res.body).toHaveLength(0);
  });

  it("serves reported absolute session raw reads from another workspace", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-root-"));
    const otherRoot = mkdtempSync(join(tmpdir(), "oppi-file-security-other-"));
    const otherFile = join(otherRoot, "release-lanes.md");
    writeFileSync(otherFile, "other workspace\n", "utf8");

    try {
      const workspace = makeWorkspace(root);
      const otherWorkspace = makeWorkspace(otherRoot, "ws-2");
      const session = makeSession({
        changeStats: {
          changedFiles: [otherFile],
          filesChanged: 1,
        } as Session["changeStats"],
      });
      const errors: Array<{ status: number; message: string }> = [];
      const handlers = createSessionFileHandlers(
        makeContext(workspace, session, [otherWorkspace]),
        makeHelpers(errors),
      );

      const rawRes = new MockWritableResponse();
      const rawFinished = once(rawRes, "finish");
      await handlers.handleGetSessionRaw(
        "ws-1",
        "sess-1",
        otherFile,
        rawRes as unknown as ServerResponse,
      );
      await rawFinished;

      expect(errors).toEqual([]);
      expect(rawRes.statusCode).toBe(200);
      expect(rawRes.body.toString("utf8")).toBe("other workspace\n");
    } finally {
      rmSync(otherRoot, { recursive: true, force: true });
    }
  });

  it("serves reported absolute session-created temp artifacts", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-root-"));
    const artifactRoot = mkdtempSync(join(tmpdir(), "oppi-session-artifact-"));
    const artifactFile = join(artifactRoot, "pi-codex-websocket-limit-issue.md");
    writeFileSync(artifactFile, "temp artifact\n", "utf8");

    try {
      const workspace = makeWorkspace(root);
      const session = makeSession({
        changeStats: {
          changedFiles: [artifactFile],
          filesChanged: 1,
          _sessionCreatedFiles: [artifactFile],
        } as Session["changeStats"],
      });
      const errors: Array<{ status: number; message: string }> = [];
      const handlers = createSessionFileHandlers(
        makeContext(workspace, session),
        makeHelpers(errors),
      );

      const rawRes = new MockWritableResponse();
      const rawFinished = once(rawRes, "finish");
      await handlers.handleGetSessionRaw(
        "ws-1",
        "sess-1",
        artifactFile,
        rawRes as unknown as ServerResponse,
      );
      await rawFinished;

      expect(errors).toEqual([]);
      expect(rawRes.statusCode).toBe(200);
      expect(rawRes.body.toString("utf8")).toBe("temp artifact\n");
    } finally {
      rmSync(artifactRoot, { recursive: true, force: true });
    }
  });

  it("serves reported session-created files outside configured workspaces", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-root-"));
    const unsafeRoot = mkdtempSync(join(homedir(), ".oppi-file-security-unsafe-"));
    const unsafeFile = join(unsafeRoot, "report.md");
    writeFileSync(unsafeFile, "home artifact\n", "utf8");

    try {
      const workspace = makeWorkspace(root);
      const session = makeSession({
        changeStats: {
          changedFiles: [unsafeFile],
          filesChanged: 1,
          _sessionCreatedFiles: [unsafeFile],
        } as Session["changeStats"],
      });
      const errors: Array<{ status: number; message: string }> = [];
      const handlers = createSessionFileHandlers(
        makeContext(workspace, session),
        makeHelpers(errors),
      );

      const rawRes = new MockWritableResponse();
      const rawFinished = once(rawRes, "finish");
      await handlers.handleGetSessionRaw(
        "ws-1",
        "sess-1",
        unsafeFile,
        rawRes as unknown as ServerResponse,
      );
      await rawFinished;

      expect(errors).toEqual([]);
      expect(rawRes.statusCode).toBe(200);
      expect(rawRes.body.toString("utf8")).toBe("home artifact\n");
    } finally {
      rmSync(unsafeRoot, { recursive: true, force: true });
    }
  });

  it("blocks unreported session raw reads outside the workspace", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-root-"));
    const outsideRoot = mkdtempSync(join(tmpdir(), "oppi-file-security-outside-"));
    const outsideFile = join(outsideRoot, "outside.txt");
    writeFileSync(outsideFile, "outside workspace\n", "utf8");

    try {
      const workspace = makeWorkspace(root);
      const session = makeSession();
      const errors: Array<{ status: number; message: string }> = [];
      const handlers = createSessionFileHandlers(
        makeContext(workspace, session),
        makeHelpers(errors),
      );

      await handlers.handleGetSessionRaw(
        "ws-1",
        "sess-1",
        outsideFile,
        new MockWritableResponse() as unknown as ServerResponse,
      );

      expect(errors).toEqual([{ status: 403, message: "Path outside session workspace" }]);
    } finally {
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  });
});
