import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { checkPiReleaseVersions } from "../scripts/check-pi-release-versions.mjs";

const packages = [
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
];

describe("Pi release version guard", () => {
  it("runs before creating a release tarball", () => {
    const manifest = JSON.parse(
      readFileSync(new URL("../package.json", import.meta.url), "utf8"),
    ) as { scripts?: Record<string, string> };

    expect(manifest.scripts?.prepack).toContain("npm run check:pi-release-versions");
  });

  it("runs as a CLI from a path containing spaces", () => {
    const root = mkdtempSync(path.join(tmpdir(), "oppi guard "));
    const scriptsDir = path.join(root, "scripts");
    const scriptPath = path.join(scriptsDir, "check-pi-release-versions.mjs");
    const mockFetchPath = path.join(root, "mock-fetch.mjs");

    try {
      mkdirSync(scriptsDir);
      cpSync(new URL("../scripts/check-pi-release-versions.mjs", import.meta.url), scriptPath);
      writeFileSync(
        path.join(root, "package.json"),
        JSON.stringify({
          dependencies: Object.fromEntries(packages.map((name) => [name, "0.81.1"])),
        }),
      );
      writeFileSync(
        mockFetchPath,
        'globalThis.fetch = async () => new Response(JSON.stringify({ version: "0.81.1" }));\n',
      );

      const result = spawnSync(process.execPath, ["--import", mockFetchPath, scriptPath], {
        encoding: "utf8",
      });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain("Pi release dependencies match npm latest");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("passes when every release-critical Pi dependency matches npm latest", () => {
    const dependencies = Object.fromEntries(packages.map((name) => [name, "0.81.1"]));
    const latestVersions = Object.fromEntries(packages.map((name) => [name, "0.81.1"]));

    expect(checkPiReleaseVersions(dependencies, latestVersions)).toEqual([]);
  });

  it("reports stale, ranged, and missing Pi dependency versions", () => {
    const dependencies = {
      "@earendil-works/pi-ai": "0.80.10",
      "@earendil-works/pi-coding-agent": "^0.81.1",
    };
    const latestVersions = Object.fromEntries(packages.map((name) => [name, "0.81.1"]));

    expect(checkPiReleaseVersions(dependencies, latestVersions)).toEqual([
      "@earendil-works/pi-ai: package.json pins 0.80.10, npm latest is 0.81.1",
      "@earendil-works/pi-coding-agent: package.json must use exact version 0.81.1, found ^0.81.1",
      "@earendil-works/pi-tui: missing from package.json dependencies",
    ]);
  });
});
