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

type TraceOutlineFixtureEntry = {
  id: string;
  kind: string;
  summary: string;
  tool?: string;
  isError?: boolean;
};

async function runTraceOutlineCli(entries: TraceOutlineFixtureEntry[]): Promise<string> {
  const fixtureDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-trace-outline-"));
  const api = createHttpServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    res.writeHead(200, { "Content-Type": "application/json" });
    if (url.pathname === "/sessions/sess-1") {
      res.end(JSON.stringify({ session: { id: "sess-1", workspaceId: "ws-1" } }));
      return;
    }
    if (url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-outline") {
      res.end(
        JSON.stringify({
          session: { id: "sess-1", workspaceId: "ws-1" },
          outline: {
            traceVersion: "fixture",
            entries,
            itemCount: entries.length,
            sourceCount: entries.length > 0 ? 1 : 0,
            jsonlBytes: entries.length > 0 ? 100 : 0,
          },
          metrics: {},
        }),
      );
      return;
    }
    res.end(JSON.stringify({ error: `Unexpected route: ${url.pathname}` }));
  });

  try {
    await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("API fixture did not bind");
    writeCliConfig(fixtureDataDir, address.port);
    return await runCli(["session", "trace-outline", "sess-1"], fixtureDataDir);
  } finally {
    await new Promise<void>((resolveClose, rejectClose) =>
      api.close((error) => (error ? rejectClose(error) : resolveClose())),
    );
    rmSync(fixtureDataDir, { recursive: true, force: true });
  }
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

  it("renders trace outline messages and tool activity from the API snapshot", async () => {
    const stdout = await runTraceOutlineCli([
      { id: "u1", kind: "user", summary: "first prompt" },
      { id: "a1-text-0", kind: "assistant", summary: "first answer" },
      {
        id: "tc-1",
        kind: "tool",
        tool: "read",
        summary: "read server/src/trace.ts",
        isError: false,
      },
    ]);

    expect(stdout).toContain("Trace outline for sess-1 (3)");
    expect(stdout).toContain("u1  user  first prompt");
    expect(stdout).toContain("a1-text-0  assistant  first answer");
    expect(stdout).toContain("tc-1  tool  read server/src/trace.ts");
    expect(stdout).toContain("tool read");
  });

  it("states clearly when the API trace outline is genuinely empty", async () => {
    const stdout = await runTraceOutlineCli([]);

    expect(stdout).toContain("Trace outline for sess-1 (0)");
    expect(stdout).toContain("No trace entries found.");
  });
});
