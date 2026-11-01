import { describe, expect, test } from "bun:test";
import { completionWaitSeconds, withUnitDiagnosticsOff, zeroTestSummary } from "./sim-pool-ops";

const prelude = "Test Suite 'All tests' passed at 2026-11-01 10:00:00.000.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n◇ Test run started.\n";

describe("zero-test runs", () => {
  test("a finished run that counted zero tests is caught for Swift Testing and XCTest summaries alike", () => {
    expect(zeroTestSummary(`${prelude}✔ Test run with 0 tests passed after 0.001 seconds.\n`)).toBe("✔ Test run with 0 tests passed after 0.001 seconds.");
    // XCTest-only bundles (UI, E2E): the top-level suite result is the count.
    expect(zeroTestSummary("Test Suite 'Selected tests' passed at 2026-11-01 10:00:00.000.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n")).toBe(
      "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds",
    );
    // A Swift Testing run after XCTest's zero-test prelude, and an XCTest run with tests, ran something.
    expect(zeroTestSummary(`${prelude}✔ Test run with 9 tests in 1 suite passed after 1.2 seconds.\n`)).toBeUndefined();
    expect(zeroTestSummary("Test Suite 'Selected tests' failed at 2026-11-01 10:00:00.000.\n\t Executed 3 tests, with 1 failure (0 unexpected) in 9.0 (9.1) seconds\n")).toBeUndefined();
    // No summary at all is a run that stopped early, not proof that the filter matched nothing.
    expect(zeroTestSummary("** BUILD INTERRUPTED **\n")).toBeUndefined();
  });
});

describe("unit test runs", () => {
  test("a unit-scheme test run collects no failure diagnostics unless the caller asks for them; UI and E2E runs keep theirs", () => {
    const phase = ["test-without-building", "-xctestrun", "/r/OppiUnitTests.xctestrun", "-only-testing:OppiTests/FooTests"];
    expect(withUnitDiagnosticsOff(["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests"], phase)).toEqual([...phase, "-collect-test-diagnostics", "never"]);
    expect(withUnitDiagnosticsOff(["-scheme", "OppiUnitTests", "test", "-collect-test-diagnostics", "on-failure"], phase)).toEqual(phase);
    expect(withUnitDiagnosticsOff(["-scheme", "Oppi", "test", "-only-testing:OppiUITests/AUITests"], phase)).toEqual(phase);
  });

  test("a finished Swift Testing run waits at most 5 s for xcodebuild to exit, unless its caller asked for diagnostics; an XCTest run keeps the configured wait", () => {
    const config = { completionTimeout: 30 };
    const swift = { summary: "✘ Test run with 9 tests in 1 suite failed after 11.2 seconds with 3 issues." };
    const unit = ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests"];
    expect(completionWaitSeconds(config, swift, unit)).toBe(5);
    expect(completionWaitSeconds(config, swift, [...unit, "-collect-test-diagnostics", "never"])).toBe(5);
    // Diagnostics are collected after the summary: a caller who wants them gets the full wait.
    expect(completionWaitSeconds(config, swift, [...unit, "-collect-test-diagnostics", "on-failure"])).toBe(30);
    expect(completionWaitSeconds(config, { summary: "Executed 5 tests, with 1 failure (1 unexpected) in 90.0 (90.1) seconds" }, ["-scheme", "Oppi", "test"])).toBe(30);
    // A shorter configured wait still wins.
    expect(completionWaitSeconds({ completionTimeout: 1 }, { summary: "✔ Test run with 9 tests in 1 suite passed after 1.0 seconds." }, unit)).toBe(1);
  });
});
