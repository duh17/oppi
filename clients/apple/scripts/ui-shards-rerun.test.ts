import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";

setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/**
 * A git checkout holding copies of the real shard runner and its modules, with a stand-in
 * sim-pool.sh: a build-for-testing writes the xctestrun; test run N appends its flags to
 * `calls`, logs `ui-N.log` (empty when absent), and exits with `ui-N.exit` (0 when absent).
 */
function checkout() {
  const root = realpathSync.native(mkdtempSync(join(tmpdir(), "ui-shards-rerun-")));
  temps.push(root);
  const state = join(root, ".state");
  const scripts = join(root, "clients", "apple", "scripts");
  for (const dir of [state, scripts, join(root, "scripts"), join(root, "dev", "testing"), join(root, "clients", "apple", "OppiUITests")]) mkdirSync(dir, { recursive: true });
  for (const name of readdirSync(import.meta.dir).filter((file) => /\.(ts|json)$/.test(file) && !file.endsWith(".test.ts"))) copyFileSync(join(import.meta.dir, name), join(scripts, name));
  copyFileSync(join(import.meta.dir, "..", "..", "..", "scripts", "gate-report.ts"), join(root, "scripts", "gate-report.ts"));
  copyFileSync(join(import.meta.dir, "..", "..", "..", "dev", "testing", "lane-budgets.json"), join(root, "dev", "testing", "lane-budgets.json"));
  writeFileSync(join(root, "clients", "apple", "OppiUITests", "AUITests.swift"), "final class AUITests: XCTestCase { func testA() {} func testB() {} }\n");
  writeFileSync(join(scripts, "sim-pool.sh"), `#!/bin/sh
case " $* " in *" build-for-testing "*)
  mkdir -p "$OPPI_SIM_POOL_PRODUCTS_DIR/Build/Products"
  : > "$OPPI_SIM_POOL_PRODUCTS_DIR/Build/Products/Oppi_iphonesimulator-arm64.xctestrun"
  exit 0 ;;
esac
n=$(( $(cat "${state}/ui.count" 2>/dev/null || echo 0) + 1 ))
echo $n > "${state}/ui.count"
echo "$*" | tr ' ' '\\n' | grep -e '-testing:' | tr '\\n' ' ' >> "${state}/calls"; echo >> "${state}/calls"
log="${state}/run-$n.log"
cp "${state}/ui-$n.log" "$log" 2>/dev/null || : > "$log"
echo "{\\"log_path\\":\\"$log\\"}" > "${state}/run-$n.summary.json"
echo "Artifact: ${state}/run-$n.summary.json"
exit $(cat "${state}/ui-$n.exit" 2>/dev/null || echo 0)
`);
  chmodSync(join(scripts, "sim-pool.sh"), 0o755);
  Bun.spawnSync(["git", "init", "-q", root]);
  Bun.spawnSync(["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"]);
  const script = (runs: { log?: string; exit?: number }[]) => runs.forEach((run, index) => {
    if (run.log !== undefined) writeFileSync(join(state, `ui-${index + 1}.log`), run.log);
    if (run.exit !== undefined) writeFileSync(join(state, `ui-${index + 1}.exit`), String(run.exit));
  });
  const run = (...filters: string[]) => {
    const result = Bun.spawnSync(["bun", join(scripts, "ui-shards.ts"), "--profile", "ipad", "--", ...filters], { cwd: root, stdout: "pipe", stderr: "pipe", env: { ...process.env, OPPI_UI_SHARDS: "1" } });
    return { code: result.exitCode, out: result.stdout.toString() + result.stderr.toString() };
  };
  const calls = () => (existsSync(join(state, "calls")) ? readFileSync(join(state, "calls"), "utf8").trim().split("\n").map((line) => line.trim()) : []);
  const flakes = () => {
    const path = join(root, ".git", "oppi", "test-flakes.jsonl");
    return existsSync(path) ? readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line)) : [];
  };
  return { root, script, run, calls, flakes };
}

/** A finished XCTest run of AUITests cases. */
function log(cases: Record<string, "passed" | "failed">): string {
  const lines = Object.entries(cases).map(([name, result]) => `Test Case '-[OppiUITests.AUITests ${name}]' ${result} (${result === "passed" ? 30 : 50}.0 seconds).`);
  const failures = Object.values(cases).filter((result) => result === "failed").length;
  return `${lines.join("\n")}\nTest Suite 'Selected tests' ${failures ? "failed" : "passed"} at 2026-11-01 10:00:00.000.\n\t Executed ${lines.length} tests, with ${failures} failures (0 unexpected) in 80.0 (80.1) seconds\n`;
}

describe("ui shards rerun", () => {
  test("a failed UI test that passes on its one rerun passes the lane, is recorded as a flake, and the summary names it", () => {
    const fx = checkout();
    fx.script([{ log: log({ testA: "passed", testB: "failed" }), exit: 65 }, { log: log({ testB: "passed" }) }]);
    const result = fx.run("OppiUITests/AUITests");
    expect(result.code).toBe(0);
    expect(fx.calls()).toEqual(["-only-testing:OppiUITests/AUITests", "-only-testing:OppiUITests/AUITests/testB"]);
    expect(result.out).toContain("[ui-shards] FLAKY OppiUITests/AUITests/testB: failed, then passed on rerun (flaked in 1 gate)");
    expect(result.out).toContain("[ui-shards] 1 flake hidden by rerun: OppiUITests/AUITests/testB (ui-ipad)");
    // The budget is the first run's median test (30 s and 50 s).
    expect(result.out).toMatch(/\[ui-shards\] budget ui-ipad: median test 40s of 45s over 2 tests, wall [0-9.]+s/);
    expect(fx.flakes().map((row) => [row.id, row.lane, row.profile, row.outcome])).toEqual([["OppiUITests/AUITests/testB", "ui-ipad", "ipad", "flaky"]]);
  });

  test("a test that fails its rerun too keeps the lane red and is named as FAILED", () => {
    const fx = checkout();
    fx.script([{ log: log({ testA: "passed", testB: "failed" }), exit: 65 }, { log: log({ testB: "failed" }), exit: 65 }]);
    const result = fx.run("OppiUITests/AUITests");
    expect(result.code).toBe(1);
    expect(result.out).toContain("[ui-shards] FAILED OppiUITests/AUITests/testB");
    // A red lane hides nothing, so it claims nothing about hidden flakes.
    expect(result.out).not.toContain("flakes hidden by rerun");
    expect(fx.flakes().map((row) => row.outcome)).toEqual(["failed"]);
  });
});

describe("ui shards quarantine", () => {
  const soon = new Date(Date.now() + 7 * 86_400_000).toISOString().slice(0, 10);
  const entry = (id: string, expires: string) => ({ id, owner: "lead", reason: "iPad flake", addedAt: "2026-10-01", expires, backlog: "test-health/ipad-x" });

  test("a quarantined test is skipped in its class's shard and runs in a shard whose failure does not block", () => {
    const fx = checkout();
    writeFileSync(join(fx.root, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiUITests/AUITests/testB", soon)]));
    fx.script([{ log: log({ testA: "passed" }) }, { log: log({ testB: "failed" }), exit: 65 }]);
    const result = fx.run("OppiUITests/AUITests");
    expect(result.code).toBe(0);
    expect(fx.calls()).toEqual(["-only-testing:OppiUITests/AUITests -skip-testing:OppiUITests/AUITests/testB", "-only-testing:OppiUITests/AUITests/testB"]);
    expect(result.out).toContain(`quarantined, run without blocking: OppiUITests/AUITests/testB (OppiUITests/AUITests/testB: owner lead, expires ${soon}, backlog test-health/ipad-x)`);
    expect(result.out).toContain("[ui-shards] quarantined (non-blocking): failed OppiUITests/AUITests/testB");
  });

  test("an expired entry fails the run before it builds", () => {
    const fx = checkout();
    writeFileSync(join(fx.root, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiUITests/AUITests/testB", "2020-01-01")]));
    const result = fx.run("OppiUITests/AUITests");
    expect(result.code).toBe(1);
    expect(result.out).toContain("quarantine expired 2020-01-01: OppiUITests/AUITests/testB (owner lead, backlog test-health/ipad-x)");
    expect(fx.calls()).toEqual([]);
  });
});
