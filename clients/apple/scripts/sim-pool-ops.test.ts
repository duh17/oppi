import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  applyPoolBuildSettings,
  applyRunCheckout,
  dropBuildDescriptionsMissingVendor,
  ensureOppiTestsInfoPlist,
  extractBuildTimingSummary,
  extractCompilerLinkerErrors,
  extractPoolFlags,
  loadConfig,
  normalizeCommandArgs,
  normalizeOppiRoot,
  normalizeVideoPolicy,
  parsePruneKeepSlots,
  PoolError,
  prepareSimulator,
  pruneBuildKind,
  silenceTimedOut,
  treeCpu,
  treeCpuRate,
  validateCommandGuardrails,
} from "./sim-pool-ops";
import { CommandSession } from "./sim-pool-supervise";

const scriptDir = import.meta.dir;

describe("sim-pool-ops helpers", () => {
  test("silence timeout needs the full interval, not just a second boundary", () => {
    // 100ms of silence straddling a whole-second boundary is not 1s of silence.
    expect(silenceTimedOut(11_050, 10_950, 1)).toBe(false);
    expect(silenceTimedOut(11_949, 10_950, 1)).toBe(false);
    expect(silenceTimedOut(11_950, 10_950, 1)).toBe(true);
    expect(silenceTimedOut(1_000_000, 0, 0)).toBe(false);
  });

  test("build CPU counts only xcodebuild's descendants, in every ps time format", () => {
    // 10 = xcodebuild; 20 = SWBBuildService (own process group) with two compilers; 99 is unrelated.
    const before = treeCpu(10, "10 1 0:01.00\n20 10 1:00.00\n21 20 0:30.00\n22 20 1-00:00:00\n99 1 5:00.00\n");
    expect([...before.keys()].sort()).toEqual([10, 20, 21, 22]);
    expect(before.get(22)).toBe(86_400);
    // 21 exited (no negative), 23 is a new compiler, 99 burned CPU outside the tree.
    const after = treeCpu(10, "10 1 0:01.10\n20 10 1:00.20\n22 20 1-00:00:01\n23 20 0:01.70\n99 1 9:00.00\n");
    expect(treeCpuRate(before, after, 4)).toBeCloseTo((0.1 + 0.2 + 1 + 1.7) / 4);
    expect(treeCpuRate(after, after, 4)).toBe(0);
  });

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
'simctl spawn') exit 0 ;; # device environment probe: clean
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

  function writeEnsureScript(root: string, body: string): void {
    const scripts = join(root, "clients", "apple", "scripts");
    mkdirSync(scripts, { recursive: true });
    writeFileSync(join(scripts, "ensure-prebuilt-frameworks.sh"), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  }

  test("extractPoolFlags peels --root and --device-profile before --", () => {
    expect(extractPoolFlags(["run", "--root", "/wt", "--", "xcodebuild", "build"])).toEqual({
      root: "/wt",
      rest: ["run", "--", "xcodebuild", "build"],
    });
    expect(extractPoolFlags(["--root=/wt", "run", "--", "xcodebuild"])).toEqual({
      root: "/wt",
      rest: ["run", "--", "xcodebuild"],
    });
    expect(extractPoolFlags(["run", "--device-profile", "duo", "--", "xcodebuild"])).toEqual({
      profile: "duo",
      rest: ["run", "--", "xcodebuild"],
    });
    expect(extractPoolFlags(["run", "--device-profile=duo", "--root", "/wt", "--", "xcodebuild"])).toEqual({
      root: "/wt",
      profile: "duo",
      rest: ["run", "--", "xcodebuild"],
    });
    expect(extractPoolFlags(["run", "--", "xcodebuild", "--root", "not-ours", "--device-profile", "duo"])).toEqual({
      rest: ["run", "--", "xcodebuild", "--root", "not-ours", "--device-profile", "duo"],
    });
    expect(() => extractPoolFlags(["run", "--device-profile"])).toThrow("--device-profile requires a value");
  });

  test("duo device profile selects the iPhone Duo lane and yields to explicit env", () => {
    const duo = loadConfig({ OPPI_SIM_DEVICE_PROFILE: "duo" }, process.cwd(), scriptDir);
    expect(duo.deviceType).toBe("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo");
    expect(duo.runtime).toBe("com.apple.CoreSimulator.SimRuntime.iOS-27-1");
    expect([duo.slotStart, duo.count]).toEqual([10, 1]);

    const overridden = loadConfig(
      {
        OPPI_SIM_DEVICE_PROFILE: "duo",
        OPPI_SIM_POOL_SLOT_START: "20",
        OPPI_SIM_POOL_COUNT: "2",
        OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
      },
      process.cwd(),
      scriptDir,
    );
    expect([overridden.slotStart, overridden.count, overridden.runtime]).toEqual([
      20,
      2,
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
    ]);

    const plain = loadConfig({}, process.cwd(), scriptDir);
    expect(plain.deviceType).toBe("com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro");
    expect([plain.slotStart, plain.count]).toEqual([0, 6]);

    expect(() => loadConfig({ OPPI_SIM_DEVICE_PROFILE: "trio" }, process.cwd(), scriptDir)).toThrow(
      "unknown device profile 'trio'",
    );
  });

  test("normalizeOppiRoot accepts repo root or clients/apple", () => {
    const root = tempCheckout("normalize");
    expect(normalizeOppiRoot(root)).toBe(root);
    expect(normalizeOppiRoot(join(root, "clients", "apple"))).toBe(root);
  });

  test("applyRunCheckout chdirs to OPPI_ROOT apple dir and writes missing test plist", () => {
    const launchedFrom = tempCheckout("launched");
    const target = tempCheckout("target");
    writeEnsureScript(target, 'mkdir -p "$PWD/Vendor/Fixture.xcframework"');
    const previous = process.cwd();
    process.chdir(join(launchedFrom, "clients", "apple"));
    try {
      const config = loadConfig({ OPPI_ROOT: target }, process.cwd(), scriptDir);
      const cwd = applyRunCheckout(config);
      const expected = realpathSync.native(join(target, "clients", "apple"));
      expect(cwd).toBe(expected);
      expect(process.cwd()).toBe(expected);
      expect(existsSync(join(target, "clients", "apple", ".build", "OppiTestsInfo.plist"))).toBe(true);
      expect(existsSync(join(target, "clients", "apple", "Vendor", "Fixture.xcframework"))).toBe(true);
    } finally {
      process.chdir(previous);
    }
  });

  test("cached build descriptions planned without this checkout's Vendor/ are dropped only in the owned slot", () => {
    const appleDir = join(tempCheckout("descriptions"), "clients", "apple");
    const buildBase = join(appleDir, ".build");
    const description = (pool: string, name: string, text: string) => {
      const dir = join(buildBase, pool, "Build", "Intermediates.noindex", "XCBuildData", `${name}.xcbuilddata`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "description.msgpack"), `\x92\xa3msg${text}\x00`);
      return dir;
    };
    const missing = (root: string) => `There is no XCFramework found at '${root}/Vendor/GhosttyVt/ghostty-vt.xcframework'.`;
    const poisoned = description("pool-0", "aaa", missing(appleDir));
    const poisonedOtherSlot = description("pool-10", "bbb", missing(appleDir));
    const healthy = description("pool-0", "ccc", "Build description signature: ccc");
    const otherCheckout = description("pool-0", "ddd", missing("/elsewhere/clients/apple"));
    dropBuildDescriptionsMissingVendor(appleDir, join(buildBase, "pool-0"));
    expect([poisoned, poisonedOtherSlot, healthy, otherCheckout].map(existsSync)).toEqual([false, true, true, true]);
  });

  test("applyRunCheckout fails before xcodebuild when prebuilt frameworks cannot be prepared", () => {
    const failing = tempCheckout("ensure-fails");
    writeEnsureScript(failing, "echo 'error: install Zig 0.16.0' >&2; exit 1");
    const previous = process.cwd();
    try {
      const config = loadConfig({ OPPI_ROOT: failing }, previous, scriptDir);
      expect(() => applyRunCheckout(config)).toThrow(/prebuilt frameworks are not ready .*exited 1/);
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
