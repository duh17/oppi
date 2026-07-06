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
  timeoutMs = 15_000,
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
  timeoutMs = 15_000,
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
  timeoutMs = 15_000,
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
    expect(text).toContain("--approval-ref <ref>");
    expect(text).toContain("--agent <agent>");
    expect(text).toContain("Automatic runs fail closed");
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
      "search",
      "stop",
      "resume",
      "fork",
      "delete",
      "changes",
      "diff",
      "tool-output",
      "trace-page",
      "trace-outline",
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
      {
        args: ["workspace", "help"],
        expected: ["Usage: oppi workspace", "list", "get", "create", "update", "delete"],
      },
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
        expected: ["Usage: oppi schedule list", "--agent <agent>", "--json"],
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
        args: ["workspace", "create", "--help"],
        expected: ["Usage: oppi workspace create", "--host-mount <path>", "--definition <file>"],
      },
      {
        args: ["workspace", "update", "--help"],
        expected: ["Usage: oppi workspace update <workspace>", "--default-model <model>"],
      },
      {
        args: ["workspace", "delete", "--help"],
        expected: ["Usage: oppi workspace delete <workspace>", "--json"],
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
        args: ["worktree", "create", "--help"],
        expected: ["Usage: oppi worktree create", "--branch <branch>", "OPPI_DATA_DIR"],
      },
      {
        args: ["worktree", "open", "--help"],
        expected: ["Usage: oppi worktree open", "--branch <branch>", "--path <path>"],
      },
      {
        args: ["worktree", "status", "--help"],
        expected: ["Usage: oppi worktree status <worktree>", "git status"],
      },
      {
        args: ["worktree", "preview", "--help"],
        expected: ["Usage: oppi worktree preview <worktree>", "--into <branch>", "read-only"],
      },
      {
        args: ["worktree", "remove", "--help"],
        expected: ["Usage: oppi worktree remove <worktree>", "--force", "active sessions"],
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
        args: ["session", "search", "--help"],
        expected: ["Usage: oppi session search", "--query <text>", "--limit <count>"],
      },
      {
        args: ["session", "resume", "--help"],
        expected: ["Usage: oppi session resume <id>", "--json"],
      },
      {
        args: ["session", "fork", "--help"],
        expected: ["Usage: oppi session fork <id>", "--entry <entry-id>"],
      },
      {
        args: ["session", "delete", "--help"],
        expected: ["Usage: oppi session delete <id>", "--json"],
      },
      {
        args: ["session", "changes", "--help"],
        expected: ["Usage: oppi session changes <id>", "changed by a session"],
      },
      {
        args: ["session", "diff", "--help"],
        expected: ["Usage: oppi session diff <id>", "--path <path>"],
      },
      {
        args: ["session", "tool-output", "--help"],
        expected: ["Usage: oppi session tool-output <id>", "tool call id"],
      },
      {
        args: ["session", "trace-page", "--help"],
        expected: ["Usage: oppi session trace-page <id>", "--target-events <count>"],
      },
      {
        args: ["session", "trace-outline", "--help"],
        expected: ["Usage: oppi session trace-outline <id>", "compact trace outline"],
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
    const { stdout, exitCode } = run(["wait", "session", "sess-1", "--poll", "0ms", "--json"]);

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
        if (method === "POST" && url.pathname === "/workspaces") {
          json({
            workspace: {
              id: "ws-created",
              name: body?.name ?? "Created",
              hostMount: body?.hostMount,
              defaultModel: body?.defaultModel,
            },
          });
          return;
        }
        if (method === "PUT" && url.pathname === "/workspaces/ws-1") {
          json({
            workspace: {
              id: "ws-1",
              name: body?.name ?? "Oppi",
              hostMount: body?.hostMount ?? "/tmp/oppi",
              defaultModel: body?.defaultModel,
            },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/workspaces/ws-1") {
          json({ ok: true });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/worktrees") {
          json({
            workspaceId: "ws-1",
            worktrees: [{ id: "main", name: "main", path: "/tmp/oppi" }],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/worktrees") {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: body?.branch ?? "feature/cli",
              branch: body?.branch ?? "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/worktrees/open") {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: body?.branch ?? "feature/cli",
              branch: body?.branch ?? "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (
          method === "GET" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/status"
        ) {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: "feature/cli",
              branch: "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
            status: { isGitRepo: true, branch: "feature/cli", dirtyCount: 0, untrackedCount: 0 },
          });
          return;
        }
        if (
          method === "POST" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview"
        ) {
          json({
            workspaceId: "ws-1",
            preview: {
              worktree: { id: "wt_feature-cli-12345678", name: "feature/cli" },
              target: { ref: body?.into ?? "main", headSha: "target-sha" },
              source: { branch: "feature/cli", headSha: "source-sha" },
              mode: body?.mode ?? "merge",
              commitCount: 1,
              commits: [{ sha: "abc123", subject: "change" }],
              changedFiles: [{ status: "M", path: "README.md" }],
              alreadyMerged: false,
              fastForwardPossible: true,
              conflictCheck: "clean",
            },
          });
          return;
        }
        if (
          method === "DELETE" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678"
        ) {
          json({
            ok: true,
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: "feature/cli",
              branch: "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/recent") {
          json({
            sessions: [
              {
                id: "sess-recent",
                workspaceId: "ws-1",
                worktreeId: "main",
                status: "stopped",
                name: "Recent Demo",
              },
            ],
            serverNow: 2,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions") {
          json({
            workspaceId: "ws-1",
            sinceMs: Number(url.searchParams.get("sinceMs")),
            untilMs: Number(url.searchParams.get("untilMs")),
            serverNow: 2,
            active: [],
            stopped: [
              {
                id: "sess-1",
                workspaceId: "ws-1",
                worktreeId: "main",
                status: "stopped",
                name: "Demo",
              },
              {
                id: "/tmp/tui.jsonl",
                source: "tui",
                workspaceId: "ws-1",
                status: "stopped",
                name: "Terminal Demo",
                path: "/tmp/tui.jsonl",
                piSessionId: "pi-1",
              },
            ],
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
        if (method === "GET" && url.pathname === "/sessions/search") {
          json({
            query: url.searchParams.get("q"),
            totalResults: 1,
            results: [{ sessionId: "sess-1", text: "matched test output", score: 0.9 }],
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
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions/sess-1/resume") {
          json({ session: { id: "sess-1", workspaceId: "ws-1", status: "ready" } });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions/sess-1/fork") {
          json({
            session: { id: "sess-fork", workspaceId: "ws-1", status: "ready", name: body?.name },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/workspaces/ws-1/sessions/sess-1") {
          json({ ok: true, deleted: true });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/changes") {
          json({ files: [{ path: "server/src/cli.ts", status: "modified" }] });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/diff") {
          json({ path: url.searchParams.get("path"), hunks: [] });
          return;
        }
        if (
          method === "GET" &&
          url.pathname === "/workspaces/ws-1/sessions/sess-1/tool-output/tool-1"
        ) {
          json({ toolCallId: "tool-1", output: "hello" });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-page") {
          json({ entries: [], metrics: {} });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-outline") {
          json({ outline: [], metrics: {} });
          return;
        }
        if (method === "GET" && url.pathname === "/schedules") {
          json({
            schedules: [
              {
                id: "sch-1",
                status: "active",
                name: "Daily",
                action: {
                  type: "new_session",
                  workspaceId: "ws-1",
                  agentId: url.searchParams.get("agentId"),
                },
              },
            ],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/schedules") {
          json({ schedule: { id: "sch-created", status: "active", name: body?.name } });
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
    const workspaceDefinitionPath = join(cliDir, "workspace.json");
    const workspaceUpdatePath = join(cliDir, "workspace-update.json");
    const agentDefinitionPath = join(cliDir, "agent.json");
    const agentUpdatePath = join(cliDir, "agent-update.json");
    writeFileSync(definitionPath, JSON.stringify({ name: "Updated" }));
    writeFileSync(
      workspaceDefinitionPath,
      JSON.stringify({ description: "Created from JSON", defaultModel: "workspace-model" }),
    );
    writeFileSync(workspaceUpdatePath, JSON.stringify({ defaultModel: "updated-model" }));
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
          args: [
            "workspace",
            "create",
            "--name",
            "Created",
            "--host-mount",
            "/tmp/created",
            "--definition",
            workspaceDefinitionPath,
            "--json",
          ],
          expected: ["POST /workspaces"],
        },
        {
          args: [
            "workspace",
            "update",
            "ws-1",
            "--name",
            "Updated Oppi",
            "--definition",
            workspaceUpdatePath,
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "PUT /workspaces/ws-1"],
        },
        {
          args: ["workspace", "delete", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1", "DELETE /workspaces/ws-1"],
        },
        {
          args: ["worktree", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        {
          args: ["worktree", "get", "main", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        {
          args: [
            "worktree",
            "create",
            "--workspace",
            "ws-1",
            "--branch",
            "feature/cli",
            "--base",
            "main",
            "--json",
          ],
          expected: ["POST /workspaces/ws-1/worktrees"],
        },
        {
          args: ["worktree", "open", "--workspace", "ws-1", "--branch", "feature/cli", "--json"],
          expected: ["POST /workspaces/ws-1/worktrees/open"],
        },
        {
          args: ["worktree", "status", "wt_feature-cli-12345678", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees/wt_feature-cli-12345678/status"],
        },
        {
          args: [
            "worktree",
            "preview",
            "wt_feature-cli-12345678",
            "--workspace",
            "ws-1",
            "--into",
            "main",
            "--mode",
            "ff-only",
            "--json",
          ],
          expected: ["POST /workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview"],
        },
        {
          args: [
            "worktree",
            "remove",
            "wt_feature-cli-12345678",
            "--workspace",
            "ws-1",
            "--force",
            "--json",
          ],
          expected: ["DELETE /workspaces/ws-1/worktrees/wt_feature-cli-12345678?force=true"],
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
          args: ["session", "list", "--json"],
          expected: ["GET /sessions/recent?recentDays=3"],
        },
        {
          args: ["session", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/sessions?status=active%2Cstopped&sinceMs=*"],
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
          args: ["session", "search", "test output", "--limit", "5", "--json"],
          expected: ["GET /sessions/search?q=test+output&limit=5"],
        },
        {
          args: ["session", "resume", "sess-1", "--json"],
          expected: ["GET /sessions/sess-1", "POST /workspaces/ws-1/sessions/sess-1/resume"],
        },
        {
          args: ["session", "fork", "sess-1", "--entry", "entry-1", "--name", "Fork", "--json"],
          expected: ["GET /sessions/sess-1", "POST /workspaces/ws-1/sessions/sess-1/fork"],
        },
        {
          args: ["session", "delete", "sess-1", "--json"],
          expected: ["GET /sessions/sess-1", "DELETE /workspaces/ws-1/sessions/sess-1"],
        },
        {
          args: ["session", "changes", "sess-1", "--json"],
          expected: ["GET /sessions/sess-1", "GET /workspaces/ws-1/sessions/sess-1/changes"],
        },
        {
          args: ["session", "diff", "sess-1", "--path", "server/src/cli.ts", "--json"],
          expected: [
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/diff?path=server%2Fsrc%2Fcli.ts",
          ],
        },
        {
          args: ["session", "tool-output", "sess-1", "tool-1", "--json"],
          expected: [
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/tool-output/tool-1",
          ],
        },
        {
          args: ["session", "trace-page", "sess-1", "--target-events", "80", "--json"],
          expected: [
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/trace-page?targetEvents=80",
          ],
        },
        {
          args: ["session", "trace-outline", "sess-1", "--json"],
          expected: ["GET /sessions/sess-1", "GET /workspaces/ws-1/sessions/sess-1/trace-outline"],
        },
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
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "daily check",
            "--cron",
            "0 7 * * *",
            "--tz",
            "America/Los_Angeles",
            "--approval-ref",
            "approval://daily-check",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /schedules"],
        },
        {
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--agent",
            "agent-1",
            "--prompt",
            "agent daily check",
            "--every",
            "1d",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /schedules"],
        },
        {
          args: ["schedule", "list", "--agent", "agent-1", "--json"],
          expected: ["GET /schedules?agentId=agent-1"],
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
          if (expected.endsWith("*")) {
            expect(
              seen.some((request) => request.startsWith(expected.slice(0, -1))),
              testCase.args.join(" "),
            ).toBe(true);
          } else {
            expect(seen, testCase.args.join(" ")).toContain(expected);
          }
        }
      }

      const workspaceHuman = await runAsync(["workspace", "list"], { OPPI_DATA_DIR: cliDir });
      expect(workspaceHuman.exitCode).toBe(0);
      expect(workspaceHuman.stdout).toContain("Workspaces (1)");
      expect(workspaceHuman.stdout).toContain("ws-1");
      expect(workspaceHuman.stdout).toContain("Oppi");
      expect(workspaceHuman.stdout).not.toContain("| ID");
      expect(workspaceHuman.stdout).not.toMatch(/\x1b\[[0-9;]*m/);

      const sessionsHuman = await runAsync(["session", "list", "--workspace", "ws-1"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(sessionsHuman.exitCode).toBe(0);
      expect(sessionsHuman.stdout).toContain("Sessions (2)");
      expect(sessionsHuman.stdout).toContain("Terminal Demo");
      expect(sessionsHuman.stdout).not.toContain("source tui");
      expect(sessionsHuman.stdout).not.toContain("source oppi");
      expect(sessionsHuman.stdout).not.toContain("| ID");
      expect(sessionsHuman.stdout).not.toMatch(/\x1b\[[0-9;]*m/);

      const workspaceCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces",
      );
      expect(workspaceCreateRequest?.body).toMatchObject({
        name: "Created",
        description: "Created from JSON",
        hostMount: "/tmp/created",
        defaultModel: "workspace-model",
      });
      const workspaceUpdateRequest = requests.find(
        (request) => request.method === "PUT" && request.path === "/workspaces/ws-1",
      );
      expect(workspaceUpdateRequest?.body).toMatchObject({
        name: "Updated Oppi",
        defaultModel: "updated-model",
      });
      const forkRequest = requests.find(
        (request) =>
          request.method === "POST" && request.path === "/workspaces/ws-1/sessions/sess-1/fork",
      );
      expect(forkRequest?.body).toEqual({ entryId: "entry-1", name: "Fork" });
      const worktreeCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces/ws-1/worktrees",
      );
      expect(worktreeCreateRequest?.body).toEqual({ branch: "feature/cli", base: "main" });
      const worktreeOpenRequest = requests.find(
        (request) =>
          request.method === "POST" && request.path === "/workspaces/ws-1/worktrees/open",
      );
      expect(worktreeOpenRequest?.body).toEqual({ branch: "feature/cli" });
      const worktreePreviewRequest = requests.find(
        (request) =>
          request.method === "POST" &&
          request.path === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview",
      );
      expect(worktreePreviewRequest?.body).toEqual({ into: "main", mode: "ff-only" });

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
      const scheduleCreateRequests = requests.filter(
        (request) => request.method === "POST" && request.path === "/schedules",
      );
      expect(scheduleCreateRequests[0]?.body).toMatchObject({
        name: expect.any(String),
        trigger: { type: "cron", expression: "0 7 * * *", timeZone: "America/Los_Angeles" },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "daily check",
          approvalRefs: [expect.objectContaining({ id: "approval://daily-check" })],
        },
      });
      expect(scheduleCreateRequests[1]?.body).toMatchObject({
        trigger: { type: "every", intervalMs: 86_400_000 },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          agentId: "agent-1",
          prompt: "agent daily check",
        },
      });
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
