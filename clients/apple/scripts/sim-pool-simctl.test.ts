import { describe, expect, test } from "bun:test";
import {
  buildAttemptCommand,
  findMatchingPoolDevice,
  parseDevicesJson,
  resultBundlePathForAttempt,
  selectIosRuntime,
} from "./sim-pool-simctl";

describe("sim-pool-simctl", () => {
  test("retry result bundle paths stay unique", () => {
    expect(resultBundlePathForAttempt("/tmp/OppiTests.xcresult", 0)).toBe("/tmp/OppiTests.xcresult");
    expect(resultBundlePathForAttempt("/tmp/OppiTests.xcresult", 1)).toBe(
      "/tmp/OppiTests-retry1.xcresult",
    );
    expect(resultBundlePathForAttempt("/tmp/result", 2)).toBe("/tmp/result-retry2");
  });

  test("buildAttemptCommand rewrites both flag forms", () => {
    const spaced = buildAttemptCommand(1, [
      "xcodebuild",
      "test",
      "-resultBundlePath",
      "/tmp/OppiTests.xcresult",
      "-scheme",
      "OppiUnitTests",
    ]);
    expect(spaced[2]).toBe("-resultBundlePath");
    expect(spaced[3]).toBe("/tmp/OppiTests-retry1.xcresult");
    const inline = buildAttemptCommand(2, ["xcodebuild", "test", "-resultBundlePath=/tmp/OppiTests.xcresult"]);
    expect(inline[2]).toBe("-resultBundlePath=/tmp/OppiTests-retry2.xcresult");
  });

  test("matching pool device requires runtime and type", () => {
    const devices = parseDevicesJson(`{
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
          {
            "udid": "U1",
            "name": "Oppi-Pool-0",
            "state": "Booted",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
          {
            "udid": "U2",
            "name": "Oppi-Pool-0",
            "state": "Shutdown",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
          }
        ]
      }
    }`);
    const match = findMatchingPoolDevice(
      devices,
      0,
      "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
    );
    expect(match.match?.udid).toBe("U1");
    const mismatch = findMatchingPoolDevice(
      devices,
      0,
      "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
      "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    );
    expect(mismatch.match).toBeUndefined();
    expect(mismatch.mismatches.map((device) => device.udid).sort()).toEqual(["U1", "U2"]);
  });

  test("latest-stable skips beta runtimes", () => {
    const runtimes = [
      {
        identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
        platform: "iOS",
        isAvailable: true,
        version: "18.5",
        buildversion: "22F77",
        name: "iOS 18.5",
        bundlePath: "/r/18",
        runtimeRoot: "/r/18",
      },
      {
        identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
        platform: "iOS",
        isAvailable: true,
        version: "26.0",
        buildversion: "23A5276e",
        name: "iOS 26.0",
        bundlePath: "/r/26",
        runtimeRoot: "/r/26",
      },
    ];
    const stable = selectIosRuntime(runtimes, "latest-stable");
    expect(stable).toBe("com.apple.CoreSimulator.SimRuntime.iOS-18-5");
    const latest = selectIosRuntime(runtimes, "latest");
    expect(latest).toBe("com.apple.CoreSimulator.SimRuntime.iOS-26-0");
  });
});
