import { describe, expect, it } from "vitest";

import { compareNpmVersions, isNpmVersionNewer } from "../src/cli/npm-version.js";

describe("npm version comparison", () => {
  it("treats a stable release as newer than its prerelease", () => {
    expect(isNpmVersionNewer("0.44.0", "0.44.0-beta.1")).toBe(true);
    expect(isNpmVersionNewer("0.44.0-beta.1", "0.44.0")).toBe(false);
  });

  it("orders numeric and textual prerelease identifiers using SemVer", () => {
    expect(compareNpmVersions("1.0.0-beta.2", "1.0.0-beta.11")).toBeLessThan(0);
    expect(compareNpmVersions("1.0.0-beta.1", "1.0.0-beta.alpha")).toBeLessThan(0);
  });

  it("ignores build metadata", () => {
    expect(compareNpmVersions("1.2.3+build.2", "1.2.3+build.1")).toBe(0);
  });

  it("rejects invalid registry versions deterministically", () => {
    expect(() => compareNpmVersions("latest", "1.2.3")).toThrow("Invalid semantic version");
  });
});
