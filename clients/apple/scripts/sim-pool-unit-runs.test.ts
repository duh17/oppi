import { describe, expect, test } from "bun:test";
import { completionWaitSeconds, withUnitDiagnosticsOff } from "./sim-pool-ops";

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
