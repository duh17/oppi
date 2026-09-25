import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { getPackageInfo } from "../src/version.js";

import {
  compareNpmVersions,
  isNpmVersionNewer,
  isValidNpmVersion,
} from "../src/cli/npm-version.js";

describe("oppi update registry version rule", () => {
  it.each([
    ["unknown", "1", "Could not determine the latest npm version"],
    ["current", "0", "already current or ahead"],
  ])("refuses %s without invoking install", (_name, fail, message) => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-update-"));
    try {
      const bin = join(dir, "bin");
      mkdirSync(bin);
      writeFileSync(
        join(bin, "npm"),
        `#!/bin/sh
if [ "$1" = "view" ]; then
  if [ "${fail}" = "1" ]; then exit 1; fi
  echo "${getPackageInfo().version}"
  exit 0
fi
if [ "$1" = "root" ]; then echo "${dir}/prefix/lib/node_modules"; exit 0; fi
echo "unexpected install" >&2
exit 44
`,
        { mode: 0o755 },
      );
      const run = spawnSync("bun", ["src/cli.ts", "update"], {
        cwd: process.cwd(),
        encoding: "utf8",
        timeout: 15_000,
        env: {
          ...process.env,
          HOME: dir,
          OPPI_DATA_DIR: join(dir, "data"),
          PATH: `${bin}:${process.env.PATH ?? ""}`,
        },
      });
      expect(run.status).toBe(1);
      expect(run.stdout).toContain(message);
      expect(run.stderr).not.toContain("unexpected install");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

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

  it("accepts exact SemVer strings and rejects tags", () => {
    expect(isValidNpmVersion("0.50.0")).toBe(true);
    expect(isValidNpmVersion("1.2.3-beta.1")).toBe(true);
    expect(isValidNpmVersion("latest")).toBe(false);
    expect(isValidNpmVersion("")).toBe(false);
  });
});
