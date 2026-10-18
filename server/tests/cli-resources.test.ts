import { createServer as createHttpServer, type Server } from "node:http";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { inferWorkspaceIdFromCwdForCli } from "../src/cli/resources.js";
import { Storage } from "../src/storage.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

const cleanupPaths = new Set<string>();
const servers = new Set<Server>();

afterEach(async () => {
  for (const api of servers) {
    await new Promise<void>((resolve, reject) =>
      api.close((error) => (error ? reject(error) : resolve())),
    );
  }
  servers.clear();
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
});

type FixtureWorkspace = {
  id: string;
  hostMount: string;
  runtime?: "host" | "sandbox";
  worktrees?: { id: string; path: string }[];
};

function makeDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  cleanupPaths.add(dir);
  return dir;
}

/** Local API fixture that mirrors the server: sandbox workspaces answer 409 on /worktrees. */
async function startLocalApi(workspaces: FixtureWorkspace[]): Promise<Storage> {
  const dataDir = makeDir("oppi-cli-resources-");
  const api = createHttpServer((req, res) => {
    const respond = (status: number, body: unknown): void => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.url === "/workspaces") {
      respond(200, {
        workspaces: workspaces.map(({ id, hostMount, runtime }) => ({
          id,
          name: id,
          hostMount,
          runtime,
        })),
      });
      return;
    }

    const worktreesMatch = /^\/workspaces\/([^/]+)\/worktrees$/.exec(req.url ?? "");
    const workspace = workspaces.find((candidate) => candidate.id === worktreesMatch?.[1]);
    if (!workspace) {
      respond(404, { error: "Not found" });
      return;
    }
    if (workspace.runtime === "sandbox") {
      respond(409, { error: "Worktrees are not available for sandbox workspaces" });
      return;
    }
    respond(200, {
      workspaceId: workspace.id,
      worktrees: [
        { id: "main", path: workspace.hostMount },
        ...(workspace.worktrees ?? []).map(({ id, path }) => ({ id, path })),
      ],
    });
  });
  servers.add(api);
  await listenOnLocalApiFixture(api, dataDir);

  const storage = new Storage(dataDir);
  storage.rotateToken();
  storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });
  return storage;
}

describe("CLI workspace inference", () => {
  it("matches cwd inside a workspace worktree path", async () => {
    const workspaceRoot = makeDir("oppi-cli-workspace-root-");
    const worktreeRoot = makeDir("oppi-cli-worktree-root-");
    const nestedWorktreeDir = join(worktreeRoot, "src");
    mkdirSync(nestedWorktreeDir, { recursive: true });

    const storage = await startLocalApi([
      {
        id: "ws-1",
        hostMount: workspaceRoot,
        worktrees: [{ id: "wt-review", path: worktreeRoot }],
      },
    ]);

    await expect(inferWorkspaceIdFromCwdForCli(storage, nestedWorktreeDir)).resolves.toBe("ws-1");
  });

  describe("with a sandbox workspace, whose worktree list the server refuses with 409", () => {
    async function startWithSandboxAndHost(): Promise<{
      storage: Storage;
      hostRoot: string;
      hostWorktreeRoot: string;
    }> {
      const sandboxRoot = makeDir("oppi-cli-sandbox-root-");
      const hostRoot = makeDir("oppi-cli-host-root-");
      const hostWorktreeRoot = makeDir("oppi-cli-host-worktree-");
      mkdirSync(join(hostRoot, "src"), { recursive: true });
      mkdirSync(join(hostWorktreeRoot, "src"), { recursive: true });
      const storage = await startLocalApi([
        { id: "ws-sandbox", hostMount: sandboxRoot, runtime: "sandbox" },
        {
          id: "ws-host",
          hostMount: hostRoot,
          runtime: "host",
          worktrees: [{ id: "wt-review", path: hostWorktreeRoot }],
        },
      ]);
      return { storage, hostRoot, hostWorktreeRoot };
    }

    it("infers the host workspace from inside its folder", async () => {
      const { storage, hostRoot } = await startWithSandboxAndHost();
      await expect(inferWorkspaceIdFromCwdForCli(storage, join(hostRoot, "src"))).resolves.toBe(
        "ws-host",
      );
    });

    it("infers the host workspace from inside one of its worktrees", async () => {
      const { storage, hostWorktreeRoot } = await startWithSandboxAndHost();
      await expect(
        inferWorkspaceIdFromCwdForCli(storage, join(hostWorktreeRoot, "src")),
      ).resolves.toBe("ws-host");
    });

    it("infers the sandbox workspace from inside its folder", async () => {
      const sandboxRoot = makeDir("oppi-cli-sandbox-root-");
      const storage = await startLocalApi([
        { id: "ws-sandbox", hostMount: sandboxRoot, runtime: "sandbox" },
      ]);
      await expect(inferWorkspaceIdFromCwdForCli(storage, sandboxRoot)).resolves.toBe(
        "ws-sandbox",
      );
    });
  });

  it("prefers a workspace folder containing cwd over another workspace's worktree", async () => {
    const outerRoot = makeDir("oppi-cli-outer-root-");
    const innerWorktree = join(outerRoot, "worktrees", "feature");
    mkdirSync(innerWorktree, { recursive: true });
    const otherRoot = makeDir("oppi-cli-other-root-");

    const storage = await startLocalApi([
      { id: "ws-other", hostMount: otherRoot, worktrees: [{ id: "wt", path: innerWorktree }] },
      { id: "ws-outer", hostMount: outerRoot },
    ]);

    await expect(inferWorkspaceIdFromCwdForCli(storage, innerWorktree)).resolves.toBe("ws-outer");
  });

  it("reports ambiguity when two workspace folders contain cwd at the same depth", async () => {
    const sharedRoot = makeDir("oppi-cli-shared-root-");
    const storage = await startLocalApi([
      { id: "ws-a", hostMount: sharedRoot },
      { id: "ws-b", hostMount: sharedRoot },
    ]);

    await expect(inferWorkspaceIdFromCwdForCli(storage, sharedRoot)).rejects.toThrow(
      "Workspace inference is ambiguous; pass --workspace or --all",
    );
  });

  it("returns undefined when no workspace folder or worktree contains cwd", async () => {
    const storage = await startLocalApi([
      { id: "ws-1", hostMount: makeDir("oppi-cli-workspace-root-") },
    ]);

    await expect(
      inferWorkspaceIdFromCwdForCli(storage, makeDir("oppi-cli-elsewhere-")),
    ).resolves.toBeUndefined();
  });
});
