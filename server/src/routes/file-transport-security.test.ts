import { afterEach, describe, expect, it } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { once } from "node:events";

import { createWorkspaceFileRoutes } from "./workspace-files.js";
import { createSessionFileHandlers } from "./session-files.js";
import type { RouteContext, RouteHelpers } from "./types.js";
import type { Session, Workspace } from "../types.js";

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

function makeWorkspace(root: string): Workspace {
  return {
    id: "ws-1",
    name: "workspace",
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

function makeContext(workspace: Workspace, session: Session): RouteContext {
  return {
    storage: {
      getWorkspace: (workspaceId: string) => (workspaceId === workspace.id ? workspace : undefined),
      getSession: (sessionId: string) => (sessionId === session.id ? session : undefined),
    },
  } as unknown as RouteContext;
}

describe("file transport security parity", () => {
  let root: string;

  afterEach(() => {
    if (root) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("blocks sensitive files consistently across browse, session file, and touched file routes", async () => {
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
    const handledBrowse = await workspaceRoutes({
      method: "GET",
      path: "/workspaces/ws-1/files/.env",
      url: new URL("https://localhost/workspaces/ws-1/files/.env?mode=browse"),
      req: new PassThrough() as unknown as IncomingMessage,
      res: new MockWritableResponse() as unknown as ServerResponse,
    });

    const sessionHandlers = createSessionFileHandlers(ctx, helpers);
    await sessionHandlers.handleGetSessionFile(
      "ws-1",
      "sess-1",
      new URL("https://localhost/workspaces/ws-1/sessions/sess-1/files?path=.env"),
      new MockWritableResponse() as unknown as ServerResponse,
    );
    await sessionHandlers.handleGetTouchedFile(
      "ws-1",
      "sess-1",
      new URL("https://localhost/workspaces/ws-1/sessions/sess-1/touched-file?path=.env"),
      new MockWritableResponse() as unknown as ServerResponse,
    );

    expect(handledBrowse).toBe(true);
    expect(errors).toEqual([
      { status: 403, message: "Access denied: sensitive file" },
      { status: 403, message: "Access denied: sensitive file" },
      { status: 403, message: "Access denied: sensitive file" },
    ]);
  });

  it("decodes percent-encoded workspace file route paths before filesystem resolution", async () => {
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
      "/workspaces/ws-1/files/folder%20one/plus%2B%3Fhash%23percent%25%26/%E6%97%A5%E6%9C%AC%E8%AA%9E%20notes.txt";
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const handled = await route({
      method: "GET",
      path: rawPath,
      url: new URL(`https://localhost${rawPath}?mode=browse`),
      req: new PassThrough() as unknown as IncomingMessage,
      res: res as unknown as ServerResponse,
    });
    await finished;

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(res.statusCode).toBe(200);
    expect(res.body.toString("utf8")).toBe("encoded path works\n");
  });

  it("keeps normal non-sensitive session file reads and touched-file previews working", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-file-security-ok-"));
    mkdirSync(join(root, "notes"), { recursive: true });
    writeFileSync(join(root, "notes", "hello world.txt"), "hi from oppi\n", "utf8");

    const workspace = makeWorkspace(root);
    const session = makeSession({
      changeStats: {
        changedFiles: ["notes/hello world.txt"],
        filesChanged: 1,
      } as Session["changeStats"],
    });
    const errors: Array<{ status: number; message: string }> = [];
    const helpers = makeHelpers(errors);
    const handlers = createSessionFileHandlers(makeContext(workspace, session), helpers);

    const sessionRes = new MockWritableResponse();
    const sessionFinished = once(sessionRes, "finish");
    await handlers.handleGetSessionFile(
      "ws-1",
      "sess-1",
      new URL(
        "https://localhost/workspaces/ws-1/sessions/sess-1/files?path=notes%2Fhello%20world.txt",
      ),
      sessionRes as unknown as ServerResponse,
    );
    await sessionFinished;

    const touchedRes = new MockWritableResponse();
    const touchedFinished = once(touchedRes, "finish");
    await handlers.handleGetTouchedFile(
      "ws-1",
      "sess-1",
      new URL(
        "https://localhost/workspaces/ws-1/sessions/sess-1/touched-file?path=notes%2Fhello%20world.txt",
      ),
      touchedRes as unknown as ServerResponse,
    );
    await touchedFinished;

    expect(errors).toEqual([]);
    expect(sessionRes.statusCode).toBe(200);
    expect(sessionRes.body.toString("utf8")).toBe("hi from oppi\n");
    expect(touchedRes.statusCode).toBe(200);
    expect(touchedRes.body.toString("utf8")).toBe("hi from oppi\n");
  });
});
