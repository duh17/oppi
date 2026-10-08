import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  readXcodeVersion,
  runXcodebuild,
  useReleaseXcodeToolchain,
} from "./testflight";

const versionText = "Xcode 27.1\nBuild version 27A9275";

describe("TestFlight Xcode toolchain", () => {
  test("logs xcodebuild -version from the toolchain on PATH", () => {
    const directory = mkdtempSync(join(tmpdir(), "oppi-release-xcode-version-"));
    const developerDir = join(directory, "Developer");
    const bin = join(directory, "bin");
    mkdirSync(developerDir);
    mkdirSync(bin);
    const marker = join(directory, "xcodebuild.calls");
    writeFileSync(
      join(bin, "xcodebuild"),
      `#!/bin/sh\nprintf '%s\\n' "$1" >> "${marker}"\nprintf '%s\\n' 'Xcode 27.1' 'Build version 27A9275'\n`,
    );
    chmodSync(join(bin, "xcodebuild"), 0o755);
    const env: NodeJS.ProcessEnv = {
      PATH: bin,
      DEVELOPER_DIR: developerDir,
    };
    try {
      expect(useReleaseXcodeToolchain(env)).toBe(developerDir);
      expect(readXcodeVersion(env)).toBe(versionText);
      expect(readFileSync(marker, "utf8").trim()).toBe("-version");
      expect(env.DEVELOPER_DIR).toBe(developerDir);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("runXcodebuild forwards an explicit DEVELOPER_DIR", async () => {
    const directory = mkdtempSync(join(tmpdir(), "oppi-release-xcode-"));
    const developerDir = join(directory, "Developer");
    mkdirSync(developerDir);
    const executable = join(directory, "print-developer-dir");
    const log = join(directory, "xcodebuild.log");
    writeFileSync(executable, "#!/bin/sh\nprintf '%s\\n' \"$DEVELOPER_DIR\"\n");
    chmodSync(executable, 0o755);
    const previous = process.env.DEVELOPER_DIR;
    process.env.DEVELOPER_DIR = developerDir;
    try {
      await runXcodebuild(["-version"], log, 5, executable);
      expect(readFileSync(log, "utf8").trim()).toBe(developerDir);
    } finally {
      if (previous === undefined) delete process.env.DEVELOPER_DIR;
      else process.env.DEVELOPER_DIR = previous;
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
