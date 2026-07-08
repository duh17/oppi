import { execFile, execSync } from "node:child_process";
import { createServer as createHttpServer } from "node:http";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { ConfigStore } from "../src/storage/config-store.js";

const CLI = resolve(__dirname, "../dist/src/cli.js");

function writeCliConfig(dataDir: string, port: number): void {
  mkdirSync(dataDir, { recursive: true });
  const config = {
    ...ConfigStore.getDefaultConfig(dataDir),
    host: "127.0.0.1",
    port,
    token: "test-owner-token",
    tls: { mode: "disabled" as const },
  };
  writeFileSync(join(dataDir, "config.json"), `${JSON.stringify(config, null, 2)}\n`);
}

function sessionStateDbFiles(dataDir: string): string[] {
  return readdirSync(dataDir).filter((name) => name.startsWith("session-state.db"));
}

async function runCli(args: string[], dataDir: string): Promise<string> {
  return await new Promise((resolveRun, rejectRun) => {
    execFile(
      "node",
      [CLI, ...args],
      { encoding: "utf-8", env: { ...process.env, OPPI_DATA_DIR: dataDir } },
      (error, stdout, stderr) => {
        if (error) {
          rejectRun(new Error(stderr || stdout || error.message));
          return;
        }
        resolveRun(stdout);
      },
    );
  });
}

describe("CLI app-state API boundary", () => {
  beforeAll(() => {
    execSync("npm run build", { cwd: resolve(__dirname, ".."), stdio: "pipe" });
  }, 30_000);

  it("serves workspace reads through the local API without opening session-state SQLite", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-api-first-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ workspaces: [{ id: "ws-1", name: "Oppi" }] }));
    });

    try {
      await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
      const address = api.address();
      if (!address || typeof address === "string") throw new Error("API fixture did not bind");
      writeCliConfig(dataDir, address.port);

      const stdout = await runCli(["workspace", "list", "--json"], dataDir);

      expect(JSON.parse(stdout)).toMatchObject({
        ok: true,
        data: { workspaces: [{ id: "ws-1", name: "Oppi" }] },
      });
      expect(requests).toEqual(["GET /workspaces"]);
      expect(sessionStateDbFiles(dataDir)).toEqual([]);
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
