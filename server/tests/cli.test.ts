/**
 * CLI integration tests — invoke the built CLI binary and check outputs.
 *
 * Tests non-interactive commands: help, status, config, token, pair, env, unknown.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFile, execFileSync, execSync, spawn } from "node:child_process";
import { X509Certificate } from "node:crypto";
import { createServer as createHttpServer } from "node:http";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from "node:net";
import { writeIrohInviteState } from "../src/iroh-invite-state.js";
import { Storage } from "../src/storage.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

const CLI = process.env.OPPI_TEST_CLI ?? resolve(__dirname, "../dist/src/cli.js");
let dataDir: string;

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function logSkip(unavailable: boolean, suite: string, reason: string): boolean {
  if (unavailable) console.warn(`[test] Skipping ${suite}: ${reason}`);
  return unavailable;
}

function run(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 15_000,
): { stdout: string; stderr: string; exitCode: number } {
  try {
    const stdout = execFileSync("node", [CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
      timeout: timeoutMs,
    });
    return { stdout, stderr: "", exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; status?: number };
    return {
      stdout: e.stdout ?? "",
      stderr: e.stderr ?? "",
      exitCode: e.status ?? 1,
    };
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

function generateDoctorCertificate(certPath: string, keyPath: string, dnsSan?: string): void {
  const sanArg = dnsSan ? ["-addext", `subjectAltName=DNS:${dnsSan}`] : [];
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      keyPath,
      "-out",
      certPath,
      "-days",
      "30",
      "-subj",
      `/CN=${dnsSan ?? "node.tail00000.ts.net"}`,
      ...sanArg,
    ],
    { stdio: "ignore" },
  );
}

function disconnectedTailscaleEnv(dir: string): Record<string, string> {
  const fakeBinDir = join(dir, "bin");
  mkdirSync(fakeBinDir, { recursive: true });
  writeFileSync(join(fakeBinDir, "tailscale"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  return { PATH: `${fakeBinDir}:${process.env.PATH ?? ""}` };
}

function fakeDateNodeOptions(dir: string, nowMs: number): string {
  const preloadPath = join(dir, `fake-date-${nowMs}.cjs`);
  writeFileSync(
    preloadPath,
    `const RealDate = Date;\n` +
      `const now = ${nowMs};\n` +
      `global.Date = class extends RealDate {\n` +
      `  constructor(...args) { super(...(args.length > 0 ? args : [now])); }\n` +
      `  static now() { return now; }\n` +
      `};\n`,
  );
  return `${process.env.NODE_OPTIONS ?? ""} --require ${preloadPath}`.trim();
}

async function runAsync(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 15_000,
  cwd?: string,
): Promise<{ stdout: string; exitCode: number }> {
  return await new Promise((resolveRun) => {
    execFile(
      "node",
      [CLI, ...args],
      {
        encoding: "utf-8",
        env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
        timeout: timeoutMs,
        ...(cwd ? { cwd } : {}),
      },
      (error, stdout) => {
        const exitCode =
          error && typeof error === "object" && "code" in error ? Number(error.code) : 0;
        resolveRun({ stdout, exitCode: Number.isFinite(exitCode) ? exitCode : 1 });
      },
    );
  });
}

async function runUntilOutput(
  args: string[],
  expected: string,
  env?: Record<string, string>,
  timeoutMs = 60_000,
): Promise<string> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn("node", [CLI, ...args], {
      env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let matched = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      rejectRun(new Error(`Timed out waiting for CLI output ${JSON.stringify(expected)}`));
    }, timeoutMs);

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
      if (!matched && stdout.includes(expected)) {
        matched = true;
        child.kill("SIGTERM");
      }
    });
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectRun(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (matched) {
        resolveRun(stdout);
      } else {
        rejectRun(new Error(`CLI exited with code ${code ?? "unknown"} before expected output`));
      }
    });
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
});

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
    expect(text).toContain("--agent <agent>");
    expect(text).not.toContain("--approval-ref");
    expect(text).not.toContain("Automatic runs fail closed");
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
    expect(text).toContain("--allow-nested-delegation");
    expect(text).toContain("one nested level");
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
      "inspect",
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
    expect(text).toContain("Inspect history progressively");
    expect(text).toContain("--view outline");
    expect(text).not.toContain("messages <id>");
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
      { args: ["update", "--help"], expected: ["Usage: oppi update", "npm-installed"] },
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
  }, 45_000);

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
        expected: [
          "Usage: oppi schedule update <id>",
          "--definition <file>",
          "--definition-json <json-object>",
          "--json",
        ],
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
        expected: [
          "Usage: oppi worktree create",
          "--branch <branch>",
          "OPPI_DATA_DIR",
          "Retained session history reserves its worktree id",
        ],
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
        expected: [
          "Usage: oppi worktree remove <worktree>",
          "--force",
          "active sessions",
          "Retained history reserves the removed worktree id",
        ],
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
        args: ["session", "inspect", "--help"],
        expected: [
          "Usage: oppi session inspect <id>",
          "--turns <spec>",
          "--view <view>",
          "compact outline",
          "messages/tools",
        ],
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
        expected: ["Usage: oppi session trace-outline <id>", "compact, jumpable event index"],
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
        expected: [
          "Usage: oppi agent create",
          "--definition <file>",
          "--definition-json <json-object>",
          "--name <name>",
        ],
      },
      {
        args: ["agent", "update", "--help"],
        expected: [
          "Usage: oppi agent update <agent>",
          "--definition <file>",
          "--definition-json <json-object>",
        ],
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
  }, 120_000);

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

  it("config set/get supports durable Iroh enablement", () => {
    run(["config", "set", "iroh.enabled", "true"]);
    expect(run(["config", "get", "iroh.enabled"]).stdout.trim()).toBe("true");
  });

  it("config set/get supports Oppi prompt toggles", () => {
    run(["config", "set", "oppiDocsPrompt.enabled", "false"]);
    expect(run(["config", "get", "oppiDocsPrompt.enabled"]).stdout.trim()).toBe("false");

    run(["config", "set", "oppiCliPrompt.enabled", "true"]);
    expect(run(["config", "get", "oppiCliPrompt.enabled"]).stdout.trim()).toBe("true");
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
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-cli-workspace-"));
    const worktreeRoot = mkdtempSync(join(tmpdir(), "oppi-cli-worktree-"));
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-app-control-"));
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
            workspaces: [{ id: "ws-1", name: "Oppi", hostMount: workspaceRoot }],
            summaries: [],
            serverNow: 1,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1") {
          json({ workspace: { id: "ws-1", name: "Oppi", hostMount: workspaceRoot } });
          return;
        }
        if (method === "GET" && url.pathname === "/models") {
          json({
            models: [
              {
                id: "openrouter/anthropic/claude-sonnet-4-20250514",
                name: "Claude Sonnet 4 via OpenRouter",
                provider: "openrouter",
                authKind: "apiKey",
              },
              {
                id: "anthropic/claude-sonnet-4-20250514",
                name: "Claude Sonnet 4",
                provider: "anthropic",
                authKind: "subscription",
              },
              {
                id: "openai/gpt-5.3-codex",
                name: "GPT-5.3 Codex",
                provider: "openai",
                authKind: "apiKey",
              },
            ],
          });
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
            worktrees: [
              { id: "main", name: "main", path: workspaceRoot },
              { id: "wt-feature", name: "feature", path: worktreeRoot },
            ],
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
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions") {
          json({
            session: {
              id: "sess-created",
              workspaceId: "ws-1",
              status: "ready",
              model: body?.model,
            },
            prompted: true,
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
            results: [{ sessionId: "sess-1", snippet: "matched test output", rank: 0.9 }],
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
        if (method === "GET" && url.pathname === "/sessions/sess-malformed/trace") {
          json({ session: { id: "sess-malformed", workspaceId: "ws-1", status: "stopped" } });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-leading/trace") {
          json({
            session: { id: "sess-leading", workspaceId: "ws-1", status: "stopped" },
            trace: [
              { type: "system", text: "Model: test-model" },
              { type: "compaction", text: "summary before prompt" },
              { type: "user", text: "first prompt" },
              { type: "assistant", text: "first answer" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-data-url/trace") {
          json({
            session: { id: "sess-data-url", workspaceId: "ws-1", status: "stopped" },
            trace: [
              {
                type: "user",
                text: "inspect this image\ndata:image/png;base64,QUJDREVGRw==",
              },
              { type: "assistant", text: "image inspected" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-trailing-user/trace") {
          json({
            session: { id: "sess-trailing-user", workspaceId: "ws-1", status: "stopped" },
            trace: [
              { type: "user", text: "first prompt" },
              { type: "assistant", text: "completed response" },
              { type: "user", text: "unanswered follow-up" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/trace") {
          const fullTrace = [
            { type: "user", text: "hello" },
            { type: "assistant", text: "trace" },
            { type: "toolCall", tool: "bash", args: { command: "false" } },
            { type: "toolResult", toolName: "bash", output: "failed", isError: true },
            { type: "system", text: "Model: test-model" },
          ];
          const include = url.searchParams.get("include")?.split(",") ?? [];
          const trace =
            include.length === 0
              ? fullTrace
              : fullTrace.filter((event) => {
                  if (include.includes("messages") && ["user", "assistant"].includes(event.type)) {
                    return true;
                  }
                  if (include.includes("thinking") && event.type === "thinking") return true;
                  if (
                    include.includes("tools") &&
                    ["toolCall", "toolResult"].includes(event.type)
                  ) {
                    return true;
                  }
                  if (include.includes("system") && event.type === "system") return true;
                  return false;
                });
          json({
            session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
            trace,
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
          json({
            outline: {
              traceVersion: "fixture",
              entries: [
                { id: "u1", kind: "user", summary: "hello" },
                { id: "a1", kind: "assistant", summary: "trace" },
                {
                  id: "tc-1",
                  kind: "tool",
                  tool: "bash",
                  summary: "$ false",
                  isError: true,
                },
                { id: "s1", kind: "system", summary: "Model: test-model" },
              ],
              itemCount: 4,
              sourceCount: 1,
              jsonlBytes: 500,
            },
            metrics: { rawEntryCount: 4 },
          });
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
    await listenOnLocalApiFixture(api, cliDir);
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

      const cases: Array<{ args: string[]; expected: string[]; exact?: boolean }> = [
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
        {
          args: [
            "agent",
            "create",
            "--definition-json",
            '{"name":"Inline Reviewer","description":"Inline create"}',
            "--json",
          ],
          expected: ["POST /agents"],
        },
        {
          args: [
            "agent",
            "update",
            "agent-1",
            "--definition-json",
            '{"description":"Inline update"}',
            "--json",
          ],
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
          args: [
            "session",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from model fuzz",
            "--model",
            "sonet",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "GET /models", "POST /workspaces/ws-1/sessions"],
        },
        {
          args: [
            "session",
            "start",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from start alias",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /workspaces/ws-1/sessions"],
        },
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
            "search",
            "test output",
            "--all",
            "--limit",
            "5",
            "--since",
            "2026-01-01",
            "--until",
            "2026-01-31",
            "--json",
          ],
          expected: [
            "GET /sessions/search?q=test+output&limit=5&since=2026-01-01&until=2026-01-31",
          ],
        },
        {
          args: ["session", "search", "--all", "--since", "2026-01-01", "--limit", "5", "--json"],
          expected: ["GET /sessions/search?limit=5&since=2026-01-01"],
        },
        {
          args: ["session", "inspect", "sess-1", "--turns", "all", "--view", "messages", "--json"],
          expected: ["GET /sessions/sess-1/trace"],
        },
        {
          args: ["session", "inspect", "sess-1", "--turn", "1", "--view", "messages", "--json"],
          expected: ["GET /sessions/sess-1/trace"],
        },
        {
          args: ["session", "inspect", "sess-1", "--view", "response", "--json"],
          expected: ["GET /sessions/sess-1/trace?include=messages"],
          exact: true,
        },
        {
          args: ["session", "inspect", "sess-1", "--json"],
          expected: ["GET /sessions/sess-1", "GET /workspaces/ws-1/sessions/sess-1/trace-outline"],
          exact: true,
        },
        {
          args: ["session", "inspect", "sess-1", "--view", "summary", "--json"],
          expected: ["GET /sessions/sess-1", "GET /workspaces/ws-1/sessions/sess-1/trace-outline"],
          exact: true,
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
          args: ["session", "diff", "sess-1", "--json", "--", "server/src/cli.ts"],
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
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "gpt daily check",
            "--every",
            "1d",
            "--model",
            "gpt codex",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "GET /models", "POST /schedules"],
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
          args: [
            "schedule",
            "update",
            "sch-1",
            "--definition-json",
            '{"name":"Inline schedule"}',
            "--json",
          ],
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
        expect(stdout, testCase.args.join(" ")).not.toBe("");
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
        if (testCase.exact) {
          expect(seen, testCase.args.join(" ")).toEqual(testCase.expected);
        }
      }

      const beforeBadModel = requests.length;
      const badModel = await runAsync(
        [
          "session",
          "create",
          "--workspace",
          "ws-1",
          "--prompt",
          "hello",
          "--model",
          "not-a-model",
          "--json",
        ],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(badModel.exitCode).toBe(1);
      expect(JSON.parse(badModel.stdout)).toEqual({
        ok: false,
        error: {
          message:
            'Model "not-a-model" is not available. Available models: openrouter/anthropic/claude-sonnet-4-20250514, anthropic/claude-sonnet-4-20250514, openai/gpt-5.3-codex',
          available_models: [
            "openrouter/anthropic/claude-sonnet-4-20250514",
            "anthropic/claude-sonnet-4-20250514",
            "openai/gpt-5.3-codex",
          ],
        },
      });
      const badModelSeen = requests
        .slice(beforeBadModel)
        .map((request) => `${request.method} ${request.path}`);
      expect(badModelSeen).toEqual(["GET /workspaces/ws-1", "GET /models"]);

      const beforeInferredSearch = requests.length;
      const inferredSearch = await runAsync(
        ["session", "search", "test output", "--limit", "5", "--json"],
        { OPPI_DATA_DIR: cliDir },
        15_000,
        workspaceRoot,
      );
      expect(inferredSearch.exitCode).toBe(0);
      expect(JSON.parse(inferredSearch.stdout)).toMatchObject({ ok: true });
      const inferredSeen = requests
        .slice(beforeInferredSearch)
        .map((request) => `${request.method} ${request.path}`);
      expect(inferredSeen).toContain("GET /workspaces");
      expect(inferredSeen).toContain("GET /sessions/search?q=test+output&limit=5&workspaceId=ws-1");

      const beforeWorktreeInferredSearch = requests.length;
      const worktreeInferredSearch = await runAsync(
        ["session", "search", "test output", "--limit", "5", "--json"],
        { OPPI_DATA_DIR: cliDir },
        15_000,
        worktreeRoot,
      );
      expect(worktreeInferredSearch.exitCode).toBe(0);
      expect(JSON.parse(worktreeInferredSearch.stdout)).toMatchObject({ ok: true });
      const worktreeInferredSeen = requests
        .slice(beforeWorktreeInferredSearch)
        .map((request) => `${request.method} ${request.path}`);
      expect(worktreeInferredSeen).toContain("GET /workspaces/ws-1/worktrees");
      expect(worktreeInferredSeen).toContain(
        "GET /sessions/search?q=test+output&limit=5&workspaceId=ws-1",
      );

      const unscopedSearch = await runAsync(["session", "search", "test output", "--json"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(unscopedSearch.exitCode).toBe(1);
      expect(JSON.parse(unscopedSearch.stdout)).toMatchObject({
        ok: false,
        error: { message: "Could not infer workspace from cwd; pass --workspace or --all" },
      });

      const responseJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "response", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(responseJson.exitCode).toBe(0);
      expect(JSON.parse(responseJson.stdout)).toMatchObject({
        ok: true,
        data: {
          selected_turns: [1],
          view: "response",
          text: "trace",
        },
      });

      const responseHuman = await runAsync(["session", "inspect", "sess-1", "--view", "response"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(responseHuman.exitCode).toBe(0);
      expect(responseHuman.stdout.trim()).toBe("trace");

      const trailingResponse = await runAsync(
        ["session", "inspect", "sess-trailing-user", "--view", "response", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(trailingResponse.exitCode).toBe(0);
      expect(JSON.parse(trailingResponse.stdout)).toMatchObject({
        ok: true,
        data: {
          selected_turns: [1, 2],
          view: "response",
          text: "completed response",
        },
      });

      const inspectJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(inspectJson.exitCode).toBe(0);
      const inspectEnvelope = JSON.parse(inspectJson.stdout) as {
        data?: {
          summary?: { counts?: { toolCalls?: number; toolErrors?: number } };
          text?: string;
        };
      };
      expect(inspectEnvelope.data?.summary?.counts?.toolCalls).toBe(1);
      expect(inspectEnvelope.data?.summary?.counts?.toolErrors).toBe(1);
      expect(inspectEnvelope.data?.text).toContain("assistant: trace");
      expect(inspectEnvelope.data?.text).not.toContain("failed");

      const inspectOutlineJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "outline", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(inspectOutlineJson.exitCode).toBe(0);
      const inspectOutlineEnvelope = JSON.parse(inspectOutlineJson.stdout) as {
        data?: { selected_turns?: number[]; text?: string };
      };
      expect(inspectOutlineEnvelope.data?.selected_turns).toEqual([1]);
      expect(inspectOutlineEnvelope.data?.text).toContain("Turn 1");
      expect(inspectOutlineEnvelope.data?.text).toContain("user: hello");
      expect(inspectOutlineEnvelope.data?.text).toContain("assistant: trace");
      expect(inspectOutlineEnvelope.data?.text).toContain("activity: 1 tool call · 1 error");
      expect(inspectOutlineEnvelope.data?.text).not.toContain("failed");

      const leadingInspectJson = await runAsync(
        ["session", "inspect", "sess-leading", "--turns", "1", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(leadingInspectJson.exitCode, leadingInspectJson.stdout).toBe(0);
      const leadingInspectEnvelope = JSON.parse(leadingInspectJson.stdout) as {
        data?: {
          selected_turns?: number[];
          summary?: { counts?: { turns?: number } };
          text?: string;
        };
      };
      expect(leadingInspectEnvelope.data?.selected_turns).toEqual([1]);
      expect(leadingInspectEnvelope.data?.summary?.counts?.turns).toBe(1);
      expect(leadingInspectEnvelope.data?.text).toContain("summary: summary before prompt");
      expect(leadingInspectEnvelope.data?.text).toContain("system: Model: test-model");
      expect(leadingInspectEnvelope.data?.text).toContain("user: first prompt");

      const dataUrlInspectJson = await runAsync(
        ["session", "inspect", "sess-data-url", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(dataUrlInspectJson.exitCode).toBe(0);
      const dataUrlInspectEnvelope = JSON.parse(dataUrlInspectJson.stdout) as {
        data?: { text?: string };
      };
      expect(dataUrlInspectEnvelope.data?.text).toContain("[inline image/png data omitted]");
      expect(dataUrlInspectEnvelope.data?.text).not.toContain("QUJDREVGRw==");

      for (const turns of ["1abc", "1-2x", "0", "2", "1-2", "2-1", "1,,1"]) {
        const invalidInspectTurns = await runAsync(
          ["session", "inspect", "sess-1", "--turns", turns, "--json"],
          { OPPI_DATA_DIR: cliDir },
        );
        expect(invalidInspectTurns.exitCode, turns).toBe(1);
        expect(JSON.parse(invalidInspectTurns.stdout), turns).toMatchObject({
          ok: false,
          error: { message: "--turns must be all, a number, a range, or a comma-separated list" },
        });
      }

      const malformedInspect = await runAsync(
        ["session", "inspect", "sess-malformed", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(malformedInspect.exitCode).toBe(1);
      expect(JSON.parse(malformedInspect.stdout)).toMatchObject({
        ok: false,
        error: { message: "Local API did not return a trace array" },
      });

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
      const sessionCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces/ws-1/sessions",
      );
      expect(sessionCreateRequest?.body).toMatchObject({
        prompt: "hello from model fuzz",
        model: "anthropic/claude-sonnet-4-20250514",
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
      expect(
        requests.find(
          (request) =>
            request.method === "POST" &&
            request.path === "/agents" &&
            (request.body as { name?: string }).name === "Inline Reviewer",
        )?.body,
      ).toEqual({ name: "Inline Reviewer", description: "Inline create" });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/agents/agent-1" &&
            (request.body as { description?: string }).description === "Inline update",
        )?.body,
      ).toEqual({ description: "Inline update" });
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
      expect(scheduleCreateRequests[2]?.body).toMatchObject({
        trigger: { type: "every", intervalMs: 86_400_000 },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "gpt daily check",
          model: "openai/gpt-5.3-codex",
        },
      });
      const updateRequest = requests.find(
        (request) => request.method === "PATCH" && request.path === "/schedules/sch-1",
      );
      expect(updateRequest?.body).toEqual({ name: "Updated" });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/schedules/sch-1" &&
            (request.body as { name?: string }).name === "Inline schedule",
        )?.body,
      ).toEqual({ name: "Inline schedule" });

      for (const testCase of [
        {
          args: [
            "agent",
            "update",
            "agent-1",
            "--definition",
            agentUpdatePath,
            "--definition-json",
            '{"description":"duplicate"}',
            "--json",
          ],
          message: "exactly one of --definition or --definition-json is required",
        },
        {
          args: ["agent", "update", "agent-1", "--definition-json", "not-json", "--json"],
          message: "--definition-json must be valid JSON",
        },
        {
          args: ["agent", "update", "agent-1", "--definition-json", "[]", "--json"],
          message: "definition must be a JSON object",
        },
        {
          args: ["schedule", "update", "sch-1", "--definition-json", "{}", "--json"],
          message: "definition update must not be empty",
        },
        {
          args: [
            "schedule",
            "update",
            "sch-1",
            "--definition-json",
            JSON.stringify({ name: "x".repeat(65_536) }),
            "--json",
          ],
          message: "--definition-json exceeds maximum size of 65536 bytes",
        },
      ]) {
        const before = requests.length;
        const result = await runAsync(testCase.args, { OPPI_DATA_DIR: cliDir });
        expect(result.exitCode, testCase.args.slice(0, 3).join(" ")).toBe(1);
        expect(JSON.parse(result.stdout).error.message).toContain(testCase.message);
        expect(requests).toHaveLength(before);
      }
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
      rmSync(worktreeRoot, { recursive: true, force: true });
    }
  }, 180_000);

  it("keeps concurrent read-only local API CLI calls from failing on SQLite locks", async () => {
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-concurrent-read-"));
    const api = createHttpServer((req, res) => {
      if (req.method === "GET" && req.url === "/workspaces") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ workspaces: [], summaries: [], serverNow: 1 }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: `${req.method ?? "GET"} ${req.url ?? "/"} not handled` }));
    });
    await listenOnLocalApiFixture(api, cliDir);

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);

      const results = await Promise.all(
        Array.from({ length: 10 }, () =>
          runAsync(["workspace", "list", "--json"], { OPPI_DATA_DIR: cliDir }),
        ),
      );
      const failures = results
        .map((result, index) => ({ index, ...result }))
        .filter((result) => result.exitCode !== 0);

      expect(failures).toEqual([]);
      for (const result of results) {
        expect(JSON.parse(result.stdout)).toMatchObject({ ok: true });
      }
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("schedule list --json fails fast on malformed successful API JSON", async () => {
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-local-api-"));
    const api = createHttpServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("not-json");
    });
    await listenOnLocalApiFixture(api, cliDir);

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
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

// ── Local orchestration authorization ──

describe("local orchestration prerequisites", () => {
  it("requires local owner credentials before calling orchestration APIs", () => {
    const freshDir = mkdtempSync(join(tmpdir(), "oppi-cli-no-owner-"));
    try {
      const { stdout, exitCode } = run(["workspace", "list", "--json"], {
        OPPI_DATA_DIR: freshDir,
      });
      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toEqual({
        ok: false,
        error: {
          message: "No owner bearer token configured. Run 'oppi init' or 'oppi pair' first.",
        },
      });
    } finally {
      rmSync(freshDir, { recursive: true, force: true });
    }
  });

  it("requires a running local server after setup", async () => {
    const configuredDir = mkdtempSync(join(tmpdir(), "oppi-cli-server-required-"));
    const port = await getFreePort();
    try {
      expect(run(["init", "--yes", "--data-dir", configuredDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], {
          OPPI_DATA_DIR: configuredDir,
        }).exitCode,
      ).toBe(0);
      expect(
        run(["config", "set", "port", String(port)], { OPPI_DATA_DIR: configuredDir }).exitCode,
      ).toBe(0);

      const { stdout, exitCode } = await runAsync(["workspace", "list", "--json"], {
        OPPI_DATA_DIR: configuredDir,
      });
      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout).error.message).toMatch(/ECONNREFUSED|connect/i);
    } finally {
      rmSync(configuredDir, { recursive: true, force: true });
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

describe("oppi pair persisted Iroh policy", () => {
  function preparePersistedPolicy(
    mode: "irohOnly" | "irohPreferred" | "httpOnly",
    state: "ready" | "missing" | "stale",
  ): string {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-iroh-policy-"));
    const storage = new Storage(dir);
    const readinessId = `readiness-${mode}`;
    storage.updateConfig({
      host: "127.0.0.1",
      port: 7749,
      tls: { mode: "disabled" },
      irohInviteMode: mode,
      irohInviteReadinessId: mode === "httpOnly" ? undefined : readinessId,
    });
    storage.ensurePaired();
    if (state !== "missing") {
      writeIrohInviteState(dir, {
        version: 2,
        nodeId: `node-${mode}`,
        alpns: ["oppi/pair/1", "oppi/http/1"],
        addressMode: "ticket",
        ticket: `ticket-${mode}`,
        readinessId,
        processId: state === "ready" ? process.pid : 2_147_483_647,
      });
    }
    return dir;
  }

  const plainPairEnv = (dir: string): Record<string, string> => ({
    OPPI_DATA_DIR: dir,
    OPPI_IROH_PAIRING: "0",
    OPPI_IROH_TRANSPORT: "0",
    OPPI_IROH_INVITE_MODE: "",
  });

  it("keeps plain pair Iroh-only when durable Iroh activation is also enabled", () => {
    const dir = preparePersistedPolicy("irohOnly", "ready");
    try {
      new Storage(dir).updateConfig({ iroh: { enabled: true } });
      const { stdout, exitCode } = run(["pair", "--json"], plainPairEnv(dir));
      expect(exitCode).toBe(0);
      const invite = JSON.parse(stdout) as Record<string, unknown>;
      expect(invite.preference).toBe("irohOnly");
      expect(invite.transports).toMatchObject({ iroh: { nodeId: "node-irohOnly" } });
      expect(invite).not.toHaveProperty("host");
      expect(invite).not.toHaveProperty("port");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it.each(["missing", "stale"] as const)(
    "errors instead of downgrading persisted Iroh-only when readiness is %s",
    (state) => {
      const dir = preparePersistedPolicy("irohOnly", state);
      try {
        const { stderr, exitCode } = run(["pair", "--json"], plainPairEnv(dir));
        expect(exitCode).toBe(1);
        expect(stderr).toContain("Iroh-only pairing is unavailable");
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );

  it("preserves preferred invites with HTTP and plain HTTP mode", () => {
    const preferredDir = preparePersistedPolicy("irohPreferred", "ready");
    const httpDir = preparePersistedPolicy("httpOnly", "missing");
    try {
      const preferredResult = run(
        ["pair", "--host", "127.0.0.1", "--json"],
        plainPairEnv(preferredDir),
      );
      expect(preferredResult.exitCode).toBe(0);
      const preferred = JSON.parse(preferredResult.stdout) as Record<string, unknown>;
      expect(preferred.preference).toBe("irohPreferred");
      expect(preferred).toMatchObject({ host: "127.0.0.1", scheme: "http" });
      expect(preferred.transports).toMatchObject({
        iroh: { nodeId: "node-irohPreferred" },
        http: { host: "127.0.0.1" },
      });

      const httpResult = run(["pair", "--host", "127.0.0.1", "--json"], plainPairEnv(httpDir));
      expect(httpResult.exitCode).toBe(0);
      const http = JSON.parse(httpResult.stdout) as Record<string, unknown>;
      expect(http).toMatchObject({ host: "127.0.0.1", scheme: "http" });
      expect(http).not.toHaveProperty("preference");
      expect(http).not.toHaveProperty("transports");
    } finally {
      rmSync(preferredDir, { recursive: true, force: true });
      rmSync(httpDir, { recursive: true, force: true });
    }
  });
});

describe.skipIf(
  logSkip(!hasOpenSSL, "oppi pair (tls self-signed)", "openssl executable is unavailable"),
)("oppi pair (tls self-signed)", () => {
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

describe.skipIf(
  logSkip(!hasOpenSSL, "oppi pair (tls tailscale)", "openssl executable is unavailable"),
)("oppi pair (tls tailscale)", () => {
  it("uses a Tailnet SAN for pairing and recovers it after Tailscale stops", () => {
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
      -addext "subjectAltName=DNS:\$host" \\
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

      // The live daemon is no longer discoverable. Pairing must recover the
      // hostname from the existing valid leaf SAN and must not need renewal.
      writeFileSync(fakeTailscalePath, "#!/usr/bin/env bash\nexit 1\n", { mode: 0o755 });
      const stoppedResult = run(["pair", "--json"], env);
      expect(stoppedResult.exitCode).toBe(0);
      const stoppedInvite = JSON.parse(stoppedResult.stdout) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };
      expect(stoppedInvite.host).toBe("my-server.tail00000.ts.net");
      expect(stoppedInvite.scheme).toBe("https");
      expect(stoppedInvite.tlsCertFingerprint).toBeUndefined();
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

      // `serve` is long-running; stop it once startup reaches the invite output.
      const serveStdout = await runUntilOutput(
        ["serve"],
        "oppi://connect?",
        { OPPI_DATA_DIR: serveDir },
        60_000,
      );

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
  }, 90_000);
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
  }, 30_000);

  describe.skipIf(
    logSkip(!hasOpenSSL, "oppi doctor (tailscale)", "openssl executable is unavailable"),
  )("Tailscale material", () => {
    function setupDoctorDir(options: { dnsSan?: string; malformed?: boolean } = {}): {
      doctorDir: string;
      certPath: string;
      keyPath: string;
      env: Record<string, string>;
    } {
      const doctorDir = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-tailscale-"));
      expect(run(["init", "--yes", "--data-dir", doctorDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"tailscale"}'], {
          OPPI_DATA_DIR: doctorDir,
        }).exitCode,
      ).toBe(0);
      const tlsDir = join(doctorDir, "tls", "tailscale");
      const certPath = join(tlsDir, "server.crt");
      const keyPath = join(tlsDir, "server.key");
      mkdirSync(tlsDir, { recursive: true });
      if (options.malformed) {
        writeFileSync(certPath, "not a certificate");
        writeFileSync(keyPath, "not a key");
      } else {
        generateDoctorCertificate(certPath, keyPath, options.dnsSan);
      }
      return { doctorDir, certPath, keyPath, env: disconnectedTailscaleEnv(doctorDir) };
    }

    it("warns but passes while disconnected when the cert/key are locally valid", () => {
      const fixture = setupDoctorDir({ dnsSan: "node.tail00000.ts.net" });
      try {
        const { stdout, exitCode } = run(["doctor"], {
          OPPI_DATA_DIR: fixture.doctorDir,
          ...fixture.env,
        });
        expect(exitCode).toBe(0);
        expect(stripAnsi(stdout)).toContain("Tailscale is not connected");
        expect(stripAnsi(stdout)).toContain("public trust is enforced by TLS clients");
      } finally {
        rmSync(fixture.doctorDir, { recursive: true, force: true });
      }
    });

    it.each([
      ["missing", "missing"],
      ["malformed", "malformed"],
      ["without a Tailnet SAN", "no-san"],
      ["with a mismatched key", "mismatch"],
    ])("fails for %s offline Tailscale material", (_label, failure) => {
      const fixture = setupDoctorDir({
        dnsSan: failure === "no-san" ? undefined : "node.tail00000.ts.net",
        malformed: failure === "malformed",
      });
      try {
        if (failure === "missing") {
          rmSync(fixture.certPath, { force: true });
          rmSync(fixture.keyPath, { force: true });
        } else if (failure === "mismatch") {
          generateDoctorCertificate(
            join(fixture.doctorDir, "replacement.crt"),
            fixture.keyPath,
            "node.tail00000.ts.net",
          );
        }
        const { stdout, exitCode } = run(["doctor"], {
          OPPI_DATA_DIR: fixture.doctorDir,
          ...fixture.env,
        });
        expect(exitCode).toBe(1);
        expect(stripAnsi(stdout)).toContain("Tailscale TLS material is unusable");
      } finally {
        rmSync(fixture.doctorDir, { recursive: true, force: true });
      }
    });

    it.each([
      ["expired", "expired"],
      ["not yet valid", "future"],
    ])("fails when offline Tailscale material is %s", (_label, validity) => {
      const fixture = setupDoctorDir({ dnsSan: "node.tail00000.ts.net" });
      try {
        const cert = new X509Certificate(readFileSync(fixture.certPath));
        const nowMs =
          validity === "expired" ? Date.parse(cert.validTo) + 1 : Date.parse(cert.validFrom) - 1;
        const { stdout, exitCode } = run(["doctor"], {
          OPPI_DATA_DIR: fixture.doctorDir,
          ...fixture.env,
          NODE_OPTIONS: fakeDateNodeOptions(fixture.doctorDir, nowMs),
        });
        expect(exitCode).toBe(1);
        expect(stripAnsi(stdout)).toContain(
          validity === "expired" ? "certificate is expired" : "certificate is not yet valid",
        );
      } finally {
        rmSync(fixture.doctorDir, { recursive: true, force: true });
      }
    });
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
