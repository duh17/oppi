import { createServer as createHttpServer } from "node:http";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { inferWorkspaceIdFromCwdForCli } from "../src/cli/resources.js";
import { Storage } from "../src/storage.js";

const cleanupPaths = new Set<string>();

afterEach(() => {
  for (const path of cleanupPaths) {
    rmSync(path, { recursive: true, force: true });
  }
  cleanupPaths.clear();
});

describe("CLI workspace inference", () => {
  it("matches cwd inside a workspace worktree path", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-resources-"));
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-cli-workspace-root-"));
    const worktreeRoot = mkdtempSync(join(tmpdir(), "oppi-cli-worktree-root-"));
    cleanupPaths.add(dataDir);
    cleanupPaths.add(workspaceRoot);
    cleanupPaths.add(worktreeRoot);

    const nestedWorktreeDir = join(worktreeRoot, "src");
    mkdirSync(nestedWorktreeDir, { recursive: true });

    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });

      if (req.url === "/workspaces") {
        res.end(
          JSON.stringify({
            workspaces: [{ id: "ws-1", name: "Oppi", hostMount: workspaceRoot }],
          }),
        );
        return;
      }

      if (req.url === "/workspaces/ws-1/worktrees") {
        res.end(
          JSON.stringify({
            workspaceId: "ws-1",
            worktrees: [
              { id: "main", name: "main", path: workspaceRoot },
              { id: "wt-review", name: "review", path: worktreeRoot },
            ],
          }),
        );
        return;
      }

      res.end(JSON.stringify({}));
    });
    await new Promise<void>((resolve) => api.listen(0, "127.0.0.1", resolve));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("Failed to start API fixture");

    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: address.port, tls: { mode: "disabled" } });

      await expect(inferWorkspaceIdFromCwdForCli(storage, nestedWorktreeDir)).resolves.toBe("ws-1");
      expect(requests).toEqual(["GET /workspaces", "GET /workspaces/ws-1/worktrees"]);
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
    }
  });
});
