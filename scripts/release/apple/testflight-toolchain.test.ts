import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  readXcodeVersion,
  runXcodebuild,
  useReleaseXcodeToolchain,
} from "./testflight";

const pinnedDeveloperDir = "/Applications/Xcode-27.1.app/Contents/Developer";

describe("TestFlight Xcode toolchain", () => {
  test("resolves the pinned Xcode 27.1 and reports xcodebuild -version", () => {
    const env: NodeJS.ProcessEnv = {};
    expect(useReleaseXcodeToolchain(env)).toBe(pinnedDeveloperDir);
    const reported = readXcodeVersion(env);
    const direct = spawnSync("xcodebuild", ["-version"], {
      env: { ...process.env, DEVELOPER_DIR: pinnedDeveloperDir },
      encoding: "utf8",
    });
    expect(direct.status).toBe(0);
    expect(reported).toBe((direct.stdout ?? "").trim());
    expect(reported.startsWith("Xcode 27.1\n")).toBeTrue();
    expect(reported).toContain("Build version ");
  });

  test("runXcodebuild passes the pinned DEVELOPER_DIR to the child", async () => {
    const directory = mkdtempSync(join(tmpdir(), "oppi-release-xcode-"));
    const executable = join(directory, "print-developer-dir");
    const log = join(directory, "xcodebuild.log");
    writeFileSync(
      executable,
      "#!/bin/sh\nprintf '%s\\n' \"$DEVELOPER_DIR\"\n",
    );
    chmodSync(executable, 0o755);
    const previous = process.env.DEVELOPER_DIR;
    delete process.env.DEVELOPER_DIR;
    try {
      await runXcodebuild(["-version"], log, 5, executable);
      expect(readFileSync(log, "utf8").trim()).toBe(pinnedDeveloperDir);
    } finally {
      if (previous === undefined) delete process.env.DEVELOPER_DIR;
      else process.env.DEVELOPER_DIR = previous;
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
