import { createServer as createHttpServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { classifyOppiToolCommand, runOppiToolCommand } from "../src/default-agent-tool.js";
import { Storage } from "../src/storage.js";

describe("Default Agent Oppi tool command runner", () => {
  it("dispatches allowed read commands through the JSON CLI modules", async () => {
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          workspaces: [{ id: "ws-1", name: "Oppi" }],
        }),
      );
    });
    await new Promise<void>((resolve) => api.listen(0, "127.0.0.1", resolve));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("Failed to start API fixture");

    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-"));
    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: address.port, tls: { mode: "disabled" } });

      const result = await runOppiToolCommand({ dataDir, args: ["workspace", "list"] });

      expect(result.ok).toBe(true);
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        data: { workspaces: [{ id: "ws-1", name: "Oppi" }] },
      });
      expect(requests).toEqual(["GET /workspaces"]);
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe("Default Agent Oppi tool command policy", () => {
  it("allows read-only app inspection commands", () => {
    for (const args of [
      ["status"],
      ["workspace", "list"],
      ["workspace", "get", "oppi"],
      ["worktree", "list", "--workspace", "oppi"],
      ["worktree", "status", "wt_feature", "--workspace", "oppi"],
      ["worktree", "preview", "wt_feature", "--workspace", "oppi", "--into", "main"],
      ["agent", "get", "default"],
      ["session", "read", "sess-1", "--tail", "10"],
      ["schedule", "runs", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "read",
      });
    }
  });

  it("requires approval for creating sessions and managing worktrees", () => {
    for (const args of [
      ["session", "create", "--workspace", "oppi", "--prompt", "Review this"],
      ["worktree", "create", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "open", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "remove", "wt_feature-review-12345678", "--workspace", "oppi"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "approved-write",
      });
    }
  });

  it("blocks mutating app commands that are not part of the first Default Agent slice", () => {
    for (const args of [
      ["agent", "archive", "default"],
      ["schedule", "create", "--workspace", "oppi", "--prompt", "daily", "--every", "1d"],
      ["session", "send", "sess-1", "--text", "hello"],
      ["session", "stop", "sess-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({ ok: false });
    }
  });
});
