/**
 * CLI integration tests — invoke the built CLI binary and check outputs.
 *
 * Tests non-interactive commands: help, status, config, token, pair, env, unknown.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFile, execFileSync, execSync } from "node:child_process";
import { createServer as createHttpServer } from "node:http";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from "node:net";

const CLI = resolve(__dirname, "../dist/src/cli.js");
let dataDir: string;

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function run(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 5000,
): { stdout: string; exitCode: number } {
  try {
    const stdout = execFileSync("node", [CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
      timeout: timeoutMs,
    });
    return { stdout, exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; status?: number };
    return { stdout: e.stdout ?? "", exitCode: e.status ?? 1 };
  }
}

function runBin(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 5000,
): { stdout: string; exitCode: number } {
  try {
    const stdout = execFileSync(CLI, args, {
      encoding: "utf-8",
      env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
      timeout: timeoutMs,
    });
    return { stdout, exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; status?: number };
    return { stdout: e.stdout ?? "", exitCode: e.status ?? 1 };
  }
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

async function runAsync(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 5000,
): Promise<{ stdout: string; exitCode: number }> {
  return await new Promise((resolveRun) => {
    execFile(
      "node",
      [CLI, ...args],
      {
        encoding: "utf-8",
        env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
        timeout: timeoutMs,
      },
      (error, stdout) => {
        const exitCode =
          error && typeof error === "object" && "code" in error ? Number(error.code) : 0;
        resolveRun({ stdout, exitCode: Number.isFinite(exitCode) ? exitCode : 1 });
      },
    );
  });
}

async function getFreePort(): Promise<number> {
  return await new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Failed to allocate test port")));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolvePort(port);
      });
    });
  });
}

beforeAll(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-test-"));
  execSync("npm run build", { cwd: resolve(__dirname, ".."), stdio: "pipe" });
}, 30_000);

afterAll(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

// ── Help ──

describe("oppi help", () => {
  it("prints usage with 'help'", () => {
    const { stdout, exitCode } = run(["help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("oppi");
    expect(stdout).toContain("serve");
    expect(stdout).toContain("pair");
    expect(stdout).toContain("config");
  });

  it("prints usage with '--help'", () => {
    const { stdout, exitCode } = run(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("prints usage with '-h'", () => {
    const { stdout, exitCode } = run(["-h"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("prints usage with no args", () => {
    const { stdout, exitCode } = run([]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("executes the built bin target directly", () => {
    const { stdout, exitCode } = runBin(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("keeps top-level help focused on nouns and common flows", () => {
    const { stdout, exitCode } = run(["help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Common flows");
    expect(text).toContain("serve/start");
    expect(text).toContain("workspace");
    expect(text).toContain("worktree");
    expect(text).toContain("agent");
    expect(text).toContain("wait");
    expect(text).toContain("schedule help");
    expect(text).toContain("session create --help");
    expect(text).not.toContain("--workspace <id>");
    expect(text).not.toContain("--prompt <text>");
  });

  it("prints schedule concept, subcommands, and examples with 'schedule help'", () => {
    const { stdout, exitCode } = run(["schedule", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Schedules run Oppi actions");
    expect(text).toContain("Subcommands");
    expect(text).toContain("create");
    expect(text).toContain("runs");
    expect(text).toContain("oppi schedule create");
  });

  it("prints exact schedule create flags, run-history notes, and examples", () => {
    const { stdout, exitCode } = run(["schedule", "create", "--help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Usage: oppi schedule create");
    expect(text).toContain("--workspace <workspace>");
    expect(text).toContain("--prompt <text>");
    expect(text).toContain("--at <iso>");
    expect(text).toContain("--every <duration>");
    expect(text).toContain("--cron <expr>");
    expect(text).toContain("Run history");
    expect(text).toContain("idempotent");
  });

  it("prints exact session create flags and launch idempotency behavior", () => {
    const { stdout, exitCode } = run(["session", "create", "--help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Usage: oppi session create");
    expect(text).toContain("--workspace <workspace>");
    expect(text).toContain("--prompt <text>");
    expect(text).toContain("--idempotency-key <key>");
    expect(text).toContain("reuses the existing launch");
  });

  it("documents the implemented session app-control commands", () => {
    const { stdout, exitCode } = run(["session", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Subcommands");
    for (const implemented of [
      "list",
      "get",
      "create",
      "send",
      "read",
      "events",
      "trace",
      "stop",
    ]) {
      expect(text).toContain(implemented);
    }
    expect(text).not.toContain("Not implemented in the CLI yet");
  });

  it("documents the implemented saved Agent commands", () => {
    const { stdout, exitCode } = run(["agent", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Saved Agents");
    for (const implemented of ["list", "get", "create", "update", "archive"]) {
      expect(text).toContain(implemented);
    }
    expect(text).toContain("session create --agent");
  });

  it("prints agent-readable help with '--json'", () => {
    const { stdout, exitCode } = run(["help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: [],
          subcommands: expect.arrayContaining([
            expect.objectContaining({ name: "schedule" }),
            expect.objectContaining({ name: "session" }),
            expect.objectContaining({ name: "agent" }),
          ]),
        },
      },
    });
  });

  it("prints command-specific help for every top-level command noun", () => {
    const cases: Array<{ args: string[]; expected: string[] }> = [
      { args: ["init", "--help"], expected: ["Usage: oppi init", "--data-dir <path>"] },
      { args: ["serve", "--help"], expected: ["Usage: oppi serve", "--host <host>"] },
      { args: ["pair", "--help"], expected: ["Usage: oppi pair", "--show-token"] },
      { args: ["status", "--help"], expected: ["Usage: oppi status", "Local Network"] },
      { args: ["doctor", "--help"], expected: ["Usage: oppi doctor", "diagnostics"] },
      { args: ["update", "--help"], expected: ["Usage: oppi update", "--self"] },
      { args: ["token", "help"], expected: ["Usage: oppi token rotate", "Existing clients"] },
      { args: ["config", "help"], expected: ["Usage: oppi config", "Subcommands"] },
      { args: ["server", "help"], expected: ["Usage: oppi server", "LaunchAgent"] },
      { args: ["workspace", "help"], expected: ["Usage: oppi workspace", "list", "get"] },
      { args: ["worktree", "help"], expected: ["Usage: oppi worktree", "--workspace <workspace>"] },
      { args: ["wait", "help"], expected: ["Usage: oppi wait", "session"] },
      { args: ["version", "--help"], expected: ["Usage: oppi version", "package version"] },
    ];

    for (const testCase of cases) {
      const { stdout, exitCode } = run(testCase.args);
      const text = stripAnsi(stdout);

      expect(exitCode).toBe(0);
      for (const expected of testCase.expected) {
        expect(text).toContain(expected);
      }
    }
  });

  it("prints useful help for nested utility subcommands", () => {
    const cases: Array<{ args: string[]; expected: string[] }> = [
      {
        args: ["config", "set", "--help"],
        expected: ["Usage: oppi config set <key> <value>", "runtimeEnv.<NAME>", "tls.mode"],
      },
      {
        args: ["config", "validate", "--help"],
        expected: ["Usage: oppi config validate", "--config-file <path>"],
      },
      {
        args: ["server", "install", "--help"],
        expected: ["Usage: oppi server install", "--data-dir <path>"],
      },
      {
        args: ["server", "restart", "--help"],
        expected: ["Usage: oppi server restart", "background server"],
      },
      {
        args: ["schedule", "list", "--help"],
        expected: ["Usage: oppi schedule list", "--json"],
      },
      {
        args: ["schedule", "get", "--help"],
        expected: ["Usage: oppi schedule get <id>", "schedule id", "--json"],
      },
      {
        args: ["schedule", "run", "--help"],
        expected: ["Usage: oppi schedule run <id>", "--request-id <key>", "idempotent"],
      },
      {
        args: ["schedule", "runs", "--help"],
        expected: ["Usage: oppi schedule runs <id>", "run history", "--json"],
      },
      {
        args: ["schedule", "pause", "--help"],
        expected: ["Usage: oppi schedule pause <id>", "automatic runs", "--json"],
      },
      {
        args: ["schedule", "resume", "--help"],
        expected: ["Usage: oppi schedule resume <id>", "automatic runs", "--json"],
      },
      {
        args: ["schedule", "archive", "--help"],
        expected: ["Usage: oppi schedule archive <id>", "no longer runs automatically", "--json"],
      },
      {
        args: ["schedule", "update", "--help"],
        expected: ["Usage: oppi schedule update <id>", "--definition <file>", "--json"],
      },
      {
        args: ["workspace", "list", "--help"],
        expected: ["Usage: oppi workspace list", "--json"],
      },
      {
        args: ["workspace", "get", "--help"],
        expected: ["Usage: oppi workspace get <workspace>", "workspace id or unique name"],
      },
      {
        args: ["worktree", "list", "--help"],
        expected: ["Usage: oppi worktree list", "--workspace <workspace>"],
      },
      {
        args: ["worktree", "get", "--help"],
        expected: ["Usage: oppi worktree get <worktree>", "main"],
      },
      {
        args: ["session", "list", "--help"],
        expected: ["Usage: oppi session list", "--workspace <workspace>", "--json"],
      },
      {
        args: ["session", "get", "--help"],
        expected: ["Usage: oppi session get <id>", "metadata"],
      },
      {
        args: ["session", "send", "--help"],
        expected: ["Usage: oppi session send <id>", "--text <text>"],
      },
      {
        args: ["session", "read", "--help"],
        expected: ["Usage: oppi session read <id>", "--tail <count>"],
      },
      {
        args: ["session", "events", "--help"],
        expected: ["Usage: oppi session events <id>", "--since <cursor>"],
      },
      {
        args: ["session", "trace", "--help"],
        expected: ["Usage: oppi session trace <id>", "--include <parts>"],
      },
      {
        args: ["session", "stop", "--help"],
        expected: ["Usage: oppi session stop <id>", "--json"],
      },
      {
        args: ["agent", "list", "--help"],
        expected: ["Usage: oppi agent list", "--json"],
      },
      {
        args: ["agent", "get", "--help"],
        expected: ["Usage: oppi agent get <agent>", "agent id or unique name"],
      },
      {
        args: ["agent", "create", "--help"],
        expected: ["Usage: oppi agent create", "--definition <file>", "--name <name>"],
      },
      {
        args: ["agent", "update", "--help"],
        expected: ["Usage: oppi agent update <agent>", "--definition <file>"],
      },
      {
        args: ["agent", "archive", "--help"],
        expected: ["Usage: oppi agent archive <agent>", "--json"],
      },
      {
        args: ["wait", "session", "--help"],
        expected: ["Usage: oppi wait session <id>", "--status <status>"],
      },
    ];

    for (const testCase of cases) {
      const { stdout, exitCode } = run(testCase.args);
      const text = stripAnsi(stdout);

      expect(exitCode).toBe(0);
      for (const expected of testCase.expected) {
        expect(text).toContain(expected);
      }
    }
  }, 30_000);

  it("prints agent-readable JSON help for agent namespace", () => {
    const { stdout, exitCode } = run(["agent", "help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: ["agent"],
          subcommands: expect.arrayContaining([expect.objectContaining({ name: "create" })]),
        },
      },
    });
  });

  it("prints agent-readable JSON help for nested utility subcommands", () => {
    const { stdout, exitCode } = run(["config", "set", "--help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: ["config", "set"],
          keys: expect.arrayContaining([expect.objectContaining({ name: "runtimeEnv.<NAME>" })]),
        },
      },
    });
  });
});

// ── Unknown command ──

describe("unknown command", () => {
  it("exits 1 with error message", () => {
    const { stdout, exitCode } = run(["bananas"]);
    expect(exitCode).toBe(1);
    expect(stdout).toContain("Unknown command: bananas");
  });
});

// ── Config ──

describe("oppi config", () => {
  it("config show displays config", () => {
    const { stdout, exitCode } = run(["config", "show"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("port");
  });

  it("config set/get roundtrips a value", () => {
    run(["config", "set", "port", "9999"]);
    const { stdout } = run(["config", "get", "port"]);
    expect(stdout.trim()).toContain("9999");
  });

  it("config set updates extension config", () => {
    run(["config", "set", "extensions", '{"voice":{"defaultVoiceId":"warm"}}']);
    const { stdout } = run(["config", "get", "extensions"]);
    expect(stdout.trim()).toContain('"defaultVoiceId": "warm"');
  });

  it("config set/get supports nested config paths", () => {
    run(["config", "set", "asr.sttEndpoint", "http://127.0.0.1:7936"]);
    const { stdout } = run(["config", "get", "asr.sttEndpoint"]);
    expect(stdout.trim()).toBe("http://127.0.0.1:7936");
  });

  it("config set/get supports the Oppi docs prompt toggle", () => {
    run(["config", "set", "oppiDocsPrompt.enabled", "false"]);
    const { stdout } = run(["config", "get", "oppiDocsPrompt.enabled"]);
    expect(stdout.trim()).toBe("false");
  });

  it("config set supports nested extension config paths", () => {
    run(["config", "set", "extensions.voice.defaultVoiceId", "warm-technical-teammate"]);
    const { stdout } = run(["config", "get", "extensions"]);
    expect(stdout).toContain("warm-technical-teammate");
  });

  it("config set supports dynamic runtimeEnv keys", () => {
    run(["config", "set", "runtimeEnv.TTS_BASE_URL", "http://127.0.0.1:7937"]);
    const { stdout } = run(["config", "get", "runtimeEnv.TTS_BASE_URL"]);
    expect(stdout.trim()).toBe("http://127.0.0.1:7937");
  });

  it("config validate succeeds on valid config", () => {
    const { stdout, exitCode } = run(["config", "validate"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Config valid");
  });

  it("config validate detects invalid config file", () => {
    const badConfig = join(dataDir, "bad-config.json");
    writeFileSync(badConfig, '{ "port": "not-a-number" }');
    const { stdout, exitCode } = run(["config", "validate", "--config-file", badConfig]);
    // Should report issues
    expect(stdout.length).toBeGreaterThan(0);
  });
});

// ── Session ──

describe("oppi session", () => {
  it("session create --json reports missing required flags in a stable envelope", () => {
    const { stdout, exitCode } = run(["session", "create", "--json"]);
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "--workspace and --prompt are required" },
    });
  });
});

// ── Wait ──

describe("oppi wait", () => {
  it("rejects a zero poll interval before polling the local API", () => {
    const { stdout, exitCode } = run([
      "wait",
      "session",
      "sess-1",
      "--poll",
      "0ms",
      "--json",
    ]);

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "--poll must be a positive duration" },
    });
  });
});

// ── Local API CLI ──

describe("oppi local API commands", () => {
  it("implements the spec-backed app-control CLI over local API routes", async () => {
    const requests: Array<{ method: string; path: string; body?: unknown }> = [];
    const api = createHttpServer((req, res) => {
      void (async () => {
        const chunks: Buffer[] = [];
        for await (const chunk of req) {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
        }
        const rawBody = Buffer.concat(chunks).toString("utf8");
        const body = rawBody ? JSON.parse(rawBody) : undefined;
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const method = req.method ?? "GET";
        requests.push({ method, path: `${url.pathname}${url.search}`, ...(body ? { body } : {}) });

        function json(payload: unknown): void {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(payload));
        }

        if (method === "GET" && url.pathname === "/workspaces") {
          json({
            workspaces: [{ id: "ws-1", name: "Oppi", hostMount: "/tmp/oppi" }],
            summaries: [],
            serverNow: 1,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1") {
          json({ workspace: { id: "ws-1", name: "Oppi", hostMount: "/tmp/oppi" } });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/worktrees") {
          json({
            workspaceId: "ws-1",
            worktrees: [{ id: "main", name: "main", path: "/tmp/oppi" }],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions") {
          json({
            sessions: [
              {
                id: "sess-1",
                workspaceId: "ws-1",
                worktreeId: "main",
                status: "stopped",
                name: "Demo",
              },
            ],
            serverNow: 2,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1") {
          json({ session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" } });
          return;
        }
        if (method === "GET" && url.pathname === "/agents") {
          json({ agents: [{ id: "agent-1", name: "Reviewer", status: "active", version: 1 }] });
          return;
        }
        if (method === "GET" && url.pathname === "/agents/agent-1") {
          json({
            agent: {
              id: "agent-1",
              name: "Reviewer",
              status: "active",
              version: 1,
              definition: { name: "Reviewer" },
            },
          });
          return;
        }
        if (method === "POST" && url.pathname === "/agents") {
          json({
            agent: {
              id: "agent-created",
              name: body?.name ?? "Created",
              status: "active",
              version: 1,
              definition: body,
            },
          });
          return;
        }
        if (method === "PATCH" && url.pathname === "/agents/agent-1") {
          json({
            agent: {
              id: "agent-1",
              name: "Reviewer",
              status: "active",
              version: 2,
              definition: body,
            },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/agents/agent-1") {
          json({ agent: { id: "agent-1", name: "Reviewer", status: "archived", version: 2 } });
          return;
        }
        if (method === "POST" && url.pathname === "/agents/agent-1/sessions") {
          json({
            receipt: {
              accepted: true,
              agentId: "agent-1",
              agentVersion: 1,
              sessionId: "sess-agent-1",
              promptDispatch: "delivered",
            },
            session: { id: "sess-agent-1", workspaceId: "ws-1", status: "ready" },
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/read") {
          json({
            session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
            trace: [
              { type: "user", text: "hello" },
              { type: "assistant", text: "hi" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/events") {
          json({
            events: [{ seq: 5, type: "session_updated" }],
            currentSeq: 5,
            catchUpComplete: true,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/trace") {
          json({
            session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
            trace: [{ type: "assistant", text: "trace" }],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/sessions/sess-1/command") {
          json({ messages: [{ type: "command_result", success: true }] });
          return;
        }
        if (method === "POST" && url.pathname === "/sessions/sess-1/stop") {
          json({ ok: true, session: { id: "sess-1", status: "stopped" } });
          return;
        }
        if (method === "PATCH" && url.pathname === "/schedules/sch-1") {
          json({ schedule: { id: "sch-1", status: "active", name: "Updated" } });
          return;
        }

        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: `${method} ${url.pathname} not handled` }));
      })().catch((error: unknown) => {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
      });
    });
    await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("Failed to start API fixture");
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-app-control-"));
    const definitionPath = join(cliDir, "schedule.json");
    const agentDefinitionPath = join(cliDir, "agent.json");
    const agentUpdatePath = join(cliDir, "agent-update.json");
    writeFileSync(definitionPath, JSON.stringify({ name: "Updated" }));
    writeFileSync(
      agentDefinitionPath,
      JSON.stringify({ description: "Reviews diffs", sessionDefaults: { model: "agent-model" } }),
    );
    writeFileSync(agentUpdatePath, JSON.stringify({ description: "Reviews risky diffs" }));

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);
      expect(
        run(["config", "set", "port", String(address.port)], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);

      const cases: Array<{ args: string[]; expected: string[] }> = [
        { args: ["workspace", "list", "--json"], expected: ["GET /workspaces"] },
        { args: ["workspace", "get", "ws-1", "--json"], expected: ["GET /workspaces/ws-1"] },
        {
          args: ["worktree", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        {
          args: ["worktree", "get", "main", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        { args: ["agent", "list", "--json"], expected: ["GET /agents"] },
        { args: ["agent", "get", "agent-1", "--json"], expected: ["GET /agents/agent-1"] },
        {
          args: [
            "agent",
            "create",
            "--name",
            "Reviewer",
            "--definition",
            agentDefinitionPath,
            "--json",
          ],
          expected: ["POST /agents"],
        },
        {
          args: ["agent", "update", "agent-1", "--definition", agentUpdatePath, "--json"],
          expected: ["PATCH /agents/agent-1"],
        },
        { args: ["agent", "archive", "agent-1", "--json"], expected: ["DELETE /agents/agent-1"] },
        {
          args: ["session", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /sessions?workspaceId=ws-1"],
        },
        { args: ["session", "get", "sess-1", "--json"], expected: ["GET /sessions/sess-1"] },
        {
          args: ["session", "read", "sess-1", "--tail", "1", "--json"],
          expected: ["GET /sessions/sess-1/read?tail=1"],
        },
        {
          args: ["session", "events", "sess-1", "--since", "4", "--json"],
          expected: ["GET /sessions/sess-1/events?since=4"],
        },
        {
          args: ["session", "trace", "sess-1", "--include", "summary,tools", "--json"],
          expected: ["GET /sessions/sess-1/trace?include=summary%2Ctools"],
        },
        {
          args: ["session", "send", "sess-1", "--text", "hello", "--json"],
          expected: ["POST /sessions/sess-1/command"],
        },
        { args: ["session", "stop", "sess-1", "--json"], expected: ["POST /sessions/sess-1/stop"] },
        {
          args: [
            "session",
            "create",
            "--agent",
            "agent-1",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from agent",
            "--idempotency-key",
            "agent-cli-1",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /agents/agent-1/sessions"],
        },
        {
          args: ["schedule", "update", "sch-1", "--definition", definitionPath, "--json"],
          expected: ["PATCH /schedules/sch-1"],
        },
        {
          args: ["wait", "session", "sess-1", "--status", "stopped", "--json"],
          expected: ["GET /sessions/sess-1"],
        },
      ];

      for (const testCase of cases) {
        const before = requests.length;
        const { stdout, exitCode } = await runAsync(testCase.args, { OPPI_DATA_DIR: cliDir });
        expect(exitCode, testCase.args.join(" ")).toBe(0);
        expect(JSON.parse(stdout), testCase.args.join(" ")).toMatchObject({ ok: true });
        const seen = requests.slice(before).map((request) => `${request.method} ${request.path}`);
        for (const expected of testCase.expected) {
          expect(seen, testCase.args.join(" ")).toContain(expected);
        }
      }

      const agentCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/agents",
      );
      expect(agentCreateRequest?.body).toMatchObject({
        name: "Reviewer",
        description: "Reviews diffs",
        sessionDefaults: { model: "agent-model" },
      });
      const agentSessionRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/agents/agent-1/sessions",
      );
      expect(agentSessionRequest?.body).toMatchObject({
        prompt: { text: "hello from agent" },
        target: { workspaceId: "ws-1" },
        idempotencyKey: "agent-cli-1",
      });
      const sendRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/sessions/sess-1/command",
      );
      expect(sendRequest?.body).toMatchObject({ type: "prompt", message: "hello" });
      const updateRequest = requests.find(
        (request) => request.method === "PATCH" && request.path === "/schedules/sch-1",
      );
      expect(updateRequest?.body).toEqual({ name: "Updated" });
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
    }
  }, 45_000);

  it("schedule list --json fails fast on malformed successful API JSON", async () => {
    const api = createHttpServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("not-json");
    });
    await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("Failed to start API fixture");
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-local-api-"));

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);
      expect(
        run(["config", "set", "port", String(address.port)], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);

      const { stdout, exitCode } = await runAsync(["schedule", "list", "--json"], {
        OPPI_DATA_DIR: cliDir,
      });

      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toEqual({
        ok: false,
        error: { message: "Invalid JSON response from local API" },
      });
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
    }
  });
});

// ── Status ──

describe("oppi status", () => {
  it("prints status info", () => {
    const { stdout, exitCode } = run(["status"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Server Configuration");
  });
});

// ── Token ──

describe("oppi token", () => {
  it("token rotate fails before pairing", () => {
    const freshDir = mkdtempSync(join(tmpdir(), "oppi-cli-token-"));
    const { exitCode } = run(["token", "rotate"], { OPPI_DATA_DIR: freshDir });
    expect(exitCode).toBe(1);
    rmSync(freshDir, { recursive: true, force: true });
  });

  it("token rotate generates a new token after pairing", () => {
    // Pair first to create owner token
    run(["pair"]);
    const { stdout: before } = run(["config", "get", "token"]);
    const { stdout, exitCode } = run(["token", "rotate"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("rotated");
    const { stdout: after } = run(["config", "get", "token"]);
    expect(after.trim()).not.toBe(before.trim());
  });

  it("token rotate remains valid across consecutive rotations", () => {
    run(["pair"]);

    const { stdout: firstBefore } = run(["config", "get", "token"]);
    const rotate1 = run(["token", "rotate"]);
    const { stdout: firstAfter } = run(["config", "get", "token"]);

    expect(rotate1.exitCode).toBe(0);
    expect(firstAfter.trim()).not.toBe(firstBefore.trim());
    expect(firstAfter.trim()).toMatch(/^sk_/);

    const rotate2 = run(["token", "rotate"]);
    const { stdout: secondAfter } = run(["config", "get", "token"]);

    expect(rotate2.exitCode).toBe(0);
    expect(secondAfter.trim()).not.toBe(firstAfter.trim());
    expect(secondAfter.trim()).toMatch(/^sk_/);
  });
});

// ── Pair ──

describe("oppi pair", () => {
  it("generates QR code output", () => {
    const { stdout, exitCode } = run(["pair"]);
    // Pair should succeed or at least output something
    // Host auto-detection may vary by environment but should still output
    expect(exitCode).toBe(0);
    // Should contain QR blocks or URL
    expect(stdout.length).toBeGreaterThan(50);
  });
});

describe.skipIf(!hasOpenSSL)("oppi pair (tls self-signed)", () => {
  it("embeds https scheme + cert fingerprint in invite payload", () => {
    const tlsDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-pair-tls-"));

    try {
      const setResult = run(["config", "set", "tls", '{"mode":"self-signed"}'], {
        OPPI_DATA_DIR: tlsDataDir,
      });
      expect(setResult.exitCode).toBe(0);

      const { stdout, exitCode } = run(["pair", "--host", "127.0.0.1"], {
        OPPI_DATA_DIR: tlsDataDir,
      });
      expect(exitCode).toBe(0);

      const stripped = stdout.replace(/\x1b\[[0-9;]*m/g, "");
      const link = stripped.match(/oppi:\/\/connect\?[^\s]+/);
      expect(link).not.toBeNull();

      const url = new URL(link![0]);
      const invite = url.searchParams.get("invite");
      expect(invite).toBeTruthy();

      const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
        signedPayload?: string;
        publicKey?: string;
        signature?: string;
      };
      expect(envelope.publicKey).toBeTruthy();
      expect(envelope.signature).toBeTruthy();
      const payload = JSON.parse(
        Buffer.from(envelope.signedPayload!, "base64url").toString("utf-8"),
      ) as {
        scheme?: string;
        tlsCertFingerprint?: string;
      };

      expect(payload.scheme).toBe("https");
      expect(payload.tlsCertFingerprint?.startsWith("sha256:")).toBe(true);
    } finally {
      rmSync(tlsDataDir, { recursive: true, force: true });
    }
  });
});

describe.skipIf(!hasOpenSSL)("oppi pair (tls tailscale)", () => {
  it("embeds https scheme + tailscale hostname without a rotating leaf cert pin", () => {
    const tlsDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-pair-tailscale-"));
    const fakeBinDir = mkdtempSync(join(tmpdir(), "oppi-cli-fake-tailscale-"));
    const fakeTailscalePath = join(fakeBinDir, "tailscale");

    writeFileSync(
      fakeTailscalePath,
      `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
if [[ -z "\$cmd" ]]; then
  exit 1
fi
shift || true

case "\$cmd" in
  status)
    if [[ "\${1:-}" == "--json" ]]; then
      echo '{"Self":{"DNSName":"my-server.tail00000.ts.net."}}'
      exit 0
    fi
    ;;
  cert)
    cert_file=""
    key_file=""
    host=""

    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --cert-file)
          cert_file="\$2"
          shift 2
          ;;
        --key-file)
          key_file="\$2"
          shift 2
          ;;
        --min-validity)
          shift 2
          ;;
        *)
          host="\$1"
          shift
          ;;
      esac
    done

    if [[ -z "\$cert_file" || -z "\$key_file" || -z "\$host" ]]; then
      echo "missing cert args" >&2
      exit 1
    fi

    mkdir -p "\$(dirname "\$cert_file")" "\$(dirname "\$key_file")"
    openssl req -x509 -newkey rsa:2048 -nodes \\
      -keyout "\$key_file" \\
      -out "\$cert_file" \\
      -subj "/CN=\$host" \\
      -days 1 >/dev/null 2>&1
    exit 0
    ;;
esac

echo "unsupported args: \$cmd \$*" >&2
exit 1
`,
      { mode: 0o755 },
    );
    chmodSync(fakeTailscalePath, 0o755);

    const env = {
      OPPI_DATA_DIR: tlsDataDir,
      PATH: `${fakeBinDir}:${process.env.PATH ?? ""}`,
    };

    try {
      const setResult = run(["config", "set", "tls", '{"mode":"tailscale"}'], env);
      expect(setResult.exitCode).toBe(0);

      const { stdout, exitCode } = run(["pair"], env);
      expect(exitCode).toBe(0);

      const stripped = stdout.replace(/\x1b\[[0-9;]*m/g, "");
      const link = stripped.match(/oppi:\/\/connect\?[^\s]+/);
      expect(link).not.toBeNull();

      const url = new URL(link![0]);
      const invite = url.searchParams.get("invite");
      expect(invite).toBeTruthy();

      const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
        signedPayload?: string;
        publicKey?: string;
        signature?: string;
      };
      expect(envelope.publicKey).toBeTruthy();
      expect(envelope.signature).toBeTruthy();
      const payload = JSON.parse(
        Buffer.from(envelope.signedPayload!, "base64url").toString("utf-8"),
      ) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };

      expect(payload.host).toBe("my-server.tail00000.ts.net");
      expect(payload.scheme).toBe("https");
      expect(payload.tlsCertFingerprint).toBeUndefined();
    } finally {
      rmSync(tlsDataDir, { recursive: true, force: true });
      rmSync(fakeBinDir, { recursive: true, force: true });
    }
  });
});

describe("oppi serve (first-run tls bootstrap)", () => {
  it("upgrades legacy disabled TLS to self-signed on first serve", async () => {
    const serveDir = mkdtempSync(join(tmpdir(), "oppi-cli-serve-tls-"));

    try {
      const freePort = await getFreePort();
      const { stdout: defaultTlsJson, exitCode: defaultExitCode } = run(["config", "get", "tls"], {
        OPPI_DATA_DIR: serveDir,
      });
      expect(defaultExitCode).toBe(0);
      const defaultTls = JSON.parse(defaultTlsJson) as { mode?: string };
      expect(defaultTls.mode).toBe("self-signed");

      const { exitCode: setDisabledExitCode } = run(
        ["config", "set", "tls", '{"mode":"disabled"}'],
        { OPPI_DATA_DIR: serveDir },
      );
      expect(setDisabledExitCode).toBe(0);

      const { exitCode: setPortExitCode } = run(["config", "set", "port", String(freePort)], {
        OPPI_DATA_DIR: serveDir,
      });
      expect(setPortExitCode).toBe(0);

      const { exitCode: setHostExitCode } = run(["config", "set", "host", "127.0.0.1"], {
        OPPI_DATA_DIR: serveDir,
      });
      expect(setHostExitCode).toBe(0);

      const { stdout: beforeTlsJson, exitCode: beforeExitCode } = run(["config", "get", "tls"], {
        OPPI_DATA_DIR: serveDir,
      });
      expect(beforeExitCode).toBe(0);
      const beforeTls = JSON.parse(beforeTlsJson) as { mode?: string };
      expect(beforeTls.mode).toBe("disabled");

      // `serve` is long-running; use a short timeout to trigger startup path.
      const { stdout: serveStdout } = run(["serve"], { OPPI_DATA_DIR: serveDir }, 2_500);

      const strippedServe = serveStdout.replace(/\x1b\[[0-9;]*m/g, "");
      expect(strippedServe).toContain("Scan this QR code in Oppi:");
      expect(strippedServe).toContain("oppi://connect?");
      expect(strippedServe).not.toContain("✓ Paired");
      expect(strippedServe).not.toContain("Waiting for connections...");

      const { stdout: afterTlsJson, exitCode: afterExitCode } = run(["config", "get", "tls"], {
        OPPI_DATA_DIR: serveDir,
      });
      expect(afterExitCode).toBe(0);
      const afterTls = JSON.parse(afterTlsJson) as { mode?: string };
      expect(afterTls.mode).toBe("self-signed");
    } finally {
      rmSync(serveDir, { recursive: true, force: true });
    }
  });
});

// ── Init ──

describe("oppi doctor", () => {
  it("reports missing self-signed TLS material without generating it", () => {
    const doctorDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-"));
    const certPath = join(doctorDir, "tls", "self-signed", "server.crt");
    const keyPath = join(doctorDir, "tls", "self-signed", "server.key");
    const caPath = join(doctorDir, "tls", "self-signed", "ca.crt");

    try {
      const { exitCode: initExitCode } = run(["init", "--yes", "--data-dir", doctorDir]);
      expect(initExitCode).toBe(0);

      const { stdout, exitCode } = run(["doctor"], { OPPI_DATA_DIR: doctorDir });
      expect(exitCode).toBe(1);
      expect(stdout).toContain("TLS cert missing");
      expect(stdout).toContain("TLS key missing");
      expect(stdout).toContain("TLS CA missing");
      expect(existsSync(certPath)).toBe(false);
      expect(existsSync(keyPath)).toBe(false);
      expect(existsSync(caPath)).toBe(false);
    } finally {
      rmSync(doctorDir, { recursive: true, force: true });
    }
  });
});

describe("oppi init (non-interactive)", () => {
  it("writes config with self-signed TLS by default", () => {
    const initDir = mkdtempSync(join(tmpdir(), "oppi-cli-init-"));

    try {
      const { exitCode } = run(["init", "--yes", "--data-dir", initDir]);
      expect(exitCode).toBe(0);

      const { stdout: tlsJson } = run(["config", "get", "tls"], { OPPI_DATA_DIR: initDir });
      const config = JSON.parse(tlsJson) as { mode?: string };

      expect(config.mode).toBe("self-signed");
    } finally {
      rmSync(initDir, { recursive: true, force: true });
    }
  });

  it("outputs TLS confirmation message", () => {
    const initDir = mkdtempSync(join(tmpdir(), "oppi-cli-init-tls-msg-"));

    try {
      const { stdout, exitCode } = run(["init", "--yes", "--data-dir", initDir]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain("self-signed");
    } finally {
      rmSync(initDir, { recursive: true, force: true });
    }
  });
});
