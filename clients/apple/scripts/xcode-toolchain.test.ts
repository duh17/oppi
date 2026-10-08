import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyXcodeToolchain, defaultXcodeApp, resolveDeveloperDir } from "./xcode-toolchain";

describe("xcode toolchain resolution", () => {
  const temps: string[] = [];
  afterEach(() => {
    for (const dir of temps.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function fakeXcodeApp(): string {
    const app = mkdtempSync(join(tmpdir(), "oppi-xcode-"));
    temps.push(app);
    mkdirSync(join(app, "Contents", "Developer"), { recursive: true });
    return app;
  }

  test("explicit DEVELOPER_DIR wins over the default", () => {
    const app = fakeXcodeApp();
    const explicit = join(app, "Contents", "Developer");
    expect(resolveDeveloperDir({ DEVELOPER_DIR: explicit }, "/nonexistent/Xcode.app")).toBe(explicit);
  });

  test("an unset DEVELOPER_DIR defaults to the pinned Xcode and is exported", () => {
    const app = fakeXcodeApp();
    expect(resolveDeveloperDir({}, app)).toBe(join(app, "Contents", "Developer"));
    expect(defaultXcodeApp()).toBe("/Applications/Xcode-27.1.app");
  });

  test("a missing toolchain fails with an actionable message", () => {
    expect(() => resolveDeveloperDir({}, "/nonexistent/Xcode.app")).toThrow(
      /Xcode toolchain not found: \/nonexistent\/Xcode\.app.*DEVELOPER_DIR/,
    );
    expect(() => resolveDeveloperDir({ DEVELOPER_DIR: "/nonexistent/Developer" }, "/x")).toThrow(
      "DEVELOPER_DIR points at a missing directory",
    );
  });

  test("applyXcodeToolchain exports the default toolchain into an env without DEVELOPER_DIR", () => {
    const app = fakeXcodeApp();
    const env: NodeJS.ProcessEnv = {};
    applyXcodeToolchain(env, app);
    expect(env.DEVELOPER_DIR).toBe(join(app, "Contents", "Developer"));
  });
});
