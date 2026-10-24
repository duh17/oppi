/**
 * CLI integration tests: what a first-time user sees from `serve`, `status`, and `doctor`.
 *
 * An owner token only means setup ran. A host is paired once a device has enrolled, so a
 * host whose first invite expired unused must keep offering a fresh one.
 */
import { execFileSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { CLI } from "./harness/cli-process.js";
import {
  getFreePort,
  hasOpenSSL,
  logSkip,
  run,
  runUntilOutput,
  stripAnsi,
  useCliDataDir,
} from "./harness/cli-test-env.js";

useCliDataDir();

/** A loopback host with TLS already chosen, so `serve` reaches the pairing output offline. */
async function prepareHost(dir: string): Promise<Record<string, string>> {
  const env = { OPPI_DATA_DIR: dir };
  for (const [key, value] of [
    ["port", String(await getFreePort())],
    ["host", "127.0.0.1"],
    ["tls", '{"mode":"self-signed"}'],
  ] as const) {
    expect(run(["config", "set", key, value], env).exitCode).toBe(0);
  }
  return env;
}

function enrollDevice(dir: string): void {
  const storage = new Storage(dir);
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const enrollment = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: publicKey.export({ format: "jwk" }),
    name: "Phone",
  });
  if (!enrollment) throw new Error("pairing failed");
}

function pairedFromStatus(env: Record<string, string>): boolean {
  const { stdout, exitCode } = run(["status", "--json"], env);
  expect(exitCode).toBe(0);
  return (JSON.parse(stdout) as { data: { status: { paired: boolean } } }).data.status.paired;
}

describe.skipIf(logSkip(!hasOpenSSL, "cli-first-run serve", "openssl is not available"))(
  "serve on a host with an owner token",
  () => {
    it("keeps offering an invite until a device has enrolled", async () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-cli-first-run-token-"));
      try {
        const env = await prepareHost(dir);
        new Storage(dir).ensurePaired();
        expect(pairedFromStatus(env)).toBe(false);

        const out = stripAnsi(await runUntilOutput(["serve"], "oppi server install", env, 60_000));
        expect(out).toContain("oppi://connect?");
        expect(out).not.toContain("✓ Paired");
        expect(out).toContain("Keep this terminal open while you pair");
        expect(out).toContain("oppi pair");
        expect(out).not.toContain("then Ctrl+C when done");
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }, 90_000);

    it("reports paired and prints no invite once a device has enrolled", async () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-cli-first-run-paired-"));
      try {
        const env = await prepareHost(dir);
        new Storage(dir).ensurePaired();
        enrollDevice(dir);
        expect(pairedFromStatus(env)).toBe(true);

        const out = stripAnsi(
          await runUntilOutput(["serve"], "Waiting for connections...", env, 60_000),
        );
        expect(out).toContain("✓ Paired");
        expect(out).not.toContain("oppi://connect?");
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }, 90_000);
  },
);

describe("doctor model providers", () => {
  /** A bare environment: no host API keys, an empty Pi agent dir, an empty HOME. */
  function doctor(extraEnv: Record<string, string>): string {
    const root = mkdtempSync(join(tmpdir(), "oppi-cli-doctor-providers-"));
    try {
      const agentDir = join(root, "agent");
      mkdirSync(agentDir);
      try {
        return stripAnsi(
          execFileSync("node", [CLI, "doctor"], {
            encoding: "utf-8",
            env: {
              PATH: process.env.PATH ?? "",
              HOME: root,
              OPPI_DATA_DIR: join(root, "data"),
              PI_CODING_AGENT_DIR: agentDir,
              ...extraEnv,
            },
            timeout: 30_000,
          }),
        );
      } catch (err: unknown) {
        // A fresh host fails other checks and exits non-zero; the provider line still prints.
        return stripAnsi((err as { stdout?: string }).stdout ?? "");
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }

  it("tells the user how to connect a provider when none has credentials", () => {
    const out = doctor({});
    expect(out).toContain("no model provider has credentials");
    expect(out).toContain("Model Providers");
    expect(out).not.toContain("pi auth");
  });

  it("names the provider a standard API key variable enables", () => {
    const out = doctor({ ANTHROPIC_API_KEY: "sk-ant-doctor-test" });
    expect(out).toContain("model providers with credentials:");
    expect(out).toContain("anthropic");
    expect(out).not.toContain("no model provider has credentials");
  });
});
