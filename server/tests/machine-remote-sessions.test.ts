import { once } from "node:events";
import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { runtimeSwitched } from "../src/durable-execution-env.js";
import { placementsFor } from "../src/machines/placements.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Workspace } from "../src/types.js";

class Response extends PassThrough {
  statusCode = 0;
  body = Buffer.alloc(0);
  constructor() {
    super();
    this.on("data", (chunk: Buffer) => {
      this.body = Buffer.concat([this.body, chunk]);
    });
  }
  writeHead(statusCode: number): this {
    this.statusCode = statusCode;
    return this;
  }
}

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/** A host workspace whose checkout holds a file, and a child worktree that lives on `build-mac`. */
function remoteChildFixture(): { dataDir: string; workspace: Workspace; ctx: RouteContext } {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-remote-session-"));
  roots.push(dataDir);
  const mount = join(dataDir, "checkout");
  mkdirSync(mount);
  writeFileSync(join(mount, "secret.txt"), "this host's file\n");
  const workspace: Workspace = {
    id: "ws-1",
    name: "Workspace",
    hostMount: mount,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  placementsFor(dataDir).put({
    worktreeId: "wt_child-1",
    machine: "build-mac",
    workspaceId: "ws-1",
    repo: mount,
    branch: "subagent/child",
    base: "0".repeat(40),
    root: "/Users/alex/.oppi/pool/worktrees/ws-1/wt_child-1",
    active: true,
    fetched: false,
  });
  const ctx = {
    storage: {
      getDataDir: () => dataDir,
      getWorkspace: (id: string) => (id === "ws-1" ? workspace : undefined),
      getSession: (id: string) =>
        id === "child"
          ? { id, workspaceId: "ws-1", worktreeId: "wt_child-1", status: "ready" }
          : undefined,
    },
  } as unknown as RouteContext;
  return { dataDir, workspace, ctx };
}

async function get(
  dispatch: (request: never) => Promise<boolean>,
  rawPath: string,
): Promise<Response> {
  const res = new Response();
  const finished = once(res, "finish");
  const url = new URL(`https://localhost${rawPath}`);
  const handled = await dispatch({
    method: "GET",
    path: url.pathname,
    url,
    req: { headers: {} } as IncomingMessage,
    res: res as unknown as ServerResponse,
  } as never);
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

describe("sessions whose files are on a machine", () => {
  it("answers 409 for the session's files instead of reading this host's same-path checkout", async () => {
    const { ctx } = remoteChildFixture();
    const dispatch = createHostFileRoutes(ctx, createRouteHelpers());
    const res = await get(
      dispatch as never,
      `/files/current?origin=session&sessionId=child&path=secret.txt`,
    );
    expect(res.statusCode).toBe(409);
    expect(res.body.toString()).toContain("build-mac");
    expect(res.body.toString()).not.toContain("this host's file");
  });

  it("answers 409 for the worktree's workspace files, where an unknown worktree is 404", async () => {
    const { ctx } = remoteChildFixture();
    const dispatch = createWorkspaceFileRoutes(ctx, createRouteHelpers());
    const remote = await get(dispatch as never, "/workspaces/ws-1/contents?worktreeId=wt_child-1");
    expect(remote.statusCode).toBe(409);
    expect(remote.body.toString()).toContain("build-mac");
    const unknown = await get(dispatch as never, "/workspaces/ws-1/contents?worktreeId=wt_nope");
    expect(unknown.statusCode).toBe(404);
  });
});

describe("a conversation's runtime never switches", () => {
  it("keeps a remote conversation on its machine, and a host or sandbox one off machines", () => {
    const remote = { kind: "remote" as const, machine: "build-mac", root: "/r" };
    expect(runtimeSwitched(remote, { sandbox: false, machine: "build-mac" })).toBe(false);
    expect(runtimeSwitched(remote, { sandbox: false, machine: "other" })).toBe(true);
    expect(runtimeSwitched(remote, { sandbox: false })).toBe(true);
    expect(runtimeSwitched(remote, { sandbox: true, workspaceId: "ws-1" })).toBe(true);
    expect(runtimeSwitched({ kind: "host" }, { sandbox: false, machine: "build-mac" })).toBe(true);
    expect(runtimeSwitched({ kind: "host" }, { sandbox: false })).toBe(false);
    expect(runtimeSwitched(undefined, { sandbox: false })).toBe(false);
    expect(runtimeSwitched({ kind: "sandbox", workspaceId: "a" }, { sandbox: false })).toBe(true);
    expect(
      runtimeSwitched({ kind: "sandbox", workspaceId: "a" }, { sandbox: true, workspaceId: "b" }),
    ).toBe(true);
  });
});
