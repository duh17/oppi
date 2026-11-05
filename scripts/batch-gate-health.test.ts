import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Each test spawns the gate, which spawns git, node, and the stand-in runners.
setDefaultTimeout(60_000);

const gate = join(import.meta.dir, "batch-gate.ts");
const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/**
 * A stand-in for sim-pool.sh or e2e.sh: call N appends its arguments to `<name>.calls`, copies
 * `<name>-N.log` (empty when absent) into the log its summary names, prints the `Artifact:` line,
 * and exits with `<name>-N.exit` (0 when absent).
 */
function fakeRunner(state: string, name: string): string {
  return `#!/bin/sh
n=$(( $(cat "${state}/${name}.count" 2>/dev/null || echo 0) + 1 ))
echo $n > "${state}/${name}.count"
echo "$*" >> "${state}/${name}.calls"
log="${state}/${name}-run-$n.log"
cp "${state}/${name}-$n.log" "$log" 2>/dev/null || : > "$log"
echo "{\\"log_path\\":\\"$log\\"}" > "${state}/${name}-$n.summary.json"
echo "Artifact: ${state}/${name}-$n.summary.json"
exit $(cat "${state}/${name}-$n.exit" 2>/dev/null || echo 0)
`;
}

/** A git checkout (on `main`) of an Oppi tree whose sim-pool.sh and e2e.sh are stand-ins. */
function fakeCheckout() {
  const root = realpathSync.native(mkdtempSync(join(tmpdir(), "batch-gate-health-")));
  temps.push(root);
  const checkout = join(root, "checkout");
  const state = join(root, "state");
  const apple = join(checkout, "clients", "apple");
  for (const dir of [state, join(apple, "scripts"), join(apple, "OppiTests"), join(apple, "OppiE2ETests"), join(checkout, "server", "scripts"), join(checkout, "dev", "testing")]) {
    mkdirSync(dir, { recursive: true });
  }
  writeFileSync(join(apple, "OppiTests", "FooTests.swift"), "struct FooTests { @Test func a() {} func helper() {} }\n");
  // A stand-in xcrun: `xcresulttool get test-results tests --path <x>` prints <x>/tests.json.
  mkdirSync(join(root, "bin"));
  writeFileSync(join(root, "bin", "xcrun"), '#!/bin/sh\nfor last; do :; done\ncat "$last/tests.json"\n');
  chmodSync(join(root, "bin", "xcrun"), 0o755);
  writeFileSync(join(apple, "OppiE2ETests", "ChatE2ETests.swift"), "final class ChatE2ETests: E2ETestCase { func testSend() {} func testOther() {} }\n");
  writeFileSync(join(checkout, "server", "scripts", "ensure-installed-deps.mjs"), "");
  for (const name of ["sim-pool", "e2e"]) {
    writeFileSync(join(apple, "scripts", `${name}.sh`), fakeRunner(state, name));
    chmodSync(join(apple, "scripts", `${name}.sh`), 0o755);
  }
  const git = (...args: string[]) => {
    const run = Bun.spawnSync(["git", "-C", checkout, "-c", "user.name=t", "-c", "user.email=t@t", ...args]);
    if (run.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${run.stderr.toString()}`);
  };
  git("init", "-q", "-b", "main");
  git("add", ".");
  git("commit", "-q", "-m", "base");
  const script = (name: string, runs: { log?: string; exit?: number }[]) => runs.forEach((run, index) => {
    if (run.log !== undefined) writeFileSync(join(state, `${name}-${index + 1}.log`), run.log);
    if (run.exit !== undefined) writeFileSync(join(state, `${name}-${index + 1}.exit`), String(run.exit));
  });
  const calls = (name: string) => (existsSync(join(state, `${name}.calls`)) ? readFileSync(join(state, `${name}.calls`), "utf8").trim().split("\n") : []);
  const run = (args: string[], env: Record<string, string> = {}) => {
    const result = Bun.spawnSync(["bun", gate, "--worktree", checkout, ...args], {
      env: { ...process.env, PATH: `${join(root, "bin")}:${process.env.PATH}`, LAND_QUEUE_BATCH: "b-test-1", LAND_QUEUE_BRANCHES: "feature", ...env },
      stdout: "pipe",
      stderr: "pipe",
    });
    return { code: result.exitCode, out: result.stdout.toString(), err: result.stderr.toString() };
  };
  const ledger = (path: string) => {
    const full = join(checkout, ".git", "oppi", path);
    return existsSync(full) ? readFileSync(full, "utf8").trim().split("\n").map((line) => JSON.parse(line)) : [];
  };
  /** The record a pre-push unit run at the current HEAD leaves (unit-shards.ts), with one shard whose xcresult ran `ids`. */
  const unitRun = (ids: string[], skipped: string[] = []) => {
    const xcresult = join(state, "dd", "Logs", "Test", "run.xcresult");
    mkdirSync(xcresult, { recursive: true });
    const cases = [...ids.map((id) => [id, "Passed"]), ...skipped.map((id) => [id, "Skipped"])].map(([id, result]) => ({ nodeType: "Test Case", result, nodeIdentifier: id }));
    writeFileSync(join(xcresult, "tests.json"), JSON.stringify({ testNodes: [{ nodeType: "Unit test bundle", children: cases }] }));
    writeFileSync(join(state, "shard-1.summary.json"), JSON.stringify({ derived_data_path: join(state, "dd") }));
    const head = Bun.spawnSync(["git", "-C", checkout, "rev-parse", "HEAD"]).stdout.toString().trim();
    mkdirSync(join(apple, ".build"), { recursive: true });
    writeFileSync(join(apple, ".build", "unit-shards-last.json"), JSON.stringify({ head, summaries: [join(state, "shard-1.summary.json")] }));
  };
  return { checkout, git, script, calls, run, ledger, unitRun };
}

/** A finished XCTest run of OppiE2ETests cases. */
function e2eLog(cases: Record<string, "passed" | "failed">): string {
  const lines = Object.entries(cases).map(([name, result]) => `Test Case '-[OppiE2ETests.ChatE2ETests ${name}]' ${result} (40.0 seconds).`);
  const failures = Object.values(cases).filter((result) => result === "failed").length;
  return `${lines.join("\n")}\nTest Suite 'Selected tests' ${failures ? "failed" : "passed"} at 2026-11-01 10:00:00.000.\n\t Executed ${lines.length} tests, with ${failures} failures (0 unexpected) in 80.0 (80.1) seconds\n`;
}

describe("batch gate: zero-test selectors", () => {
  test("a unit selector whose Swift Testing run executed zero tests fails the lane, names the selector, and is a red lane guessed as a selector", () => {
    const fx = fakeCheckout();
    fx.script("sim-pool", [{ log: "Test Suite 'All tests' passed at 2026-11-01 10:00:00.000.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n◇ Test run started.\n✔ Test run with 0 tests passed after 0.001 seconds.\n" }]);
    const result = fx.run(["--test", "OppiTests/FooTests/a"]);
    expect(result.code).toBe(1);
    expect(result.out).toContain("[batch-gate] ios-unit: zero tests ran for OppiTests/FooTests/a: no test matches the selector");
    expect(result.out).toContain("[batch-gate] ios-unit: FAIL (exit 1)");
    const [row] = fx.ledger("land-queue/red-lanes.jsonl");
    expect(row).toMatchObject({ batch: "b-test-1", branches: ["feature"], lane: "ios-unit", profile: "iphone", exit: 1, tests: [], cause_guess: "selector", cause_confirmed: null });
  });

  test("an E2E selector whose XCTest run executed zero tests fails the lane and names the selector", () => {
    const fx = fakeCheckout();
    fx.script("e2e", [{ log: "Test Suite 'Selected tests' passed at 2026-11-01 10:00:00.000.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n" }]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests/testSend"]);
    expect(result.code).toBe(1);
    expect(result.out).toContain("[batch-gate] e2e: zero tests ran for OppiE2ETests/ChatE2ETests/testSend: no test matches the selector");
    expect(fx.ledger("land-queue/red-lanes.jsonl")[0]).toMatchObject({ lane: "e2e", cause_guess: "selector" });
  });
});

describe("batch gate: E2E rerun and flake ledger", () => {
  test("a failed E2E test that passes on its one rerun passes the lane, is recorded as a flake, and the summary names it", () => {
    const fx = fakeCheckout();
    fx.script("e2e", [
      { log: e2eLog({ testSend: "failed", testOther: "passed" }), exit: 65 },
      { log: e2eLog({ testSend: "passed" }) },
    ]);
    const result = fx.run(["--target", "main", "--test", "OppiE2ETests/ChatE2ETests"]);
    expect(result.code).toBe(0);
    // The rerun keeps the step's mode and runs only the failed test.
    expect(fx.calls("e2e")).toEqual(["--native --only-testing OppiE2ETests/ChatE2ETests", "--native --only-testing OppiE2ETests/ChatE2ETests/testSend"]);
    expect(fx.ledger("test-flakes.jsonl").map((row) => [row.id, row.lane, row.profile, row.outcome])).toEqual([["OppiE2ETests/ChatE2ETests/testSend", "e2e", "iphone", "flaky"]]);
    expect(result.out).toContain("[batch-gate] e2e: FLAKY OppiE2ETests/ChatE2ETests/testSend: failed, then passed on rerun (flaked in 1 gate)");
    expect(result.out).toMatch(/\[batch-gate\] e2e: PASS [0-9]+s; budget e2e: wall [0-9.]+s, no budget/);
    expect(result.out).toContain("[batch-gate] 1 flake hidden by rerun: OppiE2ETests/ChatE2ETests/testSend (e2e)");
    expect(fx.ledger("land-queue/red-lanes.jsonl")).toEqual([]);
  });

  test("a test that fails its rerun too keeps the lane red, with the test in the red-lane row", () => {
    const fx = fakeCheckout();
    fx.script("e2e", [
      { log: e2eLog({ testSend: "failed", testOther: "passed" }), exit: 65 },
      { log: e2eLog({ testSend: "failed" }), exit: 65 },
    ]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests"]);
    expect(result.code).toBe(1);
    expect(fx.ledger("test-flakes.jsonl").map((row) => row.outcome)).toEqual(["failed"]);
    expect(result.out).toContain("[batch-gate] no flakes hidden by rerun");
    expect(fx.ledger("land-queue/red-lanes.jsonl")[0]).toMatchObject({ lane: "e2e", exit: 65, tests: ["OppiE2ETests/ChatE2ETests/testSend"], cause_guess: "test-failure" });
  });

  test("a run that died before its test summary is not rerun: tests after the crash never ran", () => {
    const fx = fakeCheckout();
    fx.script("e2e", [{ log: "Test Case '-[OppiE2ETests.ChatE2ETests testSend]' failed (40.0 seconds).\n", exit: 65 }]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests"]);
    expect(result.code).toBe(1);
    expect(fx.calls("e2e")).toHaveLength(1);
    expect(result.out).toContain("e2e: no rerun (the run did not reach its test summary");
  });
});

describe("batch gate: the ios-unit lane and the pre-push unit shards", () => {
  /** A feature branch whose commit changes app code, so its pre-push plan has an Apple lane. */
  const appChange = () => {
    const fx = fakeCheckout();
    fx.git("checkout", "-q", "-b", "feature");
    mkdirSync(join(fx.checkout, "clients", "apple", "Oppi"), { recursive: true });
    writeFileSync(join(fx.checkout, "clients", "apple", "Oppi", "A.swift"), "let a = 1\n");
    fx.git("add", ".");
    fx.git("commit", "-q", "-m", "app change");
    return fx;
  };

  test("a batch whose pre-push plan ran the unit shards checks its unit selectors but does not run them again", () => {
    const fx = appChange();
    fx.unitRun(["FooTests/a()"]);
    const covered = fx.run(["--target", "main", "--test", "OppiTests/FooTests", "--test", "OppiTests/FooTests/a"]);
    expect(covered.code).toBe(0);
    expect(fx.calls("sim-pool")).toEqual([]);
    expect(covered.out).toContain("ios-unit: the pre-push plan for");
    expect(covered.out).toContain("has apple=unit");
    expect(covered.out).toContain("ios-unit: every named unit selector matched a test the pre-push unit shards ran at this HEAD");
    expect(covered.out).toContain("ios-unit: not run; the pre-push gate already ran every OppiUnitTests test in its unit shards, including OppiTests/FooTests, OppiTests/FooTests/a");
    // The selector is still checked: a suite the target does not declare fails the plan.
    const typo = fx.run(["--target", "main", "--test", "OppiTests/FooTest"]);
    expect(typo.code).toBe(2);
    expect(fx.ledger("land-queue/red-lanes.jsonl").at(-1)).toMatchObject({ lane: "plan", exit: 2, cause_guess: "selector" });
  });

  test("a named unit selector that matched no test of the pre-push unit run fails the gate as a selector, though the lane is not run", () => {
    const fx = appChange();
    // `a` is disabled: the xcresult lists it as skipped. The selector still found it, so it is matched.
    fx.unitRun(["FooTests/b()"], ["FooTests/a()"]);
    // `helper` is a function FooTests declares, so the plan accepts it, but it is not a test.
    const result = fx.run(["--target", "main", "--test", "OppiTests/FooTests/helper", "--test", "OppiTests/FooTests/a()", "--test", "OppiTests/FooTests"]);
    expect(result.code).toBe(1);
    expect(fx.calls("sim-pool")).toEqual([]);
    expect(result.out).toContain("ios-unit: zero tests ran for OppiTests/FooTests/helper: no test matches the selector");
    expect(result.out).toContain("[batch-gate] ios-unit: FAIL (exit 1)");
    expect(fx.ledger("land-queue/red-lanes.jsonl")[0]).toMatchObject({ lane: "ios-unit", exit: 1, cause_guess: "selector" });
  });

  test("without a readable record of the pre-push unit run at HEAD, the ios-unit lane runs after all", () => {
    const fx = appChange();
    fx.script("sim-pool", [{ log: "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n" }]);
    const result = fx.run(["--target", "main", "--test", "OppiTests/FooTests"]);
    expect(result.code).toBe(0);
    expect(result.out).toContain("ios-unit: cannot check the named unit selectors against the pre-push unit run (no unit-shards-last.json from the pre-push unit shards); running the ios-unit lane");
    expect(fx.calls("sim-pool")).toHaveLength(1);
  });

  test("a batch whose pre-push plan had no Apple lane, or with no --target, runs the ios-unit lane", () => {
    const fx = fakeCheckout();
    fx.script("sim-pool", [{ log: "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n" }, { log: "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n" }]);
    fx.git("checkout", "-q", "-b", "feature");
    mkdirSync(join(fx.checkout, "server", "src"), { recursive: true });
    writeFileSync(join(fx.checkout, "server", "src", "a.ts"), "export const a = 1;\n");
    fx.git("add", ".");
    fx.git("commit", "-q", "-m", "server change");
    const serverOnly = fx.run(["--target", "main", "--test", "OppiTests/FooTests"]);
    expect(serverOnly.code).toBe(0);
    expect(serverOnly.out).toContain("has apple=none");
    expect(fx.calls("sim-pool")).toHaveLength(1);
    const untargeted = fx.run(["--test", "OppiTests/FooTests"]);
    expect(untargeted.code).toBe(0);
    expect(untargeted.out).toContain("ios-unit: no --target, so the pre-push plan is unknown");
    expect(fx.calls("sim-pool")).toHaveLength(2);
  });
});

describe("batch gate: quarantine", () => {
  const daysAhead = (days: number) => new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10);
  const soon = daysAhead(7);
  const entry = (id: string, expires: string, extra: Record<string, string> = {}) => ({ id, owner: "lead", reason: "flaky on iPad", addedAt: "2026-10-01", expires, backlog: "test-health/flake-x", ...extra });

  test("an expired entry fails the gate before any lane, and so does one without a backlog key", () => {
    const fx = fakeCheckout();
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiUITests/AUITests/testA", "2020-01-01")]));
    const expired = fx.run(["--test", "OppiE2ETests/ChatE2ETests"]);
    expect(expired.code).toBe(1);
    expect(expired.err).toContain("quarantine expired 2020-01-01: OppiUITests/AUITests/testA (owner lead, backlog test-health/flake-x)");
    expect(fx.calls("e2e")).toEqual([]);
    expect(fx.ledger("land-queue/red-lanes.jsonl")[0]).toMatchObject({ lane: "quarantine", cause_guess: "quarantine" });
    const { backlog: _, ...noBacklog } = entry("OppiE2ETests/ChatE2ETests/testOther", soon);
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([noBacklog]));
    const incomplete = fx.run([]);
    expect(incomplete.code).toBe(1);
    expect(incomplete.err).toContain("quarantine entry OppiE2ETests/ChatE2ETests/testOther lacks backlog");
    // A quarantine is a decision date, not parking: more than 30 days ahead is refused.
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiE2ETests/ChatE2ETests/testOther", daysAhead(45))]));
    const parked = fx.run([]);
    expect(parked.code).toBe(1);
    expect(parked.err).toContain(`quarantine entry OppiE2ETests/ChatE2ETests/testOther: expires ${daysAhead(45)}, more than 30 days after`);
  });

  test("a quarantined E2E test is skipped in its suite's step and runs in a step whose failure does not block", () => {
    const fx = fakeCheckout();
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiE2ETests/ChatE2ETests/testOther", soon)]));
    fx.script("e2e", [{ log: e2eLog({ testSend: "passed" }) }, { log: e2eLog({ testOther: "failed" }), exit: 65 }]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests"]);
    expect(result.code).toBe(0);
    expect(fx.calls("e2e")).toEqual([
      "--native --only-testing OppiE2ETests/ChatE2ETests --skip-testing OppiE2ETests/ChatE2ETests/testOther",
      "--native --only-testing OppiE2ETests/ChatE2ETests/testOther",
    ]);
    expect(result.out).toContain(`e2e: quarantined, run without blocking: OppiE2ETests/ChatE2ETests/testOther (OppiE2ETests/ChatE2ETests/testOther: owner lead, expires ${soon}, backlog test-health/flake-x)`);
    expect(result.out).toContain("[batch-gate] e2e: quarantined (non-blocking): failed (exit 65) OppiE2ETests/ChatE2ETests/testOther");
    // A watch run is not a rerun: it records nothing.
    expect(fx.ledger("test-flakes.jsonl")).toEqual([]);
  });

  test("a quarantined unit test is skipped in the ios-unit lane and runs in a step whose failure does not block", () => {
    const fx = fakeCheckout();
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiTests/FooTests/a()", soon)]));
    fx.script("sim-pool", [{ log: "\u2714 Test run with 2 tests in 1 suite passed after 0.1 seconds.\n" }, { log: "\u2718 Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue.\n", exit: 65 }]);
    const result = fx.run(["--test", "OppiTests/FooTests"]);
    expect(result.code).toBe(0);
    expect(fx.calls("sim-pool").map((call) => call.split(" ").filter((arg) => /-testing:/.test(arg)))).toEqual([
      ["-only-testing:OppiTests/FooTests", "-skip-testing:OppiTests/FooTests/a()"],
      ["-only-testing:OppiTests/FooTests/a()"],
    ]);
    expect(result.out).toContain("[batch-gate] ios-unit: quarantined (non-blocking): failed (exit 65) OppiTests/FooTests/a()");
  });

  test("a dropped ios-unit lane names a quarantined selector as quarantined, not as covered", () => {
    const fx = fakeCheckout();
    fx.git("checkout", "-q", "-b", "feature");
    mkdirSync(join(fx.checkout, "clients", "apple", "Oppi"), { recursive: true });
    writeFileSync(join(fx.checkout, "clients", "apple", "Oppi", "A.swift"), "let a = 1\n");
    fx.git("add", ".");
    fx.git("commit", "-q", "-m", "app change");
    writeFileSync(join(fx.checkout, "dev", "testing", "quarantine.json"), JSON.stringify([entry("OppiTests/FooTests/a()", soon)]));
    fx.unitRun(["FooTests/a()"]);
    const result = fx.run(["--target", "main", "--test", "OppiTests/FooTests/a()"]);
    expect(result.code).toBe(0);
    expect(result.out).not.toContain("including");
    expect(result.out).toContain("ios-unit: quarantined, run without blocking by the pre-push unit shards: OppiTests/FooTests/a() (OppiTests/FooTests/a(): owner lead");
  });
});

describe("batch gate: --with-pre-push runs the hook alongside the lanes", () => {
  /** What the stand-in hook does after its Apple build passed (or, for `before-apple`, instead of passing it). */
  const HOOK_ENDINGS = {
    passes: `touch "$STATE/hook-done"\nexit 0`,
    "lane-fails": `echo "ios-unit failed" >> "$OPPI_PRE_PUSH_EVENTS"\necho "[ios-unit] FAILED" >&2\nsleep 2\nexit 1`,
    // A lane reported red, yet the hook exits 0: a stray event, as the self-test's fixtures once wrote.
    "event-then-passes": `echo "apple failed" >> "$OPPI_PRE_PUSH_EVENTS"\nexit 0`,
    // Red outside any lane (check-home-paths, the deps sync): no event, only the exit.
    "exits-without-event": `echo "pre-push: absolute home paths in tracked files" >&2\nexit 1`,
  } as const;

  /**
   * An app change whose gate names a UI and an E2E suite. The stand-in hook reads its push row and
   * records whether the kept build stamps still existed. Then, after 0.5 s, it either fails its
   * Apple build (`before-apple`) or says `apple passed` (leaving an `apple-passed` marker) and, 1 s
   * later, ends as `ending` says. The stand-in ui-shards records whether the Apple build had
   * passed when it started, then works for `uiSeconds` unless stopped.
   */
  function overlapCheckout(options: { ending: keyof typeof HOOK_ENDINGS | "before-apple"; uiSeconds: number }) {
    const fx = fakeCheckout();
    const state = join(fx.checkout, "..", "state");
    const apple = join(fx.checkout, "clients", "apple");
    mkdirSync(join(apple, "OppiUITests"), { recursive: true });
    writeFileSync(join(apple, "OppiUITests", "ChatRoutesUITests.swift"), "final class ChatRoutesUITests: XCTestCase { func testOpen() {} }\n");
    writeFileSync(join(apple, "scripts", "ui-shards.ts"), `import { existsSync, writeFileSync } from "node:fs";
const profile = process.argv[process.argv.indexOf("--profile") + 1];
writeFileSync("${state}/ui-" + profile + ".start", existsSync("${state}/apple-passed") ? "after-apple" : "before-apple");
process.on("SIGTERM", () => { writeFileSync("${state}/ui-" + profile + ".terminated", ""); process.exit(143); });
await Bun.sleep(${options.uiSeconds * 1000});
writeFileSync("${state}/ui-" + profile + ".done", "");
`);
    mkdirSync(join(fx.checkout, ".githooks"));
    // Build-phase stamps an earlier batch left in the kept DerivedData.
    const stamps = ["dd/Build/Intermediates.noindex/Oppi.build/Debug-iphonesimulator/Oppi.build/DerivedSources", "pre-push-mac/Build/Intermediates.noindex/Oppi.build/Debug/OppiMac.build/DerivedSources"]
      .flatMap((dir) => ["swiftlint.stamp", "architecture-boundaries.stamp"].map((name) => join(apple, ".build", dir, name)));
    for (const stamp of stamps) {
      mkdirSync(join(stamp, ".."), { recursive: true });
      writeFileSync(stamp, "");
    }
    const ending = options.ending === "before-apple"
      ? `echo "apple failed" >> "$OPPI_PRE_PUSH_EVENTS"\necho "[apple] FAILED" >&2\nsleep 1\nexit 1`
      : `touch "$STATE/apple-passed"\necho "apple passed" >> "$OPPI_PRE_PUSH_EVENTS"\nsleep 1\n${HOOK_ENDINGS[options.ending]}`;
    writeFileSync(join(fx.checkout, ".githooks", "pre-push"), `#!/bin/bash
set -euo pipefail
STATE="${state}"
cat > "$STATE/hook.stdin"
ls ${stamps.map((stamp) => `"${stamp}"`).join(" ")} > "$STATE/stamps-at-hook" 2>/dev/null || true
echo "[apple] starting"
sleep 0.5
${ending}
`);
    chmodSync(join(fx.checkout, ".githooks", "pre-push"), 0o755);
    fx.git("checkout", "-q", "-b", "feature");
    mkdirSync(join(apple, "Oppi"), { recursive: true });
    writeFileSync(join(apple, "Oppi", "A.swift"), "let a = 1\n");
    fx.git("add", ".");
    fx.git("commit", "-q", "-m", "app change");
    const head = Bun.spawnSync(["git", "-C", fx.checkout, "rev-parse", "HEAD"]).stdout.toString().trim();
    const base = Bun.spawnSync(["git", "-C", fx.checkout, "rev-parse", "main"]).stdout.toString().trim();
    const row = `refs/heads/land-queue/b-test-1 ${head} refs/heads/main ${base}`;
    const gate = () => {
      const started = Date.now();
      const result = fx.run(["--target", "main", "--with-pre-push", row, "--test", "OppiUITests/ChatRoutesUITests", "--test", "OppiE2ETests/ChatE2ETests/testSend"]);
      return { ...result, seconds: (Date.now() - started) / 1000 };
    };
    const has = (name: string) => existsSync(join(state, name));
    const read = (name: string) => readFileSync(join(state, name), "utf8");
    return { ...fx, row, gate, has, read };
  }

  test("a red pre-push lane stops the UI lanes it started early, starts no other lane, and fails the gate", () => {
    const fx = overlapCheckout({ ending: "lane-fails", uiSeconds: 60 });

    const result = fx.gate();

    expect(result.code).toBe(3);
    // The UI lane waited for the hook's Apple build, then was stopped at the failed lane, not after its 60 s.
    expect(fx.read("ui-iphone.start")).toBe("after-apple");
    expect(fx.has("ui-iphone.terminated")).toBe(true);
    expect(fx.has("ui-iphone.done")).toBe(false);
    expect(result.seconds).toBeLessThan(20);
    expect(result.out).toContain("[batch-gate] pre-push: its ios-unit lane failed");
    // The hook ran to its end with git's push row, its output prefixed.
    expect(fx.read("hook.stdin")).toBe(`${fx.row}\n`);
    expect(result.out).toContain("[pre-push] [apple] starting");
    expect(result.out).toContain("[pre-push] [ios-unit] FAILED");
    // The E2E lane waits for a green hook, so it never ran.
    expect(fx.calls("e2e")).toEqual([]);
    expect(result.out).toMatch(/\[batch-gate\] pre-push: FAIL \(exit 1\) [0-9]+s/);
    expect(result.out).toMatch(/\[batch-gate\] ui-iphone: CANCELLED [0-9]+s; stopped because the pre-push gate failed/);
    expect(result.out).toContain("[batch-gate] e2e: NOT RUN; the pre-push gate failed first");
    // A lane cut short is not a red lane of its own.
    expect(fx.ledger("land-queue/red-lanes.jsonl")).toEqual([]);
  });

  test("a lane that reported red fails the gate even when the hook then exits 0", () => {
    const fx = overlapCheckout({ ending: "event-then-passes", uiSeconds: 60 });

    const result = fx.gate();

    expect(result.code).toBe(3);
    expect(fx.has("hook-done")).toBe(false);
    expect(fx.has("ui-iphone.terminated")).toBe(true);
    expect(fx.calls("e2e")).toEqual([]);
    expect(result.out).toMatch(/\[batch-gate\] pre-push: FAIL \(its apple lane failed; the hook exited 0\) [0-9]+s/);
  });

  test("a hook that fails outside any lane, with no event, still stops the early lanes and fails the gate", () => {
    const fx = overlapCheckout({ ending: "exits-without-event", uiSeconds: 60 });

    const result = fx.gate();

    expect(result.code).toBe(3);
    expect(fx.has("ui-iphone.terminated")).toBe(true);
    expect(result.out).toContain("[batch-gate] pre-push: the hook failed (exit 1)");
    expect(result.out).toMatch(/\[batch-gate\] ui-iphone: CANCELLED/);
    expect(result.out).toContain("[batch-gate] e2e: NOT RUN; the pre-push gate failed first");
  });

  test("a red Apple build starts no lane at all, and the summary lists every lane as not run", () => {
    const fx = overlapCheckout({ ending: "before-apple", uiSeconds: 60 });

    const result = fx.gate();

    expect(result.code).toBe(3);
    expect(fx.has("ui-iphone.start")).toBe(false);
    expect(fx.calls("e2e")).toEqual([]);
    expect(result.out).toContain("[batch-gate] ui-iphone: NOT RUN; the pre-push gate failed first");
    expect(result.out).toContain("[batch-gate] e2e: NOT RUN; the pre-push gate failed first");
  });

  test("the kept DerivedData's SwiftLint and architecture stamps are gone before the hook builds, so both phases run", () => {
    const fx = overlapCheckout({ ending: "passes", uiSeconds: 0.2 });
    fx.script("e2e", [{ log: e2eLog({ testSend: "passed" }) }]);

    expect(fx.gate().code).toBe(0);
    expect(fx.read("stamps-at-hook")).toBe("");
  });

  test("the hook's own self-test, run as a lane inside such a gate, writes no lane event into the gate's file", () => {
    const events = join(mkdtempSync(join(tmpdir(), "batch-gate-events-")), "events");
    temps.push(join(events, ".."));
    const hook = join(import.meta.dir, "..", ".githooks", "pre-push");

    const run = Bun.spawnSync([hook, "--self-test", "--lanes-only"], { env: { ...process.env, OPPI_PRE_PUSH_EVENTS: events }, stdout: "pipe", stderr: "pipe" });

    expect(run.exitCode).toBe(0);
    expect(existsSync(events) ? readFileSync(events, "utf8") : "").toBe("");
  });

  // The gate reads the hook's output until it closes. A busy-slot holder that outlived the self-test
  // with that output open kept a land-queue gate waiting long after every lane had passed.
  test("a hook self-test stopped while its fixture holds a build slot leaves no holder and its output closes", async () => {
    const hook = join(import.meta.dir, "..", ".githooks", "pre-push");
    const processes = () =>
      Bun.spawnSync(["ps", "-Ao", "pid=,ppid=,command="], { stdout: "pipe" }).stdout.toString().split("\n")
        .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
        .filter((match) => match !== null)
        .map(([, pid, ppid, command]) => ({ pid: Number(pid), ppid: Number(ppid), command }));
    const run = Bun.spawn([hook, "--self-test", "--lanes-only"], { stdout: "pipe", stderr: "pipe" });
    const output = Promise.all([new Response(run.stdout).text(), new Response(run.stderr).text()]).then(() => "closed");
    // The busy-slot fixture's holder: the hook's own `lockf ... free-slot` child.
    let holders: { pid: number; release: string }[] = [];
    try {
      const deadline = Date.now() + 30_000;
      while (holders.length === 0 && Date.now() < deadline) {
        holders = processes()
          .filter((proc) => proc.ppid === run.pid && proc.command.startsWith("/usr/bin/lockf ") && proc.command.includes("/free-slot"))
          .map((proc) => ({ pid: proc.pid, release: proc.command.match(/(\S+\/free-slot)/)![1] }));
        if (holders.length === 0) await Bun.sleep(100);
      }
      expect(holders).not.toEqual([]);

      run.kill("SIGTERM"); // the hook alone, as a timeout or a parent that signals only its child would

      expect(await Promise.race([output, Bun.sleep(5_000).then(() => "still open")])).toBe("closed");
      const alive = new Set(processes().map((proc) => proc.pid));
      expect(holders.filter((holder) => alive.has(holder.pid))).toEqual([]);
    } finally {
      // Release a leaked holder so a red run does not outlive the test.
      for (const holder of holders) writeFileSync(holder.release, "");
      run.kill("SIGKILL");
    }
  });

  test("a green pre-push lets the early UI lanes finish and then runs the rest; the summary leads with the hook", () => {
    const fx = overlapCheckout({ ending: "passes", uiSeconds: 0.2 });
    fx.script("e2e", [{ log: e2eLog({ testSend: "passed" }) }]);

    const result = fx.gate();

    expect(result.code).toBe(0);
    expect(fx.read("ui-iphone.start")).toBe("after-apple");
    expect(fx.has("ui-iphone.done")).toBe(true);
    expect(fx.calls("e2e")).toEqual(["--native --only-testing OppiE2ETests/ChatE2ETests/testSend"]);
    const order = ["ui-iphone: starting after the pre-push apple lane passed", "e2e: starting after the pre-push gate passed", "[batch-gate] summary:", "[batch-gate] pre-push: PASS", "[batch-gate] ui-iphone: PASS", "[batch-gate] e2e: PASS"];
    const positions = order.map((text) => result.out.indexOf(text));
    expect(positions.every((position) => position >= 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
  });

  test("--supports-pre-push and --build-cache answer without a checkout", () => {
    const probe = (flag: string) => Bun.spawnSync(["bun", gate, flag], { cwd: tmpdir(), stdout: "pipe" });
    const pre = probe("--supports-pre-push");
    expect(pre.exitCode).toBe(0);
    expect(pre.stdout.toString().trim()).toBe("batch-gate: runs-pre-push");
    const cache = probe("--build-cache");
    expect(cache.exitCode).toBe(0);
    const lines = cache.stdout.toString().trim().split("\n");
    expect(lines.filter((line) => line.startsWith("batch-gate: build-cache "))).toContain("batch-gate: build-cache clients/apple/.build/dd");
    expect(lines.filter((line) => line.startsWith("batch-gate: build-cache-key "))).toHaveLength(1);
  });
});

describe("batch gate: budgets and hidden flakes", () => {
  test("a lane budget file that cannot be read is a warning in the summary; the lane still passes", () => {
    const fx = fakeCheckout();
    writeFileSync(join(fx.checkout, "dev", "testing", "lane-budgets.json"), "{ not json");
    fx.script("e2e", [{ log: e2eLog({ testSend: "passed" }) }]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests/testSend"]);
    expect(result.code).toBe(0);
    expect(result.out).toContain("[batch-gate] e2e: PASS");
    expect(result.out).toMatch(/\[batch-gate\] WARNING lane budgets unreadable, no lane has a budget: .*lane-budgets\.json/);
  });

  test("a flake in a lane that ends red is not reported as hidden: the red lane hid nothing", () => {
    const fx = fakeCheckout();
    fx.script("e2e", [
      { log: e2eLog({ testSend: "failed" }), exit: 65 },
      { log: e2eLog({ testSend: "passed" }) },
      { log: e2eLog({ testOther: "failed" }), exit: 65 },
      { log: e2eLog({ testOther: "failed" }), exit: 65 },
    ]);
    const result = fx.run(["--test", "OppiE2ETests/ChatE2ETests/testSend", "--test", "OppiE2ETests/ChatE2ETests/testOther"]);
    expect(result.code).toBe(1);
    expect(fx.ledger("test-flakes.jsonl").map((row) => [row.id, row.outcome])).toEqual([
      ["OppiE2ETests/ChatE2ETests/testSend", "flaky"],
      ["OppiE2ETests/ChatE2ETests/testOther", "failed"],
    ]);
    expect(result.out).toContain("[batch-gate] no flakes hidden by rerun");
  });
});
