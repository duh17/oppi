import { describe, expect, test } from "bun:test";

import {
  nextIosReleaseBuild,
  parseIosProjectBuild,
} from "./next-ios-build.ts";

describe("next iOS release build", () => {
  test("keeps an unuploaded local candidate instead of skipping it", () => {
    expect(nextIosReleaseBuild(48, 47)).toBe(48);
  });

  test("increments when the current build already shipped", () => {
    expect(nextIosReleaseBuild(47, 47)).toBe(48);
    expect(nextIosReleaseBuild(48, 48)).toBe(49);
  });

  test("increments when last shipped is unknown", () => {
    expect(nextIosReleaseBuild(47, null)).toBe(48);
  });

  test("reads the Oppi CURRENT_PROJECT_VERSION from project.yml", () => {
    expect(
      parseIosProjectBuild(`
        Oppi:
          settings:
            MARKETING_VERSION: "1.1.2"
            CURRENT_PROJECT_VERSION: 47
        OppiMac:
          settings:
            CURRENT_PROJECT_VERSION: 40
      `),
    ).toBe(47);
  });
});
