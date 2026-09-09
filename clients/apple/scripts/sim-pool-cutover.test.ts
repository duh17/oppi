import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const wrapper = join(import.meta.dir, "sim-pool-personal-forward.sh");

describe("staged personal forwarding wrapper", () => {
  test("forwards argv to the repository runner and does not set old personal defaults", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-sim-cutover-"));
    try {
      const probe = join(dir, "probe.sh");
      writeFileSync(
        probe,
        `#!/usr/bin/env bash
set -euo pipefail
printf 'COUNT=%s KEEP=%s FORCE=%s ARGS=%s\\n' \\
  "\${OPPI_SIM_POOL_COUNT-unset}" \\
  "\${OPPI_SIM_POOL_KEEP_BOOTED-unset}" \\
  "\${OPPI_SIM_POOL_FORCE_CLEAN_BOOT-unset}" \\
  "$*"
`,
        { mode: 0o755 },
      );
      chmodSync(probe, 0o755);
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

  test("refuses to run without OPPI_SIM_POOL_REPO", () => {
    const env: NodeJS.ProcessEnv = { ...process.env };
    delete env.OPPI_SIM_POOL_REPO;
    const result = spawnSync("bash", [wrapper], { env, encoding: "utf8" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("OPPI_SIM_POOL_REPO");
  });

}
);
