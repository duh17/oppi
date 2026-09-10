import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  applyPoolBuildSettings,
  applyRunCheckout,
  ensureOppiTestsInfoPlist,
  extractBuildTimingSummary,
  extractCompilerLinkerErrors,
  extractRootFlag,
  loadConfig,
  normalizeCommandArgs,
  normalizeOppiRoot,
  normalizeVideoPolicy,
  parsePruneKeepSlots,
  PoolError,
  prepareSimulator,
  pruneBuildKind,
  validateCommandGuardrails,
} from "./sim-pool-ops";
import { CommandSession } from "./sim-pool-supervise";

const scriptDir = import.meta.dir;

describe("sim-pool-ops helpers", () => {
  test("compiler diagnostics are kept and rebuild logs are not", () => {
    const log = `--- xcodebuild: WARNING: Using the first of multiple matching destinations:
2026-08-01 10:19:05.934244+0000 Oppi[46329:117234] [LoadSession] full rebuild: 2 events → 2 items
/Users/runner/work/oppi/Foo.swift:12:7: error: cannot find 'missing' in scope
Sources/parser.c:8:2: error: expected expression
error: emit-module command failed with exit code 1
clang: error: linker command failed with exit code 1
ld: symbol(s) not found for architecture arm64
swiftc: error: unexpected input file

Build Timing Summary

SwiftCompile (33 tasks) | 1084.000 seconds
Ld (8 tasks) | 12.000 seconds

Test Suite 'All tests' started.
`;
    const errors = extractCompilerLinkerErrors(log);
    expect(errors.some((line) => line.includes("xcodebuild:"))).toBe(false);
    expect(errors.some((line) => line.includes("rebuild:"))).toBe(false);
    for (const diagnostic of [
      "/Users/runner/work/oppi/Foo.swift:12:7: error: cannot find 'missing' in scope",
      "Sources/parser.c:8:2: error: expected expression",
      "error: emit-module command failed with exit code 1",
      "clang: error: linker command failed with exit code 1",
      "ld: symbol(s) not found for architecture arm64",
      "swiftc: error: unexpected input file",
    ]) {
      expect(errors).toContain(diagnostic);
    }
    const timing = extractBuildTimingSummary(log).join("\n");
    expect(timing).toContain("SwiftCompile (33 tasks) | 1084.000 seconds");
    expect(timing).not.toContain("Test Suite");
  });

  test("index store injection respects overrides", () => {
    const config = loadConfig({ OPPI_SIM_POOL_COUNT: "1" }, process.cwd(), scriptDir);
    expect(applyPoolBuildSettings(config, ["xcodebuild", "test"])).toEqual([
      "COMPILER_INDEX_STORE_ENABLE=NO",
    ]);
    expect(
      applyPoolBuildSettings(config, ["xcodebuild", "test", "COMPILER_INDEX_STORE_ENABLE=YES"]),
    ).toEqual([]);
    const enabled = loadConfig({ OPPI_SIM_POOL_INDEX_STORE: "1" }, process.cwd(), scriptDir);
    expect(applyPoolBuildSettings(enabled, ["xcodebuild", "test"])).toEqual([]);
  });

  test("OppiTests-only Oppi scheme is rewritten unless overridden", () => {
    const config = loadConfig({}, process.cwd(), scriptDir);
    const rewritten = normalizeCommandArgs(config, [
      "xcodebuild",
      "-project",
      "Oppi.xcodeproj",
      "-scheme",
      "Oppi",
      "test",
      "-only-testing:OppiTests/Foo",
    ]);
    expect(rewritten.args.join(" ")).toContain("-scheme OppiUnitTests");
    const e2e = normalizeCommandArgs(config, [
      "xcodebuild",
      "-scheme",
      "Oppi",
      "test",
      "-only-testing:OppiE2ETests/Foo",
    ]);
    expect(e2e.args.join(" ")).toContain("-scheme Oppi");
    expect(e2e.args.join(" ")).not.toContain("OppiUnitTests");
    const mixed = normalizeCommandArgs(config, [
      "xcodebuild",
      "-scheme",
      "Oppi",
      "test",
      "-only-testing:OppiTests/Foo",
      "-only-testing:OppiUITests/Bar",
    ]);
    expect(mixed.args.join(" ")).not.toContain("OppiUnitTests");
    const allow = loadConfig({ OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME: "1" }, process.cwd(), scriptDir);
    const kept = normalizeCommandArgs(allow, [
      "xcodebuild",
      "-scheme",
      "Oppi",
      "test",
      "-only-testing:OppiTests/Foo",
    ]);
    expect(kept.args.join(" ")).not.toContain("OppiUnitTests");
  });

  test("guardrails reject injected destination", () => {
    const config = loadConfig({}, process.cwd(), scriptDir);
    expect(() => validateCommandGuardrails(config, ["xcodebuild", "-destination", "id=1"])).toThrow(
      PoolError,
    );
  });

  test("video policy aliases", () => {
    expect(normalizeVideoPolicy("1")).toBe("always");
    expect(normalizeVideoPolicy("on-failure")).toBe("on-failure");
    expect(normalizeVideoPolicy("off")).toBe("off");
  });

  test("prune classification and keep-slots", () => {
    expect(pruneBuildKind("logs")).toBeNull();
    expect(pruneBuildKind("pool-0")).toBe("pool");
    expect(pruneBuildKind("pool-foo")).toBeNull();
    expect(pruneBuildKind("derived-data-foo")).toBe("derived");
    expect(pruneBuildKind("mac-vocab-optin")).toBe("mac-stale");
    expect(pruneBuildKind("mac-tests")).toBeNull();
    expect(parsePruneKeepSlots("0-5")).toEqual({ start: 0, end: 5 });
    expect(() => parsePruneKeepSlots("5-0")).toThrow(PoolError);
  });
});

const opsTemps: string[] = [];

afterEach(() => {
  for (const dir of opsTemps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("sim-pool-ops boot readiness", () => {
  test("failed group proof does not become a readiness retry", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-sim-ops-boot-"));
    opsTemps.push(root);
    const bin = join(root, "bin");
    mkdirSync(bin);
    writeFileSync(
      join(root, "devices.json"),
      JSON.stringify({
        devices: {
          runtime: [
            {
              udid: "PRIVATE-BOOT",
              name: "Oppi-Pool-0",
              state: "Booted",
              isAvailable: true,
              deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
            },
          ],
        },
      }),
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/bin/bash
set -euo pipefail
case "$1 $2" in
'simctl list') /bin/cat "$OPPI_FAKE_ROOT/devices.json" ;;
'simctl bootstatus')
  n=0
  [[ ! -f "$OPPI_FAKE_ROOT/attempts" ]] || n=$(<"$OPPI_FAKE_ROOT/attempts")
  n=$((n+1)); printf '%s' "$n" > "$OPPI_FAKE_ROOT/attempts"
  if [[ "$n" == 1 ]]; then : > "$OPPI_FAKE_ROOT/fail-query"; fi
  exit 0 ;;
*) echo "unexpected fake call: $*" >&2; exit 99 ;;
esac
`,
      { mode: 0o755 },
    );
    writeFileSync(
      join(bin, "pgrep"),
      `#!/bin/bash
set -euo pipefail
if [[ -f "${root}/fail-query" ]]; then
  /bin/rm "${root}/fail-query"
  echo injected-observer-failure > "${root}/query-failed"
  exit 2
fi
exec /usr/bin/pgrep "$@"
`,
      { mode: 0o755 },
    );
    const keys = ["PATH", "OPPI_SIM_POOL_PGREP", "OPPI_FAKE_ROOT"] as const;
    const prior = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
    process.env.PATH = `${bin}:/usr/bin:/bin`;
    process.env.OPPI_SIM_POOL_PGREP = join(bin, "pgrep");
    process.env.OPPI_FAKE_ROOT = root;
    const session = new CommandSession();
    let prepared = false;
    try {
      const config = loadConfig(
        {
          ...process.env,
          OPPI_ROOT: root,
          OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
          OPPI_SIM_SLIM: "0",
          OPPI_SIM_POOL_BOOT_RETRIES: "1",
          OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
        },
        root,
        scriptDir,
      );
      try {
        await prepareSimulator(session, config, "PRIVATE-BOOT", "normal");
        prepared = true;
      } catch {
        prepared = false;
      }
      expect(prepared).toBe(false);
      const attempts = existsSync(join(root, "attempts"))
        ? Number(readFileSync(join(root, "attempts"), "utf8"))
        : 0;
      expect(attempts).toBe(1);
      expect(existsSync(join(root, "query-failed"))).toBe(true);
    } finally {
      await session.dispose();
      for (const key of keys) {
        if (prior[key] === undefined) {
          delete process.env[key];
        } else {
          process.env[key] = prior[key];
        }
      }
    }
  });

  test("proven-clean bootstatus timeout may retry", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-sim-ops-boot-retry-"));
    opsTemps.push(root);
    const bin = join(root, "bin");
    mkdirSync(bin);
    writeFileSync(
      join(root, "devices.json"),
      JSON.stringify({
        devices: {
          runtime: [
            {
              udid: "PRIVATE-BOOT-RETRY",
              name: "Oppi-Pool-0",
              state: "Booted",
              isAvailable: true,
              deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
            },
          ],
        },
      }),
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/bin/bash
set -euo pipefail
case "$1 $2" in
'simctl list') /bin/cat "$OPPI_FAKE_ROOT/devices.json" ;;
'simctl bootstatus')
  n=0
  [[ ! -f "$OPPI_FAKE_ROOT/attempts" ]] || n=$(<"$OPPI_FAKE_ROOT/attempts")
  n=$((n+1)); printf '%s' "$n" > "$OPPI_FAKE_ROOT/attempts"
  if [[ "$n" == 1 ]]; then exec /bin/sleep 30; fi
  exit 0 ;;
*) echo "unexpected fake call: $*" >&2; exit 99 ;;
esac
`,
      { mode: 0o755 },
    );
    const keys = ["PATH", "OPPI_FAKE_ROOT"] as const;
    const prior = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
    process.env.PATH = `${bin}:/usr/bin:/bin`;
    process.env.OPPI_FAKE_ROOT = root;
    const session = new CommandSession();
    let prepared = false;
    try {
      const config = loadConfig(
        {
          ...process.env,
          OPPI_ROOT: root,
          OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
          OPPI_SIM_SLIM: "0",
          OPPI_SIM_POOL_BOOT_RETRIES: "1",
          OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
        },
        root,
        scriptDir,
      );
      try {
        await prepareSimulator(session, config, "PRIVATE-BOOT-RETRY", "normal");
        prepared = true;
      } catch {
        prepared = false;
      }
      expect(prepared).toBe(true);
      const attempts = existsSync(join(root, "attempts"))
        ? Number(readFileSync(join(root, "attempts"), "utf8"))
        : 0;
      expect(attempts).toBe(2);
    } finally {
      await session.dispose();
      for (const key of keys) {
        if (prior[key] === undefined) {
          delete process.env[key];
        } else {
          process.env[key] = prior[key];
        }
      }
    }
  });
});

describe("sim-pool checkout targeting", () => {
  const temps: string[] = [];

  afterEach(() => {
    for (const dir of temps.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function tempCheckout(label: string): string {
    const root = mkdtempSync(join(tmpdir(), `oppi-sim-ops-${label}-`));
    temps.push(root);
    mkdirSync(join(root, "clients", "apple", "Oppi.xcodeproj"), { recursive: true });
    writeFileSync(join(root, "clients", "apple", "Oppi.xcodeproj", "project.pbxproj"), "// fixture\n");
    return root;
  }

  test("extractRootFlag peels --root before --", () => {
    expect(extractRootFlag(["run", "--root", "/wt", "--", "xcodebuild", "build"])).toEqual({
      root: "/wt",
      rest: ["run", "--", "xcodebuild", "build"],
    });
    expect(extractRootFlag(["--root=/wt", "run", "--", "xcodebuild"])).toEqual({
      root: "/wt",
      rest: ["run", "--", "xcodebuild"],
    });
    expect(extractRootFlag(["run", "--", "xcodebuild", "--root", "not-ours"])).toEqual({
      rest: ["run", "--", "xcodebuild", "--root", "not-ours"],
    });
  });

  test("normalizeOppiRoot accepts repo root or clients/apple", () => {
    const root = tempCheckout("normalize");
    expect(normalizeOppiRoot(root)).toBe(root);
    expect(normalizeOppiRoot(join(root, "clients", "apple"))).toBe(root);
  });

  test("applyRunCheckout chdirs to OPPI_ROOT apple dir and writes missing test plist", () => {
    const launchedFrom = tempCheckout("launched");
    const target = tempCheckout("target");
    const previous = process.cwd();
    process.chdir(join(launchedFrom, "clients", "apple"));
    try {
      const config = loadConfig({ OPPI_ROOT: target }, process.cwd(), scriptDir);
      const cwd = applyRunCheckout(config);
      const expected = realpathSync.native(join(target, "clients", "apple"));
      expect(cwd).toBe(expected);
      expect(process.cwd()).toBe(expected);
      expect(existsSync(join(target, "clients", "apple", ".build", "OppiTestsInfo.plist"))).toBe(true);
    } finally {
      process.chdir(previous);
    }
  });

  test("ensureOppiTestsInfoPlist does not overwrite an existing file", () => {
    const root = tempCheckout("plist");
    const appleDir = join(root, "clients", "apple");
    mkdirSync(join(appleDir, ".build"), { recursive: true });
    const plist = join(appleDir, ".build", "OppiTestsInfo.plist");
    writeFileSync(plist, "keep-me\n");
    expect(ensureOppiTestsInfoPlist(appleDir)).toBe(plist);
    expect(readFileSync(plist, "utf8")).toBe("keep-me\n");
  });
});
