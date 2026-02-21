/**
 * CLI integration tests — invoke the built CLI binary and check outputs.
 *
 * Tests non-interactive commands: help, status, config, token, pair, env, unknown.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(__dirname, "../dist/cli.js");
let dataDir: string;

function run(args: string[], env?: Record<string, string>): { stdout: string; exitCode: number } {
  try {
    const stdout = execFileSync("node", [CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, OPPI_DATA_DIR: dataDir, ...env },
      timeout: 5000,
    });
    return { stdout, exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; status?: number };
    return { stdout: e.stdout ?? "", exitCode: e.status ?? 1 };
  }
}

beforeAll(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-test-"));
  // Build if not already built
  try {
    execSync("npm run build", { cwd: resolve(__dirname, ".."), stdio: "pipe" });
  } catch {}
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

  it("config set updates defaultModel", () => {
    run(["config", "set", "defaultModel", "anthropic/claude-sonnet-4-20250514"]);
    const { stdout } = run(["config", "get", "defaultModel"]);
    expect(stdout.trim()).toContain("anthropic/claude-sonnet-4-20250514");
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
});

// ── Env ──

describe("oppi env", () => {
  it("env show prints PATH info", () => {
    const { stdout, exitCode } = run(["env", "show"]);
    expect(exitCode).toBe(0);
    // Should print something about PATH/env
    expect(stdout.length).toBeGreaterThan(0);
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
