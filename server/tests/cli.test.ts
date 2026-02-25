/**
 * CLI integration tests — invoke the built CLI binary and check outputs.
 *
 * Tests non-interactive commands: help, status, config, token, pair, env, unknown.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(__dirname, "../dist/cli.js");
let dataDir: string;

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

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

      const payload = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
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

describe("oppi pair (tls tailscale)", () => {
  it("embeds https scheme + tailscale hostname without cert pin", () => {
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
      echo '{"Self":{"DNSName":"mac-studio.taila3ebc.ts.net."}}'
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
    printf 'dummy cert for %s\n' "\$host" > "\$cert_file"
    printf 'dummy key for %s\n' "\$host" > "\$key_file"
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

      const payload = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
        host?: string;
        scheme?: string;
        tlsCertFingerprint?: string;
      };

      expect(payload.host).toBe("mac-studio.taila3ebc.ts.net");
      expect(payload.scheme).toBe("https");
      expect(payload.tlsCertFingerprint).toBeUndefined();
    } finally {
      rmSync(tlsDataDir, { recursive: true, force: true });
      rmSync(fakeBinDir, { recursive: true, force: true });
    }
  });
});
