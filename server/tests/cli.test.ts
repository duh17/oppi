/**
 * CLI integration tests — invoke the built CLI binary and check outputs.
 *
 * Tests non-interactive commands: help, status, config, token, pair, env, unknown.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync, execSync } from "node:child_process";
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
