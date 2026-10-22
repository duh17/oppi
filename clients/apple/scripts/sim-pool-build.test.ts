import { describe, expect, test } from "bun:test";
import { completionArgvForXctestrun, planRun } from "./sim-pool-build";

describe("planRun", () => {
  test("a test run builds once without test-execution flags and hands them to the test phase", () => {
    const plan = planRun([
      "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test",
      "-only-testing:OppiTests/FooTests", "-skip-testing", "OppiTests/BarTests",
      "-resultBundlePath", "/tmp/r.xcresult", "-retry-tests-on-failure", "-test-iterations", "2",
      "-enableCodeCoverage", "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=X",
    ]);
    expect(plan).toEqual({
      kind: "split",
      scheme: "OppiUnitTests",
      buildArgv: [
        "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "build-for-testing",
        "-enableCodeCoverage", "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=X",
      ],
      testFlags: [
        "-only-testing:OppiTests/FooTests", "-skip-testing", "OppiTests/BarTests",
        "-resultBundlePath", "/tmp/r.xcresult", "-retry-tests-on-failure", "-test-iterations", "2",
        "-enableCodeCoverage", "YES",
      ],
    });
  });

  test("actions without a test run build in place; test products the caller owns only need a slot", () => {
    const build = ["-scheme", "Oppi", "build-for-testing"];
    expect(planRun(build)).toEqual({ kind: "build", buildArgv: build });
    expect(planRun(["-scheme", "Oppi", "build"])).toEqual({ kind: "build", buildArgv: ["-scheme", "Oppi", "build"] });
    expect(planRun(["-scheme", "Oppi", "test-without-building"])).toEqual({ kind: "slot", readsDerivedData: true });
    expect(planRun(["test-without-building", "-xctestrun", "/x/a.xctestrun"])).toEqual({ kind: "slot", readsDerivedData: false });
    // A test plan selects its own xctestrun; no scheme leaves nothing to find one by.
    expect(planRun(["-scheme", "Oppi", "-testPlan", "P", "test"])).toEqual({ kind: "slot", readsDerivedData: false });
    expect(planRun(["test"])).toEqual({ kind: "slot", readsDerivedData: true });
  });

  test("a unit-shard xctestrun run is parsed for completion like the scheme test it stands for", () => {
    const shard = ["test-without-building", "-xctestrun", "/r/Build/Products/OppiUnitTests_iphonesimulator27.1-arm64.xctestrun",
      "-only-testing:OppiTests", "-skip-testing:OppiTests/A"];
    expect(completionArgvForXctestrun(shard)).toEqual(["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests", "-skip-testing:OppiTests/A"]);
    // Repetition changes what a finished summary means; leave such runs unparsed.
    expect(completionArgvForXctestrun([...shard, "-test-iterations", "3"])).toBeUndefined();
  });
});
