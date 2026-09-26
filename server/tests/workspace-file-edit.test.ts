import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  chmodSync,
  constants as fsConstants,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import {
  createServer,
  request as httpRequest,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const fsControl = vi.hoisted(() => {
  const rename = vi.fn();
  const chmod = vi.fn();
  const open = vi.fn();
  return {
    rename,
    chmod,
    open,
    actual: null as typeof import("node:fs/promises") | null,
  };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  fsControl.actual = actual;
  fsControl.rename.mockImplementation((...args: Parameters<typeof actual.rename>) =>
    actual.rename(...args),
  );
  fsControl.chmod.mockImplementation((...args: Parameters<typeof actual.chmod>) =>
    actual.chmod(...args),
  );
  fsControl.open.mockImplementation((...args: Parameters<typeof actual.open>) =>
    actual.open(...args),
  );
  return {
    ...actual,
    rename: fsControl.rename,
    chmod: fsControl.chmod,
    open: fsControl.open,
  };
});

import { createLogger } from "../src/logger.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";
import {
  makeRawRequest,
  makeResponse,
  MockWritableResponse,
} from "./harness/route-test-helpers.js";

const MAX_BYTES = 1_048_576;

interface Fixture {
  dataDir: string;
  home: string;
  hostRoot: string;
  sandboxMount: string;
  outside: string;
  workspaces: Workspace[];
  sessions: Session[];
}

const roots: string[] = [];

function tempRoot(prefix: string): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  roots.push(root);
  return root;
}

function restoreFsMocks(): void {
  const actual = fsControl.actual;
  if (!actual) return;
  fsControl.rename.mockImplementation((...args: Parameters<typeof actual.rename>) =>
    actual.rename(...args),
  );
  fsControl.chmod.mockImplementation((...args: Parameters<typeof actual.chmod>) =>
    actual.chmod(...args),
  );
  fsControl.open.mockImplementation((...args: Parameters<typeof actual.open>) =>
    actual.open(...args),
  );
  fsControl.rename.mockClear();
  fsControl.chmod.mockClear();
  fsControl.open.mockClear();
}

function wrapTempHandleChmod(fn: () => void): void {
  const actual = fsControl.actual;
  if (!actual) throw new Error("fs mock not initialized");
  fsControl.open.mockImplementation(async (...args: Parameters<typeof actual.open>) => {
    const handle = await actual.open(...args);
    const flags = args[1];
    if (typeof flags === "number" && flags & fsConstants.O_CREAT) {
      const origChmod = handle.chmod.bind(handle);
      handle.chmod = (async (mode: Parameters<typeof handle.chmod>[0]) => {
        const result = await origChmod(mode);
        fn();
        return result;
      }) as typeof handle.chmod;
    }
    return handle;
  });
}

function onlyEditTemp(dir: string): string {
  const temps = editTemps(dir);
  if (temps.length !== 1) {
    throw new Error(`expected one edit temp, found ${JSON.stringify(temps)}`);
  }
  return join(dir, temps[0]);
}

afterEach(() => {
  restoreFsMocks();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function etagFor(bytes: Buffer): string {
  return `"sha256-${createHash("sha256").update(bytes).digest("hex")}"`;
}

function editTemps(dir: string): string[] {
  return readdirSync(dir).filter((name) => name.startsWith(".oppi-edit-") && name.endsWith(".tmp"));
}

function session(overrides: Partial<Session>): Session {
  return {
    id: "sess",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  } as Session;
}

function seed(): Fixture {
  const dataDir = tempRoot("oppi-edit-data-");
  const home = tempRoot("oppi-edit-home-");
  const hostRoot = tempRoot("oppi-edit-host-");
  const sandboxMount = tempRoot("oppi-edit-sandbox-");
  const outside = tempRoot("oppi-edit-outside-");

  writeFileSync(join(hostRoot, "README.md"), "host workspace\n");
  writeFileSync(join(hostRoot, "pretty.json"), '{"a":1}');
  mkdirSync(join(hostRoot, "sub"));
  writeFileSync(join(hostRoot, "sub", "nested.md"), "nested\n");
  mkdirSync(join(sandboxMount, "reports"));
  writeFileSync(join(sandboxMount, "reports", "out.txt"), "sandbox bytes\n");
  writeFileSync(join(outside, "secret.txt"), "host-secret");
  symlinkSync(join(outside, "secret.txt"), join(sandboxMount, "escape.txt"));
  symlinkSync(join(hostRoot, "README.md"), join(hostRoot, "alias.md"));

  const workspaces: Workspace[] = [
    { id: "ws-host", name: "host", hostMount: hostRoot, createdAt: 1, updatedAt: 1 } as Workspace,
    {
      id: "ws-sandbox",
      name: "deep-research",
      runtime: "sandbox",
      hostMount: sandboxMount,
      createdAt: 1,
      updatedAt: 1,
    } as Workspace,
  ];
  const sessions = [
    session({ id: "host-session", workspaceId: "ws-host" }),
    session({ id: "sandbox-session", workspaceId: "ws-sandbox" }),
  ];
  return { dataDir, home, hostRoot, sandboxMount, outside, workspaces, sessions };
}

function context(fixture: Fixture): RouteContext {
  return {
    storage: {
      getDataDir: () => fixture.dataDir,
      getWorkspace: (id: string) => fixture.workspaces.find((workspace) => workspace.id === id),
      getSession: (id: string) => fixture.sessions.find((item) => item.id === id),
    },
  } as unknown as RouteContext;
}

function query(params: Record<string, string>): string {
  return new URLSearchParams(params).toString();
}

function workspaceQuery(
  fixture: Fixture,
  path: string,
  extra: Record<string, string> = {},
): Record<string, string> {
  return { origin: "workspace", workspaceId: "ws-host", path, ...extra };
}

async function currentFile(
  fixture: Fixture,
  method: string,
  pathAndQuery: string,
  headers: Record<string, string> = {},
): Promise<MockWritableResponse> {
  const dispatch = createHostFileRoutes(context(fixture), createRouteHelpers(), {
    homeDir: fixture.home,
  });
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const url = new URL(`https://localhost${pathAndQuery}`);
  const handled = await dispatch({
    method,
    path: url.pathname,
    url,
    req: { headers } as IncomingMessage,
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

async function putCurrent(
  fixture: Fixture,
  params: Record<string, string>,
  body: Buffer,
  headers: Record<string, string> = {},
  logger?: ReturnType<typeof createLogger>,
): Promise<ReturnType<typeof makeResponse>> {
  const dispatch = createHostFileRoutes(context(fixture), createRouteHelpers(), {
    homeDir: fixture.home,
    logger,
  });
  const res = makeResponse();
  const url = new URL(`https://localhost/files/current?${query(params)}`);
  const req = makeRawRequest(body);
  req.headers = {
    "content-length": String(body.length),
    ...headers,
  };
  const handled = await dispatch({
    method: "PUT",
    path: "/files/current",
    url,
    req,
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  return res;
}

describe("workspace file editor GET/HEAD ETag", () => {
  it("returns a strong ETag of the exact returned bytes with and without worktreeId", async () => {
    const fixture = seed();
    execSync(
      "git init -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
      {
        cwd: fixture.hostRoot,
        stdio: "ignore",
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
      },
    );
    const worktree = createWorkspaceWorktree(
      fixture.workspaces[0],
      { branch: "feature/edit" },
      { dataDir: fixture.dataDir },
    );
    const worktreeBytes = Buffer.from("worktree bytes\n");
    writeFileSync(join(worktree.path, "README.md"), worktreeBytes);

    const mainGet = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "README.md"))}`,
    );
    const mainBytes = Buffer.from("host workspace\n");
    expect(mainGet.statusCode).toBe(200);
    expect(mainGet.body.equals(mainBytes)).toBe(true);
    expect(mainGet.headers.ETag).toBe(etagFor(mainBytes));

    const mainHead = await currentFile(
      fixture,
      "HEAD",
      `/files/current?${query(workspaceQuery(fixture, "README.md"))}`,
    );
    expect(mainHead.statusCode).toBe(200);
    expect(mainHead.body.length).toBe(0);
    expect(mainHead.headers.ETag).toBe(etagFor(mainBytes));
    expect(mainHead.headers["Content-Length"]).toBe(String(mainBytes.length));

    const branch = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "README.md", { worktreeId: worktree.id }))}`,
    );
    expect(branch.body.equals(worktreeBytes)).toBe(true);
    expect(branch.headers.ETag).toBe(etagFor(worktreeBytes));
  });

  it("omits ETag for session origin, host origin, oversize, non-UTF-8, symlink, binary, and outside-root paths", async () => {
    const fixture = seed();
    writeFileSync(join(fixture.hostRoot, "big.md"), Buffer.alloc(MAX_BYTES + 1, 0x61));
    writeFileSync(join(fixture.hostRoot, "binary.dat"), Buffer.from([0xff, 0xfe, 0xfd, 0xfc]));
    writeFileSync(join(fixture.hostRoot, "nul.dat"), Buffer.alloc(16, 0));
    writeFileSync(join(fixture.hostRoot, "utf8.dat"), "hello");

    const sessionRes = await currentFile(
      fixture,
      "GET",
      `/files/current?${query({ origin: "session", sessionId: "host-session", path: "README.md" })}`,
    );
    expect(sessionRes.statusCode).toBe(200);
    expect(sessionRes.headers.ETag).toBeUndefined();

    const hostRes = await currentFile(
      fixture,
      "GET",
      `/files/current?${query({ origin: "host", path: join(fixture.outside, "secret.txt") })}`,
    );
    expect(hostRes.statusCode).toBe(200);
    expect(hostRes.headers.ETag).toBeUndefined();

    const big = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "big.md"))}`,
    );
    expect(big.statusCode).toBe(200);
    expect(big.headers.ETag).toBeUndefined();

    const binary = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "binary.dat"))}`,
    );
    expect(binary.statusCode).toBe(200);
    expect(binary.headers.ETag).toBeUndefined();

    const nul = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "nul.dat"))}`,
    );
    expect(nul.statusCode).toBe(200);
    expect(nul.headers.ETag).toBeUndefined();

    const utf8Dat = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "utf8.dat"))}`,
    );
    expect(utf8Dat.statusCode).toBe(200);
    expect(utf8Dat.body.toString("utf8")).toBe("hello");
    expect(utf8Dat.headers.ETag).toBeUndefined();

    const alias = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "alias.md"))}`,
    );
    expect(alias.statusCode).toBe(200);
    expect(alias.body.toString("utf8")).toBe("host workspace\n");
    expect(alias.headers.ETag).toBeUndefined();

    const outside = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, join(fixture.outside, "secret.txt")))}`,
    );
    expect(outside.statusCode).toBe(200);
    expect(outside.body.toString("utf8")).toBe("host-secret");
    expect(outside.headers.ETag).toBeUndefined();

    const dotted = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "sub/../README.md"))}`,
    );
    expect(dotted.statusCode).toBe(200);
    expect(dotted.headers.ETag).toBeUndefined();
  });

  it("advertises ETag for a sandbox guest path that stays in the selected root", async () => {
    const fixture = seed();
    const bytes = Buffer.from("sandbox bytes\n");
    const res = await currentFile(
      fixture,
      "GET",
      `/files/current?${query({
        origin: "workspace",
        workspaceId: "ws-sandbox",
        path: "/workspace/deep-research/reports/out.txt",
      })}`,
    );
    expect(res.statusCode).toBe(200);
    expect(res.body.equals(bytes)).toBe(true);
    expect(res.headers.ETag).toBe(etagFor(bytes));
    expect(res.headers["X-Oppi-Resolved-Path"]).toBeUndefined();
  });
});

describe("PUT /files/current?origin=workspace", () => {
  it("writes exact bytes, preserves mode, and returns a matching ETag", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "pretty.json");
    chmodSync(target, 0o640);
    const originalMode = statSync(target).mode & 0o777;
    const payload = Buffer.concat([
      Buffer.from([0xef, 0xbb, 0xbf]),
      Buffer.from('{\r\n  "a": 1\r\n}'),
    ]);
    const current = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "pretty.json"))}`,
    );
    const lines: string[] = [];
    const logger = createLogger({
      level: "info",
      sink: (_level, line) => lines.push(line),
    });

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "pretty.json"),
      payload,
      { "if-match": current.headers.ETag },
      logger,
    );
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as { etag: string; size: number; mtimeMs: number };
    expect(body.size).toBe(payload.length);
    expect(body.etag).toBe(etagFor(payload));
    expect(body.mtimeMs).toBeTypeOf("number");
    expect(readFileSync(target).equals(payload)).toBe(true);
    expect(statSync(target).mode & 0o777).toBe(originalMode);
    expect(editTemps(fixture.hostRoot)).toEqual([]);

    const readBack = await currentFile(
      fixture,
      "GET",
      `/files/current?${query(workspaceQuery(fixture, "pretty.json"))}`,
    );
    expect(readBack.body.equals(payload)).toBe(true);
    expect(readBack.headers.ETag).toBe(body.etag);
    expect(lines.join("\n")).not.toContain(payload.toString("utf8"));
  });

  it("writes a selected worktree file and does not fall back to main", async () => {
    const fixture = seed();
    execSync(
      "git init -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
      {
        cwd: fixture.hostRoot,
        stdio: "ignore",
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
      },
    );
    const worktree = createWorkspaceWorktree(
      fixture.workspaces[0],
      { branch: "feature/put" },
      { dataDir: fixture.dataDir },
    );
    const originalMain = readFileSync(join(fixture.hostRoot, "README.md"));
    const worktreeFile = join(worktree.path, "README.md");
    writeFileSync(worktreeFile, "worktree start\n");
    const tag = etagFor(readFileSync(worktreeFile));
    const payload = Buffer.from("worktree saved\n");

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md", { worktreeId: worktree.id }),
      payload,
      { "if-match": tag },
    );
    expect(res.statusCode).toBe(200);
    expect(readFileSync(worktreeFile).equals(payload)).toBe(true);
    expect(readFileSync(join(fixture.hostRoot, "README.md")).equals(originalMain)).toBe(true);
  });

  it("returns 428 without If-Match, refuses *, and leaves disk untouched on 412", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const original = readFileSync(target);
    const originalHash = createHash("sha256").update(original).digest("hex");

    const missing = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from("x"),
    );
    expect(missing.statusCode).toBe(428);

    const star = await putCurrent(fixture, workspaceQuery(fixture, "README.md"), Buffer.from("x"), {
      "if-match": "*",
    });
    expect(star.statusCode).toBe(412);

    const stale = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from("x"),
      { "if-match": `"sha256-${"0".repeat(64)}"` },
    );
    expect(stale.statusCode).toBe(412);
    expect(readFileSync(target).equals(original)).toBe(true);
    expect(createHash("sha256").update(readFileSync(target)).digest("hex")).toBe(originalHash);
    expect(editTemps(fixture.hostRoot)).toEqual([]);
  });

  it("rejects oversize UTF-8, invalid UTF-8, NUL, missing files, binaries, and unknown worktrees", async () => {
    const fixture = seed();
    execSync(
      "git init -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
      {
        cwd: fixture.hostRoot,
        stdio: "ignore",
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
      },
    );
    writeFileSync(join(fixture.hostRoot, "utf8.dat"), "hello");
    const tag = etagFor(readFileSync(join(fixture.hostRoot, "README.md")));
    const original = readFileSync(join(fixture.hostRoot, "README.md"));

    const invalid = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from([0xff, 0xfe]),
      { "if-match": tag },
    );
    expect(invalid.statusCode).toBe(415);

    const nul = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from("ok\0no"),
      { "if-match": tag },
    );
    expect(nul.statusCode).toBe(415);
    expect(readFileSync(join(fixture.hostRoot, "README.md")).equals(original)).toBe(true);

    const missing = await putCurrent(
      fixture,
      workspaceQuery(fixture, "absent.md"),
      Buffer.from("nope"),
      { "if-match": tag },
    );
    expect(missing.statusCode).toBe(404);
    expect(readdirSync(fixture.hostRoot)).not.toContain("absent.md");

    const binary = await putCurrent(
      fixture,
      workspaceQuery(fixture, "utf8.dat"),
      Buffer.from("hello"),
      { "if-match": etagFor(Buffer.from("hello")) },
    );
    expect(binary.statusCode).toBe(404);
    expect(readFileSync(join(fixture.hostRoot, "utf8.dat")).toString("utf8")).toBe("hello");

    const unknown = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md", { worktreeId: "gone" }),
      Buffer.from("nope"),
      { "if-match": tag },
    );
    expect(unknown.statusCode).toBe(404);
    expect(readFileSync(join(fixture.hostRoot, "README.md")).equals(original)).toBe(true);
  });

  it("writes HTTP 413 on the response for an oversize body without relying on a mock", async () => {
    const fixture = seed();
    const tag = etagFor(readFileSync(join(fixture.hostRoot, "README.md")));
    const dispatch = createHostFileRoutes(context(fixture), createRouteHelpers(), {
      homeDir: fixture.home,
    });
    const server = createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      void dispatch({
        method: req.method ?? "PUT",
        path: url.pathname,
        url,
        req,
        res,
      });
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const { port } = server.address() as AddressInfo;
    const payload = Buffer.alloc(MAX_BYTES + 1, 0x61);

    try {
      const result = await new Promise<{ status: number; body: string }>((resolve, reject) => {
        const req = httpRequest(
          {
            port,
            host: "127.0.0.1",
            method: "PUT",
            path: `/files/current?${query(workspaceQuery(fixture, "README.md"))}`,
            headers: {
              "content-length": String(payload.length),
              "if-match": tag,
            },
          },
          (res) => {
            const chunks: Buffer[] = [];
            res.on("data", (chunk: Buffer) => chunks.push(chunk));
            res.on("end", () =>
              resolve({
                status: res.statusCode ?? 0,
                body: Buffer.concat(chunks).toString("utf8"),
              }),
            );
          },
        );
        req.on("error", reject);
        req.end(payload);
      });
      expect(result.status).toBe(413);
      expect(JSON.parse(result.body)).toEqual({ error: "File too large (max 1MB)" });
      expect(readFileSync(join(fixture.hostRoot, "README.md")).toString("utf8")).toBe(
        "host workspace\n",
      );
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });

  it("refuses .., absolute paths, final-component symlinks, and sandbox escape", async () => {
    const fixture = seed();
    const tag = `"sha256-${"0".repeat(64)}"`;
    const original = readFileSync(join(fixture.hostRoot, "README.md"));

    const dotted = await putCurrent(
      fixture,
      workspaceQuery(fixture, "sub/../README.md"),
      Buffer.from("x"),
      { "if-match": tag },
    );
    expect(dotted.statusCode).toBe(404);

    const absolute = await putCurrent(
      fixture,
      workspaceQuery(fixture, join(fixture.hostRoot, "README.md")),
      Buffer.from("x"),
      { "if-match": tag },
    );
    expect(absolute.statusCode).toBe(404);

    const alias = await putCurrent(fixture, workspaceQuery(fixture, "alias.md"), Buffer.from("x"), {
      "if-match": tag,
    });
    expect(alias.statusCode).toBe(404);
    expect(readFileSync(join(fixture.hostRoot, "README.md")).equals(original)).toBe(true);

    const escaped = await putCurrent(
      fixture,
      { origin: "workspace", workspaceId: "ws-sandbox", path: "escape.txt" },
      Buffer.from("x"),
      { "if-match": tag },
    );
    expect(escaped.statusCode).toBe(403);
    expect(readFileSync(join(fixture.outside, "secret.txt")).toString("utf8")).toBe("host-secret");
  });

  it("rejects PUT for host and session origins and does not handle legacy raw PUT", async () => {
    const fixture = seed();
    const tag = etagFor(readFileSync(join(fixture.hostRoot, "README.md")));
    const original = readFileSync(join(fixture.hostRoot, "README.md"));

    const hostPut = await putCurrent(
      fixture,
      { origin: "host", path: join(fixture.hostRoot, "README.md") },
      Buffer.from("nope"),
      { "if-match": tag },
    );
    expect(hostPut.statusCode).toBe(404);

    const sessionPut = await putCurrent(
      fixture,
      { origin: "session", sessionId: "host-session", path: "README.md" },
      Buffer.from("nope"),
      { "if-match": tag },
    );
    expect(sessionPut.statusCode).toBe(404);
    expect(readFileSync(join(fixture.hostRoot, "README.md")).equals(original)).toBe(true);

    const rawDispatch = createWorkspaceFileRoutes(context(fixture), createRouteHelpers());
    const rawRes = makeResponse();
    const rawHandled = await rawDispatch({
      method: "PUT",
      path: "/workspaces/ws-host/raw/README.md",
      url: new URL("https://localhost/workspaces/ws-host/raw/README.md"),
      req: makeRawRequest(Buffer.from("nope")),
      res: rawRes as unknown as ServerResponse,
    });
    expect(rawHandled).toBe(false);
    expect(rawRes.statusCode).toBe(0);
  });

  it("serializes concurrent PUTs with the same tag to one 200 and one 412", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const tag = etagFor(readFileSync(target));
    const first = Buffer.from("first-writer\n");
    const second = Buffer.from("second-writer\n");

    const [a, b] = await Promise.all([
      putCurrent(fixture, workspaceQuery(fixture, "README.md"), first, { "if-match": tag }),
      putCurrent(fixture, workspaceQuery(fixture, "README.md"), second, { "if-match": tag }),
    ]);
    const statuses = [a.statusCode, b.statusCode].sort();
    expect(statuses).toEqual([200, 412]);
    const disk = readFileSync(target);
    const winner = a.statusCode === 200 ? first : second;
    expect(disk.equals(winner)).toBe(true);
    expect(editTemps(fixture.hostRoot)).toEqual([]);
  });

  it("serializes alias spellings of the same canonical file", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "sub", "nested.md");
    const tag = etagFor(readFileSync(target));
    const first = Buffer.from("alias-one\n");
    const second = Buffer.from("alias-two\n");

    const [a, b] = await Promise.all([
      putCurrent(fixture, workspaceQuery(fixture, "sub/nested.md"), first, { "if-match": tag }),
      putCurrent(fixture, workspaceQuery(fixture, "sub//nested.md"), second, { "if-match": tag }),
    ]);
    const statuses = [a.statusCode, b.statusCode].sort();
    expect(statuses).toEqual([200, 412]);
    const disk = readFileSync(target);
    expect(disk.equals(first) || disk.equals(second)).toBe(true);
    expect(editTemps(join(fixture.hostRoot, "sub"))).toEqual([]);
  });

  it("does not rename when the target changes during temp preparation", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const original = readFileSync(target);
    const tag = etagFor(original);
    let injected = false;
    wrapTempHandleChmod(() => {
      injected = true;
      writeFileSync(target, "external-writer\n");
    });

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from("editor\n"),
      { "if-match": tag },
    );
    expect(injected).toBe(true);
    expect(res.statusCode).toBe(412);
    expect(readFileSync(target).toString("utf8")).toBe("external-writer\n");
    expect(editTemps(fixture.hostRoot)).toEqual([]);
  });

  it("does not write through a parent-directory swap outside the selected root", async () => {
    const fixture = seed();
    const sub = join(fixture.hostRoot, "sub");
    const target = join(sub, "nested.md");
    const original = readFileSync(target);
    const tag = etagFor(original);
    const actual = fsControl.actual;
    if (!actual) throw new Error("fs mock not initialized");
    let swapped = false;
    fsControl.open.mockImplementation(async (...args: Parameters<typeof actual.open>) => {
      const flags = args[1];
      if (!swapped && typeof flags === "number" && flags & fsConstants.O_CREAT) {
        swapped = true;
        const relocated = `${sub}-was`;
        renameSync(sub, relocated);
        symlinkSync(fixture.outside, sub);
      }
      return actual.open(...args);
    });

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "sub/nested.md"),
      Buffer.from("escaped\n"),
      { "if-match": tag },
    );
    expect([403, 404]).toContain(res.statusCode);
    expect(readFileSync(join(fixture.outside, "secret.txt")).toString("utf8")).toBe("host-secret");
    expect(readdirSync(fixture.outside).some((name) => name.startsWith(".oppi-edit-"))).toBe(false);
    const relocated = readFileSync(join(`${sub}-was`, "nested.md"));
    expect(relocated.equals(original) || relocated.toString("utf8") === "escaped\n").toBe(true);
    if (relocated.toString("utf8") === "escaped\n") {
      throw new Error("parent swap redirected the editor write");
    }
  });

  it("cleans the same-directory temp file after an injected rename failure", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const original = readFileSync(target);
    const tag = etagFor(original);
    fsControl.rename.mockRejectedValueOnce(Object.assign(new Error("injected"), { code: "EIO" }));

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      Buffer.from("new\n"),
      { "if-match": tag },
    );
    expect(res.statusCode).toBe(500);
    expect(readFileSync(target).equals(original)).toBe(true);
    expect(editTemps(fixture.hostRoot)).toEqual([]);
  });

  it("does not follow a substituted temp symlink on cleanup", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const original = readFileSync(target);
    const outside = join(fixture.outside, "secret.txt");
    const outsideBytes = readFileSync(outside);
    const outsideMode = statSync(outside).mode & 0o777;
    const payload = Buffer.from("editor-bytes\n");
    let injected = false;
    wrapTempHandleChmod(() => {
      const tempPath = onlyEditTemp(fixture.hostRoot);
      unlinkSync(tempPath);
      symlinkSync(outside, tempPath);
      injected = true;
    });

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      payload,
      { "if-match": etagFor(original) },
    );
    expect(injected).toBe(true);
    expect(res.statusCode).toBe(500);
    expect(readFileSync(target).equals(original)).toBe(true);
    expect(readFileSync(outside).equals(outsideBytes)).toBe(true);
    expect(statSync(outside).mode & 0o777).toBe(outsideMode);
    expect(statSync(outside).isFile()).toBe(true);
    const leftover = editTemps(fixture.hostRoot);
    expect(leftover).toHaveLength(1);
    expect(lstatSync(join(fixture.hostRoot, leftover[0])).isSymbolicLink()).toBe(true);
  });

  it("does not rename a substituted regular file onto the target", async () => {
    const fixture = seed();
    const target = join(fixture.hostRoot, "README.md");
    const original = readFileSync(target);
    const payload = Buffer.from("editor-bytes\n");
    const substitute = Buffer.from("substituted-regular\n");
    let injected = false;
    wrapTempHandleChmod(() => {
      const tempPath = onlyEditTemp(fixture.hostRoot);
      unlinkSync(tempPath);
      writeFileSync(tempPath, substitute);
      injected = true;
    });

    const res = await putCurrent(
      fixture,
      workspaceQuery(fixture, "README.md"),
      payload,
      { "if-match": etagFor(original) },
    );
    expect(injected).toBe(true);
    expect(res.statusCode).toBe(500);
    const disk = readFileSync(target);
    expect(disk.equals(substitute)).toBe(false);
    expect(disk.equals(original)).toBe(true);
    const leftover = editTemps(fixture.hostRoot);
    expect(leftover).toHaveLength(1);
    expect(readFileSync(join(fixture.hostRoot, leftover[0])).equals(substitute)).toBe(true);
  });
});
