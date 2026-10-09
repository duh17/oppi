import { afterEach, describe, expect, it } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { once } from "node:events";

import { sendFileBytes } from "../src/current-file.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
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
  return { id, name: `workspace ${id}`, hostMount: root } as Workspace;
}

function makeSession(): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

type Origin = "workspace" | "session";

/** `/files/current` for the workspace `ws-1` or its session `sess-1`; both read the same checkout. */
async function readCurrentFile(
  root: string,
  origin: Origin,
  path: string,
  options: { method?: string; headers?: Record<string, string> } = {},
): Promise<MockWritableResponse> {
  const workspaces = [makeWorkspace(root)];
  const session = makeSession();
  const dispatch = createHostFileRoutes(
    {
      storage: {
        getWorkspace: (id: string) => workspaces.find((item) => item.id === id),
        getSession: (id: string) => (id === session.id ? session : undefined),
        getDataDir: () => tmpdir(),
      },
    } as unknown as RouteContext,
    createRouteHelpers(),
  );
  const params = new URLSearchParams(
    origin === "workspace"
      ? { origin, workspaceId: "ws-1", path }
      : { origin, sessionId: "sess-1", path },
  );
  const url = new URL(`https://localhost/files/current?${params}`);
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const handled = await dispatch({
    method: options.method ?? "GET",
    path: url.pathname,
    url,
    req: { headers: options.headers ?? {} } as IncomingMessage,
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

describe("current-file transport security", () => {
  const roots: string[] = [];

  function tempRoot(prefix: string): string {
    const created = mkdtempSync(join(tmpdir(), prefix));
    roots.push(created);
    return created;
  }

  afterEach(() => {
    for (const created of roots.splice(0)) rmSync(created, { recursive: true, force: true });
  });

  it.each<Origin>(["workspace", "session"])(
    "serves .env inside the workspace for origin=%s",
    async (origin) => {
      const root = tempRoot("oppi-file-security-");
      writeFileSync(join(root, ".env"), "SECRET=yes\n", "utf8");

      const res = await readCurrentFile(root, origin, ".env");

      expect(res.statusCode).toBe(200);
      expect(res.body.toString("utf8")).toBe("SECRET=yes\n");
    },
  );

  it.each<Origin>(["workspace", "session"])(
    "resolves reserved and non-ASCII path characters for origin=%s",
    async (origin) => {
      const root = tempRoot("oppi-file-security-encoded-");
      mkdirSync(join(root, "folder one", "plus+?hash#percent%&"), { recursive: true });
      writeFileSync(
        join(root, "folder one", "plus+?hash#percent%&", "日本語 notes.txt"),
        "encoded path works\n",
        "utf8",
      );

      const res = await readCurrentFile(
        root,
        origin,
        "folder one/plus+?hash#percent%&/日本語 notes.txt",
      );

      expect(res.statusCode).toBe(200);
      expect(res.body.toString("utf8")).toBe("encoded path works\n");
    },
  );

  it.each<Origin>(["workspace", "session"])(
    "serves byte ranges, full-body range advertisement, and HEAD for origin=%s",
    async (origin) => {
      const root = tempRoot("oppi-file-range-");
      writeFileSync(join(root, "clip.mp4"), "0123456789", "utf8");

      const partial = await readCurrentFile(root, origin, "clip.mp4", {
        headers: { range: "bytes=2-5" },
      });
      expect(partial.statusCode).toBe(206);
      expect(partial.headers["Content-Type"]).toBe("video/mp4");
      expect(partial.headers["Accept-Ranges"]).toBe("bytes");
      expect(partial.headers["Content-Range"]).toBe("bytes 2-5/10");
      expect(partial.headers["Content-Length"]).toBe("4");
      expect(partial.body.toString("utf8")).toBe("2345");

      const full = await readCurrentFile(root, origin, "clip.mp4");
      expect(full.statusCode).toBe(200);
      expect(full.headers["Accept-Ranges"]).toBe("bytes");
      expect(full.headers["Content-Length"]).toBe("10");
      expect(full.body.toString("utf8")).toBe("0123456789");

      const head = await readCurrentFile(root, origin, "clip.mp4", { method: "HEAD" });
      expect(head.statusCode).toBe(200);
      expect(head.headers["Content-Type"]).toBe("video/mp4");
      expect(head.headers["Content-Length"]).toBe("10");
      expect(head.body).toHaveLength(0);

      const unsatisfiable = await readCurrentFile(root, origin, "clip.mp4", {
        headers: { range: "bytes=50-60" },
      });
      expect(unsatisfiable.statusCode).toBe(416);
      expect(unsatisfiable.headers["Content-Range"]).toBe("bytes */10");
      expect(unsatisfiable.headers["Content-Length"]).toBe("0");
      expect(unsatisfiable.body).toHaveLength(0);
    },
  );

  it("reports an unreadable file as an error before sending success headers", async () => {
    const root = tempRoot("oppi-file-security-stream-error-");
    const res = new MockWritableResponse();
    const finished = once(res, "finish");

    const status = await sendFileBytes(
      undefined,
      res as unknown as ServerResponse,
      "GET",
      { filePath: join(root, "missing.txt"), contentType: "text/plain; charset=utf-8", size: 1 },
      { rangeLogTag: "test" },
    );
    await finished;

    expect(status).toBe(res.statusCode);
    expect(res.statusCode).toBeGreaterThanOrEqual(400);
    expect(res.headers["Content-Range"]).toBeUndefined();
    expect(JSON.parse(res.body.toString("utf8"))).toHaveProperty("error");
  });

  it.each<Origin>(["workspace", "session"])(
    "serves reported absolute files outside the checkout for origin=%s",
    async (origin) => {
      const root = tempRoot("oppi-file-security-root-");
      const otherRoot = tempRoot("oppi-file-security-other-");
      const otherFile = join(otherRoot, "release-lanes.md");
      writeFileSync(otherFile, "other workspace\n", "utf8");
      const homeRoot = mkdtempSync(join(homedir(), ".oppi-file-security-unsafe-"));
      roots.push(homeRoot);
      const homeFile = join(homeRoot, "report.md");
      writeFileSync(homeFile, "home artifact\n", "utf8");

      const other = await readCurrentFile(root, origin, otherFile);
      expect(other.statusCode).toBe(200);
      expect(other.body.toString("utf8")).toBe("other workspace\n");

      const home = await readCurrentFile(root, origin, homeFile);
      expect(home.statusCode).toBe(200);
      expect(home.body.toString("utf8")).toBe("home artifact\n");
    },
  );
});
