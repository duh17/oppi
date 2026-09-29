/**
 * Environment for tests that spawn the built CLI.
 *
 * `oppi init|pair|serve` on a host with undecided TLS probes `tailscale cert`,
 * which issues a real certificate on a machine that has Tailscale. The probe
 * looks up `tailscale` through the config's runtimePathEntries, so a PATH shim
 * cannot cover it; OPPI_TAILSCALE_BIN can. Take the CLI path and the spawn
 * environment from this module together so a new CLI test starts with a stopped
 * fake Tailscale instead of the host's.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const CLI = process.env.OPPI_TEST_CLI ?? resolve(__dirname, "../../dist/src/cli.js");

let stoppedBin: string | undefined;

/** A `tailscale` that fails every subcommand, `cert` included, and says why. */
function stoppedTailscaleBin(): string {
  if (!stoppedBin) {
    const dir = mkdtempSync(join(tmpdir(), "oppi-test-stopped-tailscale-"));
    mkdirSync(dir, { recursive: true });
    stoppedBin = join(dir, "tailscale");
    writeFileSync(
      stoppedBin,
      "#!/bin/sh\necho 'tailscale is stopped in tests (OPPI_TAILSCALE_BIN)' >&2\nexit 1\n",
      { mode: 0o755 },
    );
    process.once("exit", () => rmSync(dir, { recursive: true, force: true }));
  }
  return stoppedBin;
}

/** Point the CLI at a specific fake `tailscale` binary (also first on PATH). */
export function fakeTailscaleEnv(bin: string): Record<string, string> {
  return {
    PATH: `${dirname(bin)}:${process.env.PATH ?? ""}`,
    OPPI_TAILSCALE_BIN: bin,
  };
}

/** Process env for a CLI spawn: the host env plus a stopped fake Tailscale. */
export function cliSpawnEnv(env?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...process.env, OPPI_TAILSCALE_BIN: stoppedTailscaleBin(), ...env };
}
