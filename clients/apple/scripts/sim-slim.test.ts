import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const scripts = import.meta.dir;
const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function apply(mode: "legacy" | "current" | "fresh" | "reject-enable") {
  const dir = mkdtempSync(join(tmpdir(), "oppi-sim-slim-"));
  temps.push(dir);
  const trace = join(dir, "calls");
  writeFileSync(join(dir, "xcrun"), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$TRACE"
if [[ "$2" == "spawn" && "$5" == "print-disabled" ]]; then
  if [[ "$MODE" != "fresh" ]]; then
    printf '%s\\n' '"com.apple.PosterBoard" => disabled' '"com.apple.routined" => true'
    if [[ "$MODE" == "current" ]]; then
      printf '%s\\n' '"com.apple.navd" => enabled'
    else
      printf '%s\\n' '"com.apple.navd" => true'
    fi
  fi
fi
if [[ "$MODE" == "reject-enable" && "$2" == "spawn" && "$5" == "enable" && "$6" == "system/com.apple.navd" ]]; then
  echo 'enable rejected' >&2
  exit 42
fi
`, { mode: 0o755 });
  // Exercise the shared owner with its real label file. Only xcrun effects and
  // the caller's boot-readiness hook are replaced; no simulator is launched.
  const driver = join(dir, "apply.sh");
  writeFileSync(driver, `#!/usr/bin/env bash
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
wait_for_boot_ready_with_retries() { xcrun simctl bootstatus "$1" -b; }
source "$SLIM_SCRIPT"
slim_simulator PRIVATE
`);
  const result = spawnSync("bash", [driver], {
    encoding: "utf8",
    timeout: 20000,
    env: {
      ...process.env,
      PATH: `${dir}:${process.env.PATH}`,
      TRACE: trace,
      MODE: mode,
      SLIM_SCRIPT: join(scripts, "sim-slim.sh"),
      SIM_SLIM_LABELS_FILE: join(scripts, "sim-pool-slim-labels.txt"),
      OPPI_SIM_SLIM: "1",
    },
  });
  return { ...result, calls: readFileSync(trace, "utf8").trim().split("\n") };
}

const enable = "simctl spawn PRIVATE launchctl enable system/com.apple.navd";
const shutdown = "simctl shutdown PRIVATE";
const boot = "simctl boot PRIVATE";

describe("shared simulator slimming navigation dependency", () => {
  test("migrates old slim overrides and reloads only the supplied device", () => {
    const result = apply("legacy");
    expect(result.status).toBe(0);
    expect(result.calls).toContain(enable);
    expect(result.calls.filter(call => call === shutdown)).toHaveLength(1);
    expect(result.calls.filter(call => call === boot)).toHaveLength(1);
    expect(result.calls.indexOf(enable)).toBeLessThan(result.calls.indexOf(shutdown));
    expect(result.calls.every(call => /^simctl (spawn|shutdown|boot|bootstatus) PRIVATE(?: |$)/.test(call))).toBe(true);
  });

  test("fresh slimming keeps navigation, widget and live diagnostic services", () => {
    const result = apply("fresh");
    expect(result.status).toBe(0);
    expect(result.calls).toContain(enable);
    for (const label of ["navd", "chronod", "liveactivitiesd", "diagnosticd"]) {
      expect(result.calls).not.toContain(`simctl spawn PRIVATE launchctl disable system/com.apple.${label}`);
    }
  });

  test("already migrated devices are not mutated or rebooted", () => {
    const result = apply("current");
    expect(result.status).toBe(0);
    expect(result.calls).toEqual(["simctl spawn PRIVATE launchctl print-disabled system"]);
    expect(result.stderr).toContain("already slim");
  });

  test("cannot claim slimming success when required navigation restoration fails", () => {
    const result = apply("reject-enable");
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("nav");
    expect(result.calls).not.toContain(shutdown);
    expect(result.calls).not.toContain(boot);
    expect(result.stderr).not.toContain("already slim");
  });
});
