import { execSync } from "node:child_process";
import { once } from "node:events";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import type { FileHandle } from "node:fs/promises";
import {
  createServer,
  request as httpRequest,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import { afterEach, describe, expect, it, vi } from "vitest";

// Record every handle `sendFileBytes` opens so a test can prove it was closed
// (a closed FileHandle reports fd -1). Opens pass through unchanged.
const openedHandles = vi.hoisted(() => [] as { path: string; handle: FileHandle }[]);
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (...args: Parameters<typeof actual.open>) => {
      const handle = await actual.open(...args);
      openedHandles.push({ path: String(args[0]), handle });
      return handle;
    },
  };
});

import { sendFileBytes, statServableFile } from "../src/current-file.js";
import { listDirectoryEntries } from "../src/directory-listing.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";

class MockWritableResponse extends PassThrough {
  statusCode = 0;
  headers: Record<string, string> = {};
  body = Buffer.alloc(0);

  constructor() {
    super();
    this.on("data", (chunk: Buffer) => {
      this.body = Buffer.concat([this.body, chunk]);
    });
  }

  writeHead(statusCode: number, headers: Record<string, string | number> = {}): this {
    this.statusCode = statusCode;
    this.headers = Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [key, String(value)]),
    );
    return this;
  }

  text(): string {
    return this.body.toString("utf8");
  }
}

interface Fixture {
  dataDir: string;
  home: string;
  workspaces: Workspace[];
  sessions: Session[];
}

const roots: string[] = [];

function tempRoot(prefix: string): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  roots.push(root);
  return root;
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

async function request(
  fixture: Fixture,
  method: string,
  pathAndQuery: string,
  headers: Record<string, string> = {},
): Promise<MockWritableResponse> {
  const dispatch = createHostFileRoutes(
    {
      storage: {
        getDataDir: () => fixture.dataDir,
        getWorkspace: (id: string) => fixture.workspaces.find((workspace) => workspace.id === id),
        getSession: (id: string) => fixture.sessions.find((session) => session.id === id),
      },
    } as unknown as RouteContext,
    createRouteHelpers(),
    { homeDir: fixture.home },
  );
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

function query(params: Record<string, string>): string {
  return new URLSearchParams(params).toString();
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

function seed(): Fixture & { hostRoot: string; sandboxMount: string; outside: string } {
  const dataDir = tempRoot("oppi-current-data-");
  const home = tempRoot("oppi-current-home-");
  const hostRoot = tempRoot("oppi-current-host-ws-");
  const sandboxMount = tempRoot("oppi-current-sandbox-");
  const outside = tempRoot("oppi-current-outside-");

  writeFileSync(join(home, "notes.md"), "home notes\n");
  writeFileSync(join(hostRoot, "README.md"), "host workspace\n");
  mkdirSync(join(sandboxMount, "reports"));
  writeFileSync(join(sandboxMount, "reports", "out.txt"), "sandbox bytes\n");
  writeFileSync(join(outside, "secret.txt"), "host-secret");
  symlinkSync(join(outside, "secret.txt"), join(sandboxMount, "escape.txt"));
  symlinkSync(outside, join(sandboxMount, "escape-dir"));
  mkdirSync(join(dataDir, "control-sessions", "cwd"), { recursive: true, mode: 0o700 });
  writeFileSync(join(dataDir, "control-sessions", "cwd", "plan.md"), "control plan\n");

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
    session({ id: "control-1", control: { domain: "skills", intent: "create" } }),
    session({ id: "host-session", workspaceId: "ws-host" }),
    session({ id: "sandbox-session", workspaceId: "ws-sandbox" }),
  ];
  return { dataDir, home, hostRoot, sandboxMount, outside, workspaces, sessions };
}

describe("GET/HEAD /files/current", () => {
  it("reads host paths outside any workspace and ~/ with the canonical path header", async () => {
    const fixture = seed();

    const absolute = await request(
      fixture,
      "GET",
      `/files/current?${query({ origin: "host", path: join(fixture.outside, "secret.txt") })}`,
    );
    expect(absolute.statusCode).toBe(200);
    expect(absolute.text()).toBe("host-secret");
    expect(absolute.headers["X-Oppi-Resolved-Path"]).toBe(join(fixture.outside, "secret.txt"));

    const tilde = await request(
      fixture,
      "HEAD",
      `/files/current?${query({ origin: "host", path: "~/notes.md" })}`,
    );
    expect(tilde.statusCode).toBe(200);
    expect(tilde.headers["Content-Length"]).toBe("11");
    expect(tilde.headers["X-Oppi-Resolved-Path"]).toBe(join(fixture.home, "notes.md"));

    // Host origin has no relative namespace.
    const relative = await request(
      fixture,
      "HEAD",
      `/files/current?${query({ origin: "host", path: "notes.md" })}`,
    );
    expect(relative.statusCode).toBe(404);
  });

  it("fails closed for missing, unknown, duplicate, and conflicting origin parameters", async () => {
    const fixture = seed();
    const file = join(fixture.outside, "secret.txt");
    for (const [search, message] of [
      [query({ path: file }), "Invalid origin"],
      [query({ origin: "owner", path: file }), "Invalid origin"],
      [query({ origin: "host" }), "path parameter required"],
      [
        query({ origin: "host", path: file, workspaceId: "ws-host" }),
        "Conflicting origin parameters",
      ],
      [query({ origin: "workspace", path: "README.md" }), "Conflicting origin parameters"],
      [
        query({
          origin: "workspace",
          workspaceId: "ws-host",
          sessionId: "host-session",
          path: "x",
        }),
        "Conflicting origin parameters",
      ],
      [
        query({ origin: "session", sessionId: "host-session", worktreeId: "main", path: "x" }),
        "Conflicting origin parameters",
      ],
      [
        query({ origin: "host", path: file, controlSessionId: "control-1" }),
        "Invalid query parameter: controlSessionId",
      ],
      [
        `origin=host&path=${encodeURIComponent(file)}&path=%2Fetc%2Fhosts`,
        "Invalid query parameter: path",
      ],
    ] as const) {
      const res = await request(fixture, "GET", `/files/current?${search}`);
      expect({ search, status: res.statusCode, body: JSON.parse(res.text()) }).toEqual({
        search,
        status: 400,
        body: { error: message },
      });
    }
  });

  it("resolves workspace, worktree, and host-workspace absolute paths without a secrecy check", async () => {
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
      { branch: "feature/current" },
      { dataDir: fixture.dataDir },
    );
    writeFileSync(join(worktree.path, "README.md"), "worktree bytes\n");

    const main = await request(
      fixture,
      "GET",
      `/files/current?${query({ origin: "workspace", workspaceId: "ws-host", path: "README.md" })}`,
    );
    expect(main.text()).toBe("host workspace\n");

    const branch = await request(
      fixture,
      "GET",
      `/files/current?${query({
        origin: "workspace",
        workspaceId: "ws-host",
        worktreeId: worktree.id,
        path: "README.md",
      })}`,
    );
    expect(branch.text()).toBe("worktree bytes\n");

    const outsideHost = await request(
      fixture,
      "GET",
      `/files/current?${query({
        origin: "workspace",
        workspaceId: "ws-host",
        path: join(fixture.outside, "secret.txt"),
      })}`,
    );
    expect(outsideHost.statusCode).toBe(200);
    expect(outsideHost.text()).toBe("host-secret");

    const missingWorktree = await request(
      fixture,
      "HEAD",
      `/files/current?${query({
        origin: "workspace",
        workspaceId: "ws-host",
        worktreeId: "gone",
        path: "README.md",
      })}`,
    );
    expect(missingWorktree.statusCode).toBe(404);
  });

  it("keeps sandbox workspace and session reads inside the mount after realpath", async () => {
    const fixture = seed();

    for (const origin of [
      { origin: "workspace", workspaceId: "ws-sandbox" },
      { origin: "session", sessionId: "sandbox-session" },
    ]) {
      const guest = await request(
        fixture,
        "GET",
        `/files/current?${query({ ...origin, path: "/workspace/deep-research/reports/out.txt" })}`,
      );
      expect(guest.statusCode).toBe(200);
      expect(guest.text()).toBe("sandbox bytes\n");
      // Sandbox files never disclose their host realpath.
      expect(guest.headers["X-Oppi-Resolved-Path"]).toBeUndefined();

      for (const path of [
        "escape.txt",
        "escape-dir/secret.txt",
        "/workspace/deep-research/escape.txt",
        join(fixture.outside, "secret.txt"),
        "../",
      ]) {
        const escaped = await request(
          fixture,
          "GET",
          `/files/current?${query({ ...origin, path })}`,
        );
        expect({ origin, path, status: escaped.statusCode }).toEqual({ origin, path, status: 403 });
        expect(escaped.text()).not.toContain("host-secret");
      }
    }
  });

  it("resolves session-relative paths from the session's actual cwd", async () => {
    const fixture = seed();

    const control = await request(
      fixture,
      "GET",
      `/files/current?${query({ origin: "session", sessionId: "control-1", path: "plan.md" })}`,
    );
    expect(control.statusCode).toBe(200);
    expect(control.text()).toBe("control plan\n");
    expect(control.headers["X-Oppi-Resolved-Path"]).toBe(
      join(fixture.dataDir, "control-sessions", "cwd", "plan.md"),
    );

    const hostSession = await request(
      fixture,
      "GET",
      `/files/current?${query({ origin: "session", sessionId: "host-session", path: "README.md" })}`,
    );
    expect(hostSession.text()).toBe("host workspace\n");

    const unknown = await request(
      fixture,
      "HEAD",
      `/files/current?${query({ origin: "session", sessionId: "nope", path: "plan.md" })}`,
    );
    expect(unknown.statusCode).toBe(404);
  });

  it("serves single byte ranges and rejects unsatisfiable ranges", async () => {
    const fixture = seed();
    const clip = join(fixture.outside, "clip.mp4");
    writeFileSync(clip, "0123456789");
    const search = `/files/current?${query({ origin: "host", path: clip })}`;

    const partial = await request(fixture, "GET", search, { range: "bytes=2-5" });
    expect(partial.statusCode).toBe(206);
    expect(partial.headers["Content-Range"]).toBe("bytes 2-5/10");
    expect(partial.headers["Content-Type"]).toBe("video/mp4");
    expect(partial.text()).toBe("2345");

    const unsatisfiable = await request(fixture, "GET", search, { range: "bytes=20-" });
    expect(unsatisfiable.statusCode).toBe(416);
    expect(unsatisfiable.headers["Content-Range"]).toBe("bytes */10");
  });
});

describe("GET /files/current/sidecars", () => {
  it("returns only same-stem timed-text regular files beside a host video", async () => {
    const fixture = seed();
    const movies = join(fixture.home, "Movies");
    mkdirSync(movies);
    for (const name of [
      "clip.mp4",
      "clip.srt",
      "clip.en.srt",
      "clip.zh-Hans.vtt",
      "CLIP.fr.ass",
      "clip.txt",
      "clip2.srt",
      "other.srt",
      "notes.md",
    ]) {
      writeFileSync(join(movies, name), "1\n00:00:00,000 --> 00:00:01,000\nHi\n");
    }
    mkdirSync(join(movies, "clip.de.srt"));

    const res = await request(
      fixture,
      "GET",
      `/files/current/sidecars?${query({ origin: "host", path: "~/Movies/clip.mp4" })}`,
    );
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.text())).toEqual({
      names: ["CLIP.fr.ass", "clip.en.srt", "clip.srt", "clip.zh-Hans.vtt"],
      truncated: false,
    });

    const missing = await request(
      fixture,
      "GET",
      `/files/current/sidecars?${query({ origin: "host", path: "~/Movies/absent.mp4" })}`,
    );
    expect(missing.statusCode).toBe(404);
  });

  it("omits sandbox sidecars that escape the mount", async () => {
    const fixture = seed();
    writeFileSync(join(fixture.sandboxMount, "reports", "clip.mp4"), "video");
    writeFileSync(join(fixture.sandboxMount, "reports", "clip.srt"), "srt");
    symlinkSync(
      join(fixture.outside, "secret.txt"),
      join(fixture.sandboxMount, "reports", "clip.en.srt"),
    );

    const res = await request(
      fixture,
      "GET",
      `/files/current/sidecars?${query({
        origin: "session",
        sessionId: "sandbox-session",
        path: "/workspace/deep-research/reports/clip.mp4",
      })}`,
    );
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.text())).toEqual({ names: ["clip.srt"], truncated: false });
  });
});

describe("checked path swapped before the bytes are served", () => {
  it("refuses a final-component or intermediate-directory symlink swap", async () => {
    const mount = tempRoot("oppi-swap-mount-");
    const outside = tempRoot("oppi-swap-outside-");
    writeFileSync(join(outside, "out.txt"), "host-secret");
    const checkedPath = join(mount, "dir", "out.txt");

    for (const swap of [
      () => {
        rmSync(checkedPath);
        symlinkSync(join(outside, "out.txt"), checkedPath);
      },
      () => {
        renameSync(join(mount, "dir"), join(mount, "dir-was"));
        symlinkSync(outside, join(mount, "dir"));
      },
    ]) {
      rmSync(join(mount, "dir"), { recursive: true, force: true });
      rmSync(join(mount, "dir-was"), { recursive: true, force: true });
      mkdirSync(join(mount, "dir"));
      writeFileSync(checkedPath, "in-mount");
      const checked = await statServableFile(checkedPath);
      if (checked.kind !== "ok") throw new Error(`fixture not servable: ${checked.kind}`);

      swap();
      const res = new MockWritableResponse();
      const finished = once(res, "finish");
      const status = await sendFileBytes(
        undefined,
        res as unknown as ServerResponse,
        "GET",
        checked.file,
        { rangeLogTag: "test" },
      );
      if (!res.writableEnded) await finished;
      expect(status).toBe(404);
      expect(res.statusCode).toBe(404);
      expect(res.text()).not.toContain("host-secret");
    }
  });

  it("closes the file handle when a client aborts a Range GET mid-transfer", async () => {
    const root = tempRoot("oppi-range-abort-");
    const clip = join(root, "clip.mp4");
    // Far larger than socket and stream buffers, so the abort lands mid-transfer.
    writeFileSync(clip, Buffer.alloc(8 * 1024 * 1024, 7));
    const checked = await statServableFile(clip);
    if (checked.kind !== "ok") throw new Error(`fixture not servable: ${checked.kind}`);

    const served: { sending: Promise<number>; closed: Promise<unknown> }[] = [];
    const server = createServer((req, res) => {
      served.push({
        closed: once(res, "close"),
        sending: sendFileBytes(req, res, req.method ?? "GET", checked.file, {
          rangeLogTag: "test",
        }),
      });
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const { port } = server.address() as AddressInfo;

    const get = (range: string, abortOnFirstChunk: boolean) =>
      new Promise<{ status: number; bytes: number }>((resolveGet, rejectGet) => {
        const req = httpRequest({ port, host: "127.0.0.1", headers: { range } }, (res) => {
          let bytes = 0;
          res.on("data", (chunk: Buffer) => {
            bytes += chunk.length;
            if (abortOnFirstChunk) {
              req.destroy();
              resolveGet({ status: res.statusCode ?? 0, bytes });
            }
          });
          res.on("end", () => resolveGet({ status: res.statusCode ?? 0, bytes }));
        });
        req.on("error", (error) => {
          if (!abortOnFirstChunk) rejectGet(error);
        });
        req.end();
      });

    try {
      const aborted = await get("bytes=1024-", true);
      expect(aborted.status).toBe(206);
      expect(aborted.bytes).toBeGreaterThan(0);
      await served[0].closed;
      expect(await served[0].sending).toBe(206);
      const abortedHandles = openedHandles.filter((entry) => entry.path === clip);
      expect(abortedHandles).toHaveLength(1);
      expect(abortedHandles[0].handle.fd).toBe(-1);

      const next = await get("bytes=0-99", false);
      expect(next).toEqual({ status: 206, bytes: 100 });
      expect(await served[1].sending).toBe(206);
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });

  it("omits escaping child symlinks from a confined listing", async () => {
    const mount = tempRoot("oppi-list-mount-");
    const outside = tempRoot("oppi-list-outside-");
    writeFileSync(join(outside, "big.bin"), "x".repeat(4096));
    writeFileSync(join(mount, "kept.txt"), "k");
    symlinkSync("kept.txt", join(mount, "kept-alias.txt"));
    symlinkSync(join(outside, "big.bin"), join(mount, "escape.bin"));

    const confined = await listDirectoryEntries(mount, ".", { confineSymlinks: true });
    expect(confined?.entries.map((entry) => entry.name).sort()).toEqual([
      "kept-alias.txt",
      "kept.txt",
    ]);
    const host = await listDirectoryEntries(mount, ".");
    expect(host?.entries.map((entry) => entry.name).sort()).toEqual([
      "escape.bin",
      "kept-alias.txt",
      "kept.txt",
    ]);
  });
});
