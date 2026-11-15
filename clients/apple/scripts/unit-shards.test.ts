import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { failedTestIds, infrastructureFailure, parseTestResults, partition, readFailures, recordWeights, scanTestTypes, shardFlags, shardTests, splitQuarantine, unmatchedSelectors, verdict, type TestType } from "./unit-shards";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";

// Some tests spawn a Bun or shell child; see sim-pool-test-support.ts for the sizing.
setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

const source = `import Testing

@Suite("Mic button orb layout")
@MainActor
struct MicButtonOrbLayoutTests {
    @Test func idle() {}
    @Test(arguments: [1, 2]) func sizes(_ n: Int) {}
    struct Nested {
        @Test func inner() {}
    }
}

private struct Helper {}

extension MicButtonOrbLayoutTests {
    @Test func more() {}
}

final class CacheTests {
    @Test func evicts() {}
}

@Test func topLevel() {}
`;

describe("unit shards", () => {
  test("scan finds top-level test types with their suite names and folds in extensions and nested suites", () => {
    expect(scanTestTypes([{ path: "A.swift", text: source }, { path: "B.swift", text: "struct NoTests {}\n" }])).toEqual([
      { name: "CacheTests", display: "CacheTests", tests: 1 },
      { name: "MicButtonOrbLayoutTests", display: "Mic button orb layout", tests: 4 },
    ]);
  });

  test("shards balance recorded seconds, and the last shard runs everything the others do not", () => {
    const types: TestType[] = ["A", "B", "C", "D", "E"].map((name) => ({ name, display: name, tests: 1 }));
    const parts = partition(types, { A: 100, B: 60, C: 50, D: 40 }, 3);
    expect(parts.map((part) => part.map((type) => type.name))).toEqual([["A"], ["B", "E"], ["C", "D"]]);
    expect(shardFlags(parts, 0)).toEqual(["-only-testing:OppiTests/A"]);
    expect(shardFlags(parts, 2)).toEqual([
      "-only-testing:OppiTests",
      "-skip-testing:OppiTests/A",
      "-skip-testing:OppiTests/B",
      "-skip-testing:OppiTests/E",
    ]);
  });

  test("quarantine entries block once their decision date has passed", () => {
    const entry = (id: string, expires: string) => ({ id, owner: "o", reason: "r", addedAt: "2026-10-01", expires });
    const { active, expired } = splitQuarantine([entry("A", "2026-10-22"), entry("B", "2026-10-21")], "2026-10-22");
    expect(active.map((e) => e.id)).toEqual(["A"]);
    expect(expired.map((e) => e.id)).toEqual(["B"]);
  });

  test("failed tests come from the xcresult tree, nested suites included", () => {
    const tree = JSON.stringify({
      testNodes: [{
        nodeType: "Test Plan", children: [{
          nodeType: "Unit test bundle", children: [
            { nodeType: "Test Suite", children: [
              { nodeType: "Test Case", result: "Failed", nodeIdentifier: "SSHTerminalTests/aPasswordPrompt()" },
              { nodeType: "Test Case", result: "Passed", nodeIdentifier: "SSHTerminalTests/ok()" },
              { nodeType: "Test Suite", children: [{ nodeType: "Test Case", result: "Failed", nodeIdentifier: "Outer/Inner/x()" }] },
            ] },
          ],
        }],
      }],
    });
    expect(failedTestIds(tree)).toEqual(["SSHTerminalTests/aPasswordPrompt()", "Outer/Inner/x()"]);
    expect(failedTestIds("Error: bundle is incomplete")).toBeUndefined();
  });

  test("a selector matches listed tests by name or by type, ignoring Swift Testing's parameter lists on both sides", () => {
    const listed = ["FooTests/testB(arg:)", "Outer/Inner/test()"];
    expect(unmatchedSelectors(["OppiTests/FooTests/testB", "OppiTests/FooTests/testB(arg:)", "OppiTests/Outer/Inner", "OppiTests/Outer/Inner/test"], listed)).toEqual([]);
    expect(unmatchedSelectors(["OppiTests/Outer/Inne", "OppiTests/FooTests/testB/x"], listed)).toEqual(["OppiTests/Outer/Inne", "OppiTests/FooTests/testB/x"]);
  });

  test("reads the failures of a full shard's tests JSON, which is several MiB", () => {
    // ~0.7 KB per test, 4,300 tests: more than Bun's default 1 MiB spawn buffer.
    const printTree = `
      const cases = Array.from({ length: 4300 }, (_, i) => ({
        nodeType: "Test Case", result: i === 4000 ? "Failed" : "Passed", nodeIdentifier: "Suite/test" + i + "()",
        name: "test" + i + "()", details: "x".repeat(600),
      }));
      process.stdout.write(JSON.stringify({ testNodes: [{ nodeType: "Test Suite", children: cases }] }));`;
    const failures = readFailures(process.execPath, ["-e", printTree]);
    expect(failures).toEqual({ ids: ["Suite/test4000()"] });
  });

  test("an unreadable xcresulttool result is a reason that names what went wrong", () => {
    const failed = readFailures("/bin/sh", ["-c", "echo 'bad bundle' >&2; exit 3"]);
    expect(failed).not.toHaveProperty("ids");
    expect(failed).toHaveProperty("reason");
    const reason = (failed as { reason: string }).reason;
    expect(reason).toContain("3");
    expect(reason).toContain("bad bundle");
    const garbled = readFailures("/bin/sh", ["-c", "printf 'Error: incomplete'"]);
    expect(garbled).not.toHaveProperty("ids");
    expect(garbled).toHaveProperty("reason");
  });

  test("recorded seconds add up a type's test durations across shards and drop types the scan did not find", () => {
    const types: TestType[] = [
      { name: "MicTests", display: "Mic", tests: 3 },
      { name: "CacheTests", display: "Cache", tests: 1 },
    ];
    const testCase = (id: string, seconds: number) => ({ nodeType: "Test Case", nodeIdentifier: id, durationInSeconds: seconds });
    const shard = (...children: object[]) => JSON.stringify({ testNodes: [{ nodeType: "Test Suite", children }] });
    const weights = recordWeights(
      [
        shard(testCase("MicTests/idle()", 0.25), { nodeType: "Test Suite", children: [testCase("MicTests/sizes(_:)", 1.5), testCase("GoneTests/old()", 9)] }),
        shard(testCase("MicTests/more()", 0.5), testCase("CacheTests/evicts()", 0.0004)),
      ],
      types,
    );
    expect(weights).toEqual({ MicTests: 2.25, CacheTests: 0 });
  });

  test("a shard that ran no tests is an infrastructure failure naming sim-pool's own error, not a test failure", () => {
    const busy = "[sim-pool] All 6 slots (slots 0-5) busy, waiting up to 60s...\nerror: all 6 simulator slots (slots 0-5) are busy or quarantined (waited 60s)\n";
    expect(infrastructureFailure({ code: 1, tests: 0 }, busy)).toBe(
      "the shard ran no tests (exit 1): all 6 simulator slots (slots 0-5) are busy or quarantined (waited 60s)",
    );
    expect(infrastructureFailure({ code: 1, tests: 0 }, "xcodebuild died\n")).toBe("the shard ran no tests (exit 1)");
    expect(infrastructureFailure({ code: 0, tests: 0 }, "")).toBe("the shard exited 0 but ran no tests");
    // A shard that ran tests and failed is a test failure, even with an `error:` line in its output.
    expect(infrastructureFailure({ code: 1, tests: 40 }, "error: something\n")).toBeUndefined();
  });

  test("the gate verdict keeps test failures and infrastructure failures apart", () => {
    expect(verdict([], [])).toBe("PASSED");
    expect(verdict(["shard-2"], [])).toBe("FAILED (test failures in shard-2)");
    expect(verdict([], ["shard-1"])).toBe("FAILED (INFRASTRUCTURE failure, no tests ran in shard-1)");
    expect(verdict(["shard-3"], ["shard-1"])).toBe("FAILED (test failures in shard-3; INFRASTRUCTURE failure, no tests ran in shard-1)");
    // A shard whose result cannot be read is never said to have run no tests.
    expect(verdict([], ["shard-1", "shard-3"], ["shard-3"])).toBe("FAILED (INFRASTRUCTURE failure, no tests ran in shard-1; INFRASTRUCTURE failure, result unreadable in shard-3)");
  });

  test("a shard's test count is its xcresult's, and an unreadable result is reported as such, never as zero tests", () => {
    const dir = mkdtempSync(join(tmpdir(), "unit-shards-"));
    try {
      // The pool log's run line was glued to a simulator line and is not read at all: the count is the xcresult's.
      writeFileSync(join(dir, "pool.log"), "... Couldn't open .../Managed Pr✔ Test run with 5127 tests in 550 suites passed after 229.603 seconds.\n");
      const summary = (record: object) => {
        writeFileSync(join(dir, "summary.json"), JSON.stringify({ log_path: join(dir, "pool.log"), ...record }));
        return shardTests(join(dir, "summary.json"));
      };
      const counts = { bundle: "/r/Run.xcresult", result: "Passed", total: 5127, passed: 5127, failed: 0, skipped: 0, expectedFailures: 0, failures: [] };
      expect(summary({ exit_code: 0, test_results: counts })).toEqual({ tests: 5127 });
      // A UI run that died partway still lists the tests it reached: a test failure, not an infrastructure one.
      const died = summary({ exit_code: 65, test_results: { ...counts, result: "Failed", total: 2, passed: 1, failed: 1 } });
      expect(infrastructureFailure({ code: 65, ...died }, "")).toBeUndefined();
      // Stopped after its summary, xcodebuild left no readable bundle.
      const stopped = summary({ exit_code: 0, completion_hang_detected: true, test_results: { bundle: "/r/Run.xcresult", unreadable: "xcresulttool exit 1: Info.plist ... does not exist" } });
      expect(stopped).toEqual({ tests: 0, unreadable: "xcresulttool exit 1: Info.plist ... does not exist" });
      expect(infrastructureFailure({ code: 0, ...stopped }, "")).toBe("result unreadable (exit 0): xcresulttool exit 1: Info.plist ... does not exist");
      expect(summary({ exit_code: 1, incomplete: true }).unreadable).toContain("could not finish the run cleanly");
      // No summary, or one with no test run (a build that failed), ran nothing.
      expect(summary({ exit_code: 65 })).toEqual({ tests: 0 });
      expect(shardTests(undefined)).toEqual({ tests: 0 });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("xcresult summary JSON gives the verdict, counts, and each failing test with its message's first line", () => {
    const parsed = parseTestResults(JSON.stringify({
      result: "Failed", totalTestCount: 3, passedTests: 1, failedTests: 1, skippedTests: 1, expectedFailures: 0,
      testFailures: [
        { targetName: "OppiUITests", testIdentifierString: "ScheduleUITests/testSwipe()", testName: "testSwipe()", failureText: `Failed to tap "day"\n${"Other,\n".repeat(50)}` },
        { targetName: "OppiTests", testName: "late()", failureText: "x".repeat(900) },
      ],
    }));
    expect(parsed).toMatchObject({ result: "Failed", total: 3, passed: 1, failed: 1, skipped: 1, expectedFailures: 0 });
    expect(parsed?.failures[0]).toEqual({ test: "OppiUITests/ScheduleUITests/testSwipe()", message: 'Failed to tap "day"' });
    expect(parsed?.failures[1]).toEqual({ test: "OppiTests/late()", message: "x".repeat(400) });
    expect(parseTestResults(JSON.stringify({ result: "Passed", totalTestCount: 1 }))).toBeUndefined();
    expect(parseTestResults("Error: Info.plist does not exist")).toBeUndefined();
  });
});
