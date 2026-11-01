import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  budgetVerdict, failedTestsInOutput, flakesAt, flakesAtHead, guessCause, hiddenFlakesLine, loadBudgets, parseFlakes, recordRedLane, recordRerun, xctestRerun,
} from "./gate-report";

const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** A git checkout with one commit, so the ledgers resolve `<git common dir>/oppi` and a HEAD. */
function checkout(): string {
  const dir = mkdtempSync(join(tmpdir(), "gate-report-"));
  temps.push(dir);
  const git = (...args: string[]) => Bun.spawnSync(["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", ...args]);
  git("init", "-q");
  git("commit", "-q", "--allow-empty", "-m", "a");
  return dir;
}
const commit = (dir: string) => Bun.spawnSync(["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "b"]);
const rows = (path: string) => readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line));

/** A finished XCTest run of `cases` (`Class/test` -> passed or failed). */
function xctestLog(cases: Record<string, "passed" | "failed">, bundle = "OppiUITests"): string {
  const lines = Object.entries(cases).map(([id, result]) => {
    const [cls, name] = id.split("/");
    return `Test Case '-[${bundle}.${cls} ${name}]' started.\nTest Case '-[${bundle}.${cls} ${name}]' ${result} (31.5 seconds).`;
  });
  const failures = Object.values(cases).filter((result) => result === "failed").length;
  return `${lines.join("\n")}\nTest Suite 'Selected tests' ${failures ? "failed" : "passed"} at 2026-11-01 10:00:00.000.\n\t Executed ${lines.length} tests, with ${failures} failures (0 unexpected) in 90.0 (90.1) seconds\n`;
}

describe("rerun ledger", () => {
  test("every lane writes one shape; only passes on a rerun count as flaky gates, once per head", () => {
    const dir = checkout();
    const path = join(dir, ".git", "oppi", "test-flakes.jsonl");
    // A row from before lanes were recorded: the unit shards' pass-on-rerun.
    Bun.spawnSync(["mkdir", "-p", join(dir, ".git", "oppi")]);
    writeFileSync(path, `${JSON.stringify({ id: "OppiUITests/A/testX", head: "old", at: "2026-10-30T00:00:00.000Z" })}\n`);
    expect(recordRerun(dir, { id: "OppiUITests/A/testX", lane: "ui-ipad", profile: "ipad", outcome: "flaky" })).toBe(2);
    // The same gate (head) flaking again, and a failed rerun, are not more flaky gates.
    expect(recordRerun(dir, { id: "OppiUITests/A/testX", lane: "ui-iphone", profile: "iphone", outcome: "flaky" })).toBe(2);
    expect(recordRerun(dir, { id: "OppiUITests/A/testX", lane: "ui-ipad", profile: "ipad", outcome: "failed" })).toBe(2);
    commit(dir);
    expect(recordRerun(dir, { id: "OppiUITests/A/testX", lane: "ui-ipad", profile: "ipad", outcome: "flaky" })).toBe(3);
    const written = rows(path);
    expect(Object.keys(written[1]).sort()).toEqual(["at", "head", "id", "lane", "outcome", "profile"]);
    expect(written.slice(1).map((row) => [row.lane, row.profile, row.outcome])).toEqual([
      ["ui-ipad", "ipad", "flaky"], ["ui-iphone", "iphone", "flaky"], ["ui-ipad", "ipad", "failed"], ["ui-ipad", "ipad", "flaky"],
    ]);
    expect(parseFlakes(readFileSync(path, "utf8"))[0]).toMatchObject({ lane: "unit-full", profile: "iphone", outcome: "flaky" });
  });

  test("the summary names the flakes hidden at this head, once per test and lane, and says so when there are none", () => {
    const dir = checkout();
    expect(hiddenFlakesLine(flakesAtHead(dir))).toBe("no flakes hidden by rerun");
    recordRerun(dir, { id: "OppiTests/S/a()", lane: "unit-full", profile: "iphone", outcome: "flaky" });
    recordRerun(dir, { id: "OppiE2ETests/C/testY", lane: "e2e", profile: "iphone", outcome: "flaky" });
    recordRerun(dir, { id: "OppiE2ETests/C/testY", lane: "e2e", profile: "iphone", outcome: "flaky" });
    recordRerun(dir, { id: "OppiUITests/B/testZ", lane: "ui-ipad", profile: "ipad", outcome: "failed" });
    expect(hiddenFlakesLine(flakesAtHead(dir))).toBe("2 flakes hidden by rerun: OppiTests/S/a() (unit-full), OppiE2ETests/C/testY (e2e)");
    // Another head's flakes belong to another gate.
    const head = flakesAtHead(dir)[0].head;
    expect(flakesAt([{ id: "x", lane: "e2e", profile: null, head: "other", at: "", outcome: "flaky" }], head)).toEqual([]);
    // A directory outside any checkout has no ledger.
    const plain = mkdtempSync(join(tmpdir(), "gate-report-plain-"));
    temps.push(plain);
    expect(flakesAtHead(plain)).toEqual([]);
  });
});

describe("XCTest rerun candidates", () => {
  test("a finished run's failed tests are rerun; an unfinished run, a failure outside tests, or too many failures are not", () => {
    expect(xctestRerun(xctestLog({ "A/testOne": "passed", "A/testTwo": "failed", "B/testThree": "failed" }))).toEqual({
      ids: ["OppiUITests/A/testTwo", "OppiUITests/B/testThree"],
    });
    // The runner died after one test: later tests never started, so rerunning the failed one would pass a run that skipped them.
    const died = "Test Case '-[OppiUITests.A testOne]' failed (4.0 seconds).\n";
    expect(xctestRerun(died)).toHaveProperty("reason");
    expect(xctestRerun(xctestLog({ "A/testOne": "passed" }).replace("passed at", "failed at"))).toHaveProperty("reason");
    const many = Object.fromEntries(Array.from({ length: 6 }, (_, i) => [`A/test${i}`, "failed" as const]));
    expect((xctestRerun(xctestLog(many)) as { reason: string }).reason).toContain("6 failed tests");
  });
});

describe("red lanes", () => {
  test("the cause is guessed from the lane's output, and a named failing test outranks infrastructure noise", () => {
    const guess = (output: string, tests: string[] = []) => guessCause(output, tests).cause;
    expect(guess("[batch-gate] ios-unit: zero tests ran for OppiTests/A/b: no test matches the selector (see dev/testing/apple.md#gotchas)")).toBe("selector");
    expect(guess("error: zero tests ran for OppiUITests/X/testY: no test matches the selector (Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds)")).toBe("selector");
    expect(guess("unknown --test 'FooTest'")).toBe("selector");
    expect(guess("Compiler/linker errors (1):\n/x/Oppi/A.swift:12:3: error: cannot find 'x' in scope")).toBe("compile");
    expect(guess("[ui-shards] build failed (exit 65)")).toBe("compile");
    expect(guess("error: all 2 simulator slots (slots 8-9) are busy or quarantined (waited 60s)")).toBe("infra");
    expect(guess("[sim-pool] hang detected: no log, DerivedData, or build CPU progress for 180s (pid 9)")).toBe("infra");
    expect(guess("[ui-shards] FAILED (INFRASTRUCTURE failure, no tests ran in shard-1)")).toBe("infra");
    expect(guess("[sim-pool] hang detected: no log progress\nTest Case '-[OppiUITests.A testB]' failed (3.0 seconds).", ["OppiUITests/A/testB"])).toBe("test-failure");
    expect(guess(" FAIL  tests/a.test.ts > b > c")).toBe("test-failure");
    expect(guess("quarantine expired 2026-10-01: OppiUITests/A/testB (owner o, backlog k)")).toBe("quarantine");
    expect(guessCause("exit 1", []).cause).toBe("unknown");
    expect(guessCause("error: all 6 simulator slots (slots 0-5) are busy or quarantined (waited 60s)", []).evidence).toContain("busy or quarantined");
  });

  test("failing tests come from the runners' FAILED lines and Vitest, not from XCTest lines a rerun may have cleared", () => {
    const output = [
      "Test Case '-[OppiUITests.A testFlaky]' failed (3.0 seconds).",
      "[ui-shards] FAILED OppiUITests/A/testRed",
      "[unit-shards] FAILED OppiTests/S/red()",
      "\x1b[31m FAIL \x1b[39m tests/a.test.ts > group > case",
    ].join("\n");
    expect(failedTestsInOutput(output)).toEqual(["OppiUITests/A/testRed", "OppiTests/S/red()", "server/tests/a.test.ts > group > case"]);
  });

  test("a red lane of a land-queue batch is one ledger row with a labelled guess; outside a batch nothing is written", () => {
    const dir = checkout();
    const lane = { lane: "ui-ipad", profile: "ipad", exit: 1, seconds: 612, tests: ["OppiUITests/A/testB"], output: "Test Case '-[OppiUITests.A testB]' failed (3.0 seconds)." };
    expect(recordRedLane(dir, lane, {})).toMatchObject({ path: undefined, cause: "test-failure" });
    const written = recordRedLane(dir, lane, { LAND_QUEUE_BATCH: "b20261101-1", LAND_QUEUE_BRANCHES: "a,b" }, new Date("2026-11-01T12:00:00Z"));
    expect(written.path).toBe(join(dir, ".git", "oppi", "land-queue", "red-lanes.jsonl"));
    const [row] = rows(written.path!);
    expect(row).toEqual({
      at: "2026-11-01T12:00:00.000Z", batch: "b20261101-1", branches: ["a", "b"], head: row.head, lane: "ui-ipad", profile: "ipad", exit: 1, seconds: 612,
      tests: ["OppiUITests/A/testB"], cause_guess: "test-failure", cause_evidence: "OppiUITests/A/testB", cause_confirmed: null,
    });
    expect(row.head).toMatch(/^[0-9a-f]{40}$/);
  });

  test("the pre-push CLI records a failed server lane of a batch from its log", () => {
    const dir = checkout();
    const log = join(dir, "server.log");
    writeFileSync(log, " FAIL  tests/search-index.test.ts > search > ranks\n");
    const run = Bun.spawnSync(["bun", join(import.meta.dir, "gate-report.ts"), "red-lane", "--lane", "server", "--exit", "1", "--seconds", "140", "--log", log], {
      cwd: dir, env: { ...process.env, LAND_QUEUE_BATCH: "b1" },
    });
    expect(run.exitCode).toBe(0);
    expect(rows(join(dir, ".git", "oppi", "land-queue", "red-lanes.jsonl"))[0]).toMatchObject({
      batch: "b1", lane: "server", exit: 1, seconds: 140, tests: ["server/tests/search-index.test.ts > search > ranks"], cause_guess: "test-failure",
    });
  });
});

describe("lane budgets", () => {
  const budgets = {
    "unit-full": { measure: "longest-shard" as const, seconds: 240 },
    "ui-ipad": { measure: "median-test" as const, seconds: 45 },
    server: { measure: "wall" as const, seconds: 180 },
  };

  test("each lane is measured by its own budget; over budget is a warning that names the config", () => {
    expect(budgetVerdict("unit-full", { wall: 300, longestShard: 224 }, budgets)).toEqual({ line: "budget unit-full: longest shard 224s of 240s, wall 300s" });
    const over = budgetVerdict("unit-full", { wall: 330, longestShard: 261 }, budgets);
    expect(over.warning).toBe("WARNING unit-full over budget: longest shard 261s > 240s; budgets live in dev/testing/lane-budgets.json");
    expect(budgetVerdict("ui-ipad", { wall: 640, medianTest: 52.25, tests: 14 }, budgets).warning).toBe(
      "WARNING ui-ipad over budget: median test 52.3s > 45s over 14 tests; budgets live in dev/testing/lane-budgets.json",
    );
    expect(budgetVerdict("server", { wall: 180 }, budgets)).toEqual({ line: "budget server: wall 180s of 180s" });
    expect(budgetVerdict("e2e", { wall: 300 }, budgets)).toEqual({ line: "budget e2e: wall 300s, no budget" });
    expect(budgetVerdict("ui-ipad", { wall: 20, tests: 0 }, budgets)).toEqual({ line: "budget ui-ipad: wall 20s; median test not measured (budget 45s)" });
  });

  test("a budget file or entry that cannot be read is a warning, never a throw, and the readable entries still apply", () => {
    const dir = checkout();
    const path = join(dir, "budgets.json");
    writeFileSync(path, JSON.stringify({ server: { measure: "p90", seconds: 180 }, "unit-full": { measure: "longest-shard", seconds: 240 } }));
    const partly = loadBudgets(path);
    expect(partly.budgets).toEqual({ "unit-full": { measure: "longest-shard", seconds: 240 } });
    expect(partly.warnings).toEqual([expect.stringContaining("WARNING lane budget 'server' ignored")]);
    writeFileSync(path, "{ broken");
    const broken = loadBudgets(path);
    expect(broken.budgets).toEqual({});
    expect(broken.warnings).toEqual([expect.stringContaining("WARNING lane budgets unreadable, no lane has a budget")]);
  });
});
