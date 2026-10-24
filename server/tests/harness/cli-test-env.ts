/**
 * Shared environment for the CLI integration tests (`cli-*.test.ts`).
 *
 * Each test file calls `useCliDataDir()` once at the top level; it gives that file its
 * own temp OPPI_DATA_DIR (created before, removed after the file's tests). `dataDir` is
 * a live binding to that directory. Vitest isolates module state per test file, so
 * files running in parallel workers never share it.
 */
import { afterAll, beforeAll } from "vitest";
import { execFile, execFileSync, execSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";
import { OPPI_CALLER_SESSION_ID_ENV } from "../../src/session-caller-identity.js";
import { Storage } from "../../src/storage.js";
import { CLI, cliSpawnEnv, fakeTailscaleEnv } from "./cli-process.js";

export let dataDir: string;

export function useCliDataDir(): void {
  beforeAll(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-test-"));
  });

  afterAll(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });
}

// cliSpawnEnv starts every CLI run on a stopped fake Tailscale, so first-run
// `serve`/`pair`/`init` never reach the host's real one.
export function cliProcessEnv(env?: Record<string, string>): NodeJS.ProcessEnv {
  const next: NodeJS.ProcessEnv = {
    ...cliSpawnEnv(),
    OPPI_DATA_DIR: dataDir,
    ...env,
  };
  if (env?.[OPPI_CALLER_SESSION_ID_ENV] === undefined) {
    delete next[OPPI_CALLER_SESSION_ID_ENV];
  }
  return next;
}

export let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

export function logSkip(unavailable: boolean, suite: string, reason: string): boolean {
  if (unavailable) console.warn(`[test] Skipping ${suite}: ${reason}`);
  return unavailable;
}

export function run(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 15_000,
): { stdout: string; stderr: string; exitCode: number } {
  try {
    const stdout = execFileSync("node", [CLI, ...args], {
      encoding: "utf-8",
      env: cliProcessEnv(env),
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

export function runBin(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 15_000,
): { stdout: string; exitCode: number } {
  try {
    const stdout = execFileSync(CLI, args, {
      encoding: "utf-8",
      env: cliProcessEnv(env),
      timeout: timeoutMs,
    });
    return { stdout, exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; status?: number };
    return { stdout: e.stdout ?? "", exitCode: e.status ?? 1 };
  }
}

/**
 * Makes the spawned CLI see a terminal on stdout. `oppi serve` prints a pairing invite
 * only in a terminal, and the test pipes stdout.
 */
export const TERMINAL_STDOUT_ENV: Record<string, string> = {
  NODE_OPTIONS:
    "--import=data:text/javascript,Object.defineProperty(process.stdout,'isTTY',{value:true})",
};

export function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

export function generateDoctorCertificate(
  certPath: string,
  keyPath: string,
  dnsSan?: string,
): void {
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

export function disconnectedTailscaleEnv(dir: string): Record<string, string> {
  const fakeBinDir = join(dir, "bin");
  mkdirSync(fakeBinDir, { recursive: true });
  const bin = join(fakeBinDir, "tailscale");
  writeFileSync(bin, "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  return fakeTailscaleEnv(bin);
}

/**
 * Fake `tailscale` that reports a connected tailnet node. With `certFixture`,
 * `tailscale cert` installs that cert/key pair; without it, issuance fails the
 * way it does when tailnet HTTPS certificates are disabled.
 */
export function connectedTailscaleEnv(
  dir: string,
  dnsName: string,
  certFixture?: { certPath: string; keyPath: string },
  /** Slow issuance: touch `markerPath` when `cert` starts, then wait before installing. */
  slowCert?: { markerPath: string; seconds: number },
): Record<string, string> {
  const fakeBinDir = join(dir, "bin");
  mkdirSync(fakeBinDir, { recursive: true });
  const slowCommand = slowCert
    ? `  touch '${slowCert.markerPath}'\n  sleep ${slowCert.seconds}\n`
    : "";
  const certCommand = certFixture
    ? slowCommand +
      `  while [ $# -gt 0 ]; do\n` +
      `    case "$1" in\n` +
      `      --cert-file) cp '${certFixture.certPath}' "$2"; shift 2 ;;\n` +
      `      --key-file) cp '${certFixture.keyPath}' "$2"; shift 2 ;;\n` +
      `      *) shift ;;\n` +
      `    esac\n` +
      `  done\n` +
      `  exit 0\n`
    : `  echo 'your Tailscale account does not support getting TLS certs' >&2\n  exit 1\n`;
  writeFileSync(
    join(fakeBinDir, "tailscale"),
    `#!/bin/sh\n` +
      `if [ "$1" = "status" ]; then\n` +
      `  printf '%s\\n' '{"Self":{"DNSName":"${dnsName}."}}'\n` +
      `  exit 0\n` +
      `fi\n` +
      `if [ "$1" = "ip" ]; then\n` +
      `  echo 100.64.0.1\n` +
      `  exit 0\n` +
      `fi\n` +
      `if [ "$1" = "cert" ]; then\n` +
      `  shift\n` +
      certCommand +
      `fi\n` +
      `exit 1\n`,
    { mode: 0o755 },
  );
  return fakeTailscaleEnv(join(fakeBinDir, "tailscale"));
}

export function fakeDateNodeOptions(dir: string, nowMs: number): string {
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

export async function runAsync(
  args: string[],
  env?: Record<string, string>,
  timeoutMs = 15_000,
  cwd?: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return await new Promise((resolveRun) => {
    execFile(
      "node",
      [CLI, ...args],
      {
        encoding: "utf-8",
        env: cliProcessEnv(env),
        timeout: timeoutMs,
        ...(cwd ? { cwd } : {}),
      },
      (error, stdout, stderr) => {
        const exitCode =
          error && typeof error === "object" && "code" in error ? Number(error.code) : 0;
        resolveRun({ stdout, stderr, exitCode: Number.isFinite(exitCode) ? exitCode : 1 });
      },
    );
  });
}

export async function runUntilOutput(
  args: string[],
  expected: string,
  env?: Record<string, string>,
  timeoutMs = 60_000,
): Promise<string> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn("node", [CLI, ...args], {
      env: cliProcessEnv(env),
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

/**
 * Just enough host state for a CLI command that talks to the local API: an owner token and TLS
 * disabled. It is not a full `oppi init` (no identity keys, no init defaults). Written through
 * Storage so a test that only exercises one later command spends a single CLI spawn instead of
 * one per setup step.
 */
export function seedConfiguredHost(dir: string): void {
  const storage = new Storage(dir);
  storage.rotateToken();
  storage.updateConfig({ tls: { mode: "disabled" } });
}

export async function getFreePort(): Promise<number> {
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
