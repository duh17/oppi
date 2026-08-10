import { describe, expect, test } from "bun:test";
import {
  readTargetSetting,
  validateReleasePreflight,
  type ReleasePreflightInput,
} from "./preflight";

function validInput(): ReleasePreflightInput {
  return {
    targetBuild: 44,
    whatsNewStartBuild: 43,
    serverVersion: "0.46.0",
    mirrorVersion: "0.46.0",
    iosMarketingVersion: "1.1.0",
    intent: {
      schemaVersion: 1,
      components: {
        server: { release: true, version: "0.46.0" },
        mirror: { release: true, version: "0.46.0" },
        ios: {
          release: true,
          target: "Oppi",
          marketingVersion: "1.1.0",
          build: 44,
          whatsNewFromBuild: 43,
        },
      },
      changelogPath: ".internal/release-notes/testflight-build-44-changelog.md",
      whatToTestPath:
        ".internal/release-notes/testflight-build-44-what-to-test.md",
    },
    changelogRelativePath:
      ".internal/release-notes/testflight-build-44-changelog.md",
    whatToTestRelativePath:
      ".internal/release-notes/testflight-build-44-what-to-test.md",
    serverManifestVersion: "0.46.0",
    lockfileVersion: "0.46.0",
    lockfileRootVersion: "0.46.0",
    mirrorManifestVersion: "0.46.0",
    iosBuilds: {
      Oppi: 44,
      OppiActivityExtension: 44,
      OppiShareExtension: 44,
      OppiControlWidget: 44,
    },
    whatsNewSource: 'Text("Builds 43–44")',
    changelog: "# TestFlight Build 44\n\n## Added\n- Provider models.",
    whatToTest: "What's changed\n- Requires oppi-server 0.46.0.",
    trackedReleasePaths: [
      "release/intent.json",
      "scripts/release/preflight.ts",
      "scripts/release/release-notes.ts",
      "scripts/release/apple/testflight.ts",
      "scripts/release/apple/asc.ts",
    ],
  };
}

describe("release preflight", () => {
  test("accepts matching release coordinates and complete notes", () => {
    expect(validateReleasePreflight(validInput())).toEqual([]);
  });

  test("accepts a matching mirror version when the mirror is not released", () => {
    const input = validInput();
    input.intent.components.mirror.release = false;
    expect(validateReleasePreflight(input)).toEqual([]);
  });

  test("accepts the compact Build 45 caption while covering the prior build", () => {
    const input = validInput();
    input.targetBuild = 45;
    input.intent.components.ios.build = 45;
    input.iosBuilds = {
      Oppi: 45,
      OppiActivityExtension: 45,
      OppiShareExtension: 45,
      OppiControlWidget: 45,
    };
    input.whatsNewSource = 'Text("Build 45 · Changes since Build 43")';
    expect(validateReleasePreflight(input)).toEqual([]);
  });

  test("rejects version, build, notes, and tracking drift", () => {
    const input = validInput();
    input.mirrorManifestVersion = "0.44.0";
    input.iosBuilds.OppiShareExtension = 43;
    input.whatsNewSource = 'Text("Build 43")';
    input.whatToTest = "Draft: fill this in";
    input.trackedReleasePaths[0] = "missing:release/intent.json";

    expect(validateReleasePreflight(input)).toEqual([
      "oppi-mirror version 0.44.0 does not match target 0.46.0",
      "OppiShareExtension build 43 does not match 44",
      "What's New does not identify builds 43–44",
      "release notes still contain Draft placeholders",
      "required release path is not tracked: release/intent.json",
    ]);
  });

  test("rejects drift between release intent and candidate coordinates", () => {
    const input = validInput();
    input.intent.components.server.version = "0.45.0";
    input.intent.components.mirror.version = "0.45.0";
    input.intent.components.ios.build = 45;
    input.intent.whatToTestPath = ".internal/release-notes/wrong.md";
    expect(validateReleasePreflight(input)).toEqual([
      "release intent does not authorize the target server version",
      "release intent mirror version does not match the candidate",
      "release intent iOS coordinates do not match the candidate",
      "release intent note paths do not match the candidate files",
    ]);
  });

  test("rejects target-only What's New when the prior build was missed", () => {
    const input = validInput();
    input.whatsNewSource = 'Text("Build 44")';
    expect(validateReleasePreflight(input)).toContain(
      "What's New does not identify builds 43–44",
    );
  });
});

describe("project setting parser", () => {
  test("reads only the named target", () => {
    const yaml = `targets:
  Oppi:
    settings:
      base:
        CURRENT_PROJECT_VERSION: 44
  OppiMac:
    settings:
      base:
        CURRENT_PROJECT_VERSION: 40
`;
    expect(readTargetSetting(yaml, "Oppi", "CURRENT_PROJECT_VERSION")).toBe(
      "44",
    );
    expect(readTargetSetting(yaml, "OppiMac", "CURRENT_PROJECT_VERSION")).toBe(
      "40",
    );
  });
});
