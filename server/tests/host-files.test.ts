import { afterEach, describe, expect, it } from "vitest";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  existsSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir, tmpdir } from "node:os";
import { join, relative } from "node:path";
import { PassThrough } from "node:stream";
import { once } from "node:events";
import { fileURLToPath } from "node:url";

import { createRouteHelpers } from "../src/routes/http.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import {
  decodeHostResolvedPathHeader,
  encodeHostResolvedPathHeader,
  expandExactHostPath,
} from "../src/host-file-path.js";
import {
  MAX_BROWSE_IMAGE_FILE_SIZE,
  MAX_BROWSE_TEXT_FILE_SIZE,
} from "../src/file-serving-policy.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Workspace } from "../src/types.js";
import type { Logger } from "../src/logger.js";

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

interface HostFileLogLine {
  event: string;
  method?: string;
  realpath?: string;
  size?: number | null;
  status?: number;
}

function makeLogger(lines: HostFileLogLine[]): Logger {
  const record = (event: string, context?: Record<string, unknown>) => {
    lines.push({
      event,
      method: typeof context?.method === "string" ? context.method : undefined,
      realpath: typeof context?.realpath === "string" ? context.realpath : undefined,
      size:
        typeof context?.size === "number" || context?.size === null
          ? (context.size as number | null)
          : undefined,
      status: typeof context?.status === "number" ? context.status : undefined,
    });
  };

  return {
    debug: record,
    info: record,
    warn: record,
    error: record,
    child: () => makeLogger(lines),
    isEnabled: () => true,
  };
}

function makeContext(): RouteContext {
  return {
    storage: {
      getWorkspace: () => undefined,
      getDataDir: () => tmpdir(),
    },
  } as unknown as RouteContext;
}

function makeIncoming(headers: Record<string, string> = {}): IncomingMessage {
  return { headers } as IncomingMessage;
}

async function dispatchHost(
  method: string,
  rawPath: string,
  options: {
    logger?: Logger;
    homeDir?: string;
    headers?: Record<string, string>;
  } = {},
): Promise<MockWritableResponse> {
  const logs: HostFileLogLine[] = [];
  const dispatch = createHostFileRoutes(makeContext(), createRouteHelpers(), {
    logger: options.logger ?? makeLogger(logs),
    homeDir: options.homeDir,
  });
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const url = new URL(`https://localhost${rawPath}`);
  const handled = await dispatch({
    method,
    path: url.pathname,
    url,
    req: makeIncoming(options.headers),
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) {
    await finished;
  }
  return res;
}

describe("expandExactHostPath", () => {
  const home = "/Users/owner";

  it("expands bare ~ and ~/ only", () => {
    expect(expandExactHostPath("~", { homeDir: home })).toBe(home);
    expect(expandExactHostPath("~/notes.md", { homeDir: home })).toBe(`${home}/notes.md`);
  });

  it("rejects ~user and relative leftovers instead of resolving against cwd", () => {
    expect(expandExactHostPath("~other/secrets", { homeDir: home })).toBeNull();
    expect(expandExactHostPath("relative.md", { homeDir: home })).toBeNull();
    expect(expandExactHostPath("./notes.md", { homeDir: home })).toBeNull();
  });

  it("accepts local file:// paths and rejects non-local, single-slash, or queried URLs", () => {
    expect(expandExactHostPath("file:///tmp/foo.md", { homeDir: home })).toBe("/tmp/foo.md");
    expect(expandExactHostPath("file:/tmp/foo.md", { homeDir: home })).toBeNull();
    expect(expandExactHostPath("file://localhost/tmp/foo.md", { homeDir: home })).toBeNull();
    expect(expandExactHostPath("file:///tmp/foo.md?leak=1", { homeDir: home })).toBeNull();
  });

  it("returns null for NUL and malformed file URLs", () => {
    expect(expandExactHostPath("/tmp/foo\0.md", { homeDir: home })).toBeNull();
    expect(expandExactHostPath("file://", { homeDir: home })).toBeNull();
  });

  it("round-trips non-Latin resolved paths through the header encoding", () => {
    const cjk = "/tmp/中文.md";
    const emoji = "/tmp/📄.md";
    expect(encodeHostResolvedPathHeader(cjk)).toBe("/tmp/%E4%B8%AD%E6%96%87.md");
    expect(encodeHostResolvedPathHeader(emoji)).toBe("/tmp/%F0%9F%93%84.md");
    expect(encodeHostResolvedPathHeader("/tmp/server.ts")).toBe("/tmp/server.ts");
    expect(decodeHostResolvedPathHeader(encodeHostResolvedPathHeader(cjk))).toBe(cjk);
    expect(decodeHostResolvedPathHeader(encodeHostResolvedPathHeader(emoji))).toBe(emoji);
  });
});

describe("GET/HEAD /files/raw", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function tempRoot(prefix: string): string {
    const root = mkdtempSync(join(tmpdir(), prefix));
    roots.push(root);
    return root;
  }

  it("serves GET and HEAD for an exact /tmp file", async () => {
    const root = tempRoot("oppi-hostfile-abs-");
    const filePath = join(root, "oppi-debug.log");
    writeFileSync(filePath, "host log\n", "utf8");
    const logs: HostFileLogLine[] = [];
    const logger = makeLogger(logs);

    const getRes = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(filePath)}`, {
      logger,
    });
    expect(getRes.statusCode).toBe(200);
    expect(getRes.headers["Content-Type"]).toMatch(/text\/plain/);
    expect(getRes.headers["X-Oppi-Resolved-Path"]).toBe(realpathSync(filePath));
    expect(getRes.body.toString("utf8")).toBe("host log\n");

    const headRes = await dispatchHost("HEAD", `/files/raw?path=${encodeURIComponent(filePath)}`, {
      logger,
    });
    expect(headRes.statusCode).toBe(200);
    expect(headRes.headers["Content-Length"]).toBe(String(Buffer.byteLength("host log\n")));
    expect(headRes.headers["X-Oppi-Resolved-Path"]).toBe(realpathSync(filePath));
    expect(headRes.body.length).toBe(0);

    const resolvedFilePath = realpathSync(filePath);
    expect(logs).toHaveLength(2);
    expect(logs.every((line) => line.event === "hostfile.read")).toBe(true);
    expect(logs.map((line) => line.method)).toEqual(["GET", "HEAD"]);
    expect(logs.every((line) => line.realpath === resolvedFilePath)).toBe(true);
    expect(logs.every((line) => line.size === Buffer.byteLength("host log\n"))).toBe(true);
    expect(logs.every((line) => line.status === 200)).toBe(true);
    expect(JSON.stringify(logs)).not.toContain("workspace");
  });

  it("serves a non-Latin filename through Node header validation", async () => {
    const root = tempRoot("oppi-hostfile-cjk-");
    const filePath = join(root, "中文.md");
    writeFileSync(filePath, "unicode notes\n", "utf8");
    const resolvedFilePath = realpathSync(filePath);

    const dispatch = createHostFileRoutes(makeContext(), createRouteHelpers());
    const server = createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      void dispatch({
        method: req.method ?? "GET",
        path: url.pathname,
        url,
        req,
        res,
      }).catch((error) => {
        if (!res.headersSent) {
          res.statusCode = 500;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: String(error) }));
          return;
        }
        res.destroy(error instanceof Error ? error : new Error(String(error)));
      });
    });

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      server.close();
      throw new Error("expected a TCP listen address");
    }

    try {
      const res = await fetch(
        `http://127.0.0.1:${address.port}/files/raw?path=${encodeURIComponent(filePath)}`,
      );
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("unicode notes\n");

      const header = res.headers.get("x-oppi-resolved-path");
      expect(header).toBe(encodeHostResolvedPathHeader(resolvedFilePath));
      expect(header, "header must stay ASCII-safe for Node writeHead").toMatch(
        /^[\t\x20-\x7e]+$/,
      );
      expect(header).not.toBe(resolvedFilePath);
      expect(decodeHostResolvedPathHeader(header ?? "")).toBe(resolvedFilePath);
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  });

  it("serves a ~/ path after expanding only the process home", async () => {
    const home = tempRoot("oppi-hostfile-home-");
    mkdirSync(join(home, "notes"), { recursive: true });
    writeFileSync(join(home, "notes", "readme.md"), "from home\n", "utf8");
    const logs: HostFileLogLine[] = [];

    const res = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent("~/notes/readme.md")}`, {
      logger: makeLogger(logs),
      homeDir: home,
    });

    expect(res.statusCode).toBe(200);
    expect(res.body.toString("utf8")).toBe("from home\n");
    expect(res.headers["X-Oppi-Resolved-Path"]).toBe(
      realpathSync(join(home, "notes", "readme.md")),
    );
    expect(logs).toEqual([
      expect.objectContaining({
        event: "hostfile.read",
        method: "GET",
        realpath: realpathSync(join(home, "notes", "readme.md")),
        status: 200,
      }),
    ]);
  });

  it("returns 404 for missing, directory, unreadable, and non-file nodes", async () => {
    const root = tempRoot("oppi-hostfile-nodes-");
    const missing = join(root, "missing.txt");
    const directory = join(root, "dir");
    mkdirSync(directory);
    const unreadable = join(root, "secret.txt");
    writeFileSync(unreadable, "nope\n", "utf8");
    chmodSync(unreadable, 0);
    const fifo = join(root, "pipe.fifo");
    execFileSync("mkfifo", [fifo]);

    try {
      const cases = [
        missing,
        directory,
        unreadable,
        fifo,
        "/dev/null",
      ];
      for (const path of cases) {
        const res = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(path)}`);
        expect(res.statusCode, path).toBe(404);
      }
    } finally {
      chmodSync(unreadable, 0o644);
    }
  });

  it("404s ~user, relative leftovers, and resolution throws without using process.cwd()", async () => {
    const cwdFile = join(process.cwd(), `oppi-hostfile-cwd-${Date.now()}.txt`);
    writeFileSync(cwdFile, "should not be served\n", "utf8");
    roots.push(cwdFile);

    const relativeName = relative(process.cwd(), cwdFile) || cwdFile;
    const cases = [
      `~/../${relativeName}`,
      relativeName,
      "./package.json",
      "~root/.ssh/id_rsa",
      "file://",
      `/tmp/bad\0name.txt`,
    ];

    for (const path of cases) {
      const res = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(path)}`);
      expect(res.statusCode, path).toBe(404);
      expect(res.body.toString("utf8")).not.toContain("should not be served");
    }
  });

  it("reuses browse size caps and streams byte ranges", async () => {
    const root = tempRoot("oppi-hostfile-range-");
    const textPath = join(root, "notes.txt");
    writeFileSync(textPath, "0123456789", "utf8");
    const hugePath = join(root, "huge.txt");
    writeFileSync(hugePath, Buffer.alloc(MAX_BROWSE_TEXT_FILE_SIZE + 1, 0x61));
    const imagePath = join(root, "huge.png");
    writeFileSync(imagePath, Buffer.alloc(MAX_BROWSE_IMAGE_FILE_SIZE + 1, 0x89));

    const rangeRes = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(textPath)}`, {
      headers: { range: "bytes=2-5" },
    });
    expect(rangeRes.statusCode).toBe(206);
    expect(rangeRes.headers["Content-Range"]).toBe("bytes 2-5/10");
    expect(rangeRes.body.toString("utf8")).toBe("2345");

    const textTooLarge = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(hugePath)}`);
    expect(textTooLarge.statusCode).toBe(413);

    const imageTooLarge = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(imagePath)}`);
    expect(imageTooLarge.statusCode).toBe(413);
  });

  it("returns the canonical realpath for a disguised tilde or symlink request", async () => {
    const root = tempRoot("oppi-hostfile-realpath-");
    const target = join(root, "secret.txt");
    writeFileSync(target, "classified\n", "utf8");
    const alias = join(root, "harmless-note.txt");
    symlinkSync(target, alias);
    const home = tempRoot("oppi-hostfile-tilde-");
    writeFileSync(join(home, "secret"), "from home\n", "utf8");

    const aliasRes = await dispatchHost("HEAD", `/files/raw?path=${encodeURIComponent(alias)}`);
    expect(aliasRes.statusCode).toBe(200);
    expect(aliasRes.headers["X-Oppi-Resolved-Path"]).toBe(realpathSync(target));
    expect(aliasRes.headers["X-Oppi-Resolved-Path"]).not.toBe(alias);

    const tildeRes = await dispatchHost(
      "HEAD",
      `/files/raw?path=${encodeURIComponent("~/secret")}`,
      { homeDir: home },
    );
    expect(tildeRes.statusCode).toBe(200);
    expect(tildeRes.headers["X-Oppi-Resolved-Path"]).toBe(realpathSync(join(home, "secret")));
    expect(tildeRes.headers["X-Oppi-Resolved-Path"]).not.toBe("~/secret");
  });

  it("does not apply isSensitivePath 403 on the owner host-file path", async () => {
    const root = tempRoot("oppi-hostfile-env-");
    const envPath = join(root, ".env");
    writeFileSync(envPath, "SECRET=yes\n", "utf8");

    const res = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(envPath)}`);
    expect(res.statusCode).toBe(200);
    expect(res.body.toString("utf8")).toBe("SECRET=yes\n");
  });

  it("does not list directories and does not require a workspace id", async () => {
    const root = tempRoot("oppi-hostfile-nolist-");
    mkdirSync(join(root, "notes"));
    const dispatch = createHostFileRoutes(makeContext(), createRouteHelpers());

    const listed = await dispatch({
      method: "GET",
      path: "/files",
      url: new URL("https://localhost/files"),
      req: makeIncoming(),
      res: new MockWritableResponse() as unknown as ServerResponse,
    });
    expect(listed).toBe(false);

    const dirRes = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(root)}`);
    expect(dirRes.statusCode).toBe(404);
    expect(dirRes.body.toString("utf8")).not.toMatch(/notes/);
  });
});

describe("workspace confinement after /files/raw lands", () => {
  it("keeps workspace contents and raw 404 for absolute paths and parent escapes", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-ws-confine-"));
    const outside = mkdtempSync(join(tmpdir(), "oppi-ws-outside-"));
    try {
      writeFileSync(join(workspaceRoot, "inside.txt"), "inside\n", "utf8");
      writeFileSync(join(outside, "secret.txt"), "outside\n", "utf8");
      const workspace: Workspace = {
        id: "ws-1",
        name: "Workspace",
        hostMount: workspaceRoot,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const dispatch = createWorkspaceFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) => (workspaceId === "ws-1" ? workspace : undefined),
            getDataDir: () => workspaceRoot,
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const cases = [
        `/workspaces/ws-1/raw/${encodeURIComponent(join(outside, "secret.txt"))}`,
        "/workspaces/ws-1/raw/../secret.txt",
        `/workspaces/ws-1/contents/${encodeURIComponent(outside)}`,
        "/workspaces/ws-1/contents/../",
      ];

      for (const path of cases) {
        const res = new MockWritableResponse();
        const finished = once(res, "finish");
        const url = new URL("https://localhost");
        url.pathname = path;
        const handled = await dispatch({
          method: "GET",
          path,
          url,
          req: makeIncoming(),
          res: res as unknown as ServerResponse,
        });
        expect(handled, path).toBe(true);
        if (!res.writableEnded) {
          await finished;
        }
        expect(res.statusCode, path).toBe(404);
        expect(res.body.toString("utf8")).not.toContain("outside");
      }

      const hostRes = await dispatchHost(
        "GET",
        `/files/raw?path=${encodeURIComponent(join(outside, "secret.txt"))}`,
      );
      expect(hostRes.statusCode).toBe(200);
      expect(hostRes.body.toString("utf8")).toBe("outside\n");
    } finally {
      rmSync(workspaceRoot, { recursive: true, force: true });
      rmSync(outside, { recursive: true, force: true });
    }
  });
});

describe("host-file path helpers stay fail-closed", () => {
  it("does not follow a directory or socket-like node after realpath", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-hostfile-symlink-"));
    try {
      mkdirSync(join(root, "real-dir"));
      const link = join(root, "alias");
      symlinkSync(join(root, "real-dir"), link);
      const res = await dispatchHost("GET", `/files/raw?path=${encodeURIComponent(link)}`);
      expect(res.statusCode).toBe(404);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("expands a local file URL the same way as its POSIX path", () => {
    const posix = "/tmp/oppi-debug.log";
    expect(expandExactHostPath(`file://${posix}`)).toBe(posix);
    expect(expandExactHostPath(fileURLToPath(new URL(`file://${posix}`)))).toBe(posix);
  });
});

describe("auth contract", () => {
  it("registers /files/raw as an owner-authenticated session route", async () => {
    const { apiRouteSpecs } = await import("../src/routes/registry.js");
    const routes = apiRouteSpecs.filter((route) => route.path === "/files/raw");
    expect(routes.map((route) => route.method).sort()).toEqual(["GET", "HEAD"]);
    expect(routes.every((route) => route.auth === "owner")).toBe(true);
    expect(routes.every((route) => route.nativeClientUses?.includes("session"))).toBe(true);
  });
});

void existsSync;
