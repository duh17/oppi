import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const wrapper = join(import.meta.dir, "sim-pool-personal-forward.sh");

function writeProbe(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env bash
set -euo pipefail
printf 'COUNT=%s KEEP=%s FORCE=%s ROOT=%s ARGS=%s\n' \\
  "\${OPPI_SIM_POOL_COUNT-unset}" \\
  "\${OPPI_SIM_POOL_KEEP_BOOTED-unset}" \\
  "\${OPPI_SIM_POOL_FORCE_CLEAN_BOOT-unset}" \\
  "\${OPPI_ROOT-unset}" \\
  "$*"
`,
    { mode: 0o755 },
  );
  chmodSync(path, 0o755);
}

describe("personal forwarding wrapper", () => {
  test("forwards argv to OPPI_SIM_POOL_REPO and does not set old personal defaults", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-sim-cutover-"));
    try {
      const probe = join(dir, "probe.sh");
      writeProbe(probe);
      const result = spawnSync("bash", [wrapper, "run", "--", "xcodebuild", "build"], {
        env: { ...process.env, OPPI_SIM_POOL_REPO: probe },
        encoding: "utf8",
      });
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("COUNT=unset");
      expect(result.stdout).toContain("KEEP=unset");
      expect(result.stdout).toContain("ARGS=run -- xcodebuild build");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("auto-detects the checkout sim-pool.sh from git root", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-sim-cutover-git-"));
    try {
      spawnSync("git", ["init", "-q", root]);
      const runner = join(root, "clients", "apple", "scripts", "sim-pool.sh");
      mkdirSync(join(root, "clients", "apple", "scripts"), { recursive: true });
      writeProbe(runner);
      const env: NodeJS.ProcessEnv = { ...process.env, HOME: join(root, "home") };
      delete env.OPPI_SIM_POOL_REPO;
      delete env.OPPI_ROOT;
      delete env.PIOS_ROOT;
      const result = spawnSync("bash", [wrapper, "run", "--", "xcodebuild", "build"], {
        cwd: root,
        env,
        encoding: "utf8",
      });
      expect(result.status).toBe(0);
      expect(result.stdout).toContain(`ROOT=${realpathSync.native(root)}`);
      expect(result.stdout).toContain("COUNT=unset");
      expect(result.stdout).toContain("ARGS=run -- xcodebuild build");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("missing runner fails clearly", () => {
    const env: NodeJS.ProcessEnv = { ...process.env, OPPI_ROOT: "/tmp/oppi-sim-missing-runner" };
    delete env.OPPI_SIM_POOL_REPO;
    const result = spawnSync("bash", [wrapper, "status"], { env, encoding: "utf8" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/sim-pool runner not found|OPPI_SIM_POOL_REPO/);
  });
});
