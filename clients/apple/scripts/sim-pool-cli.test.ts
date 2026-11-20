import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireHeavySlot } from "./sim-pool-build";
import { INTERRUPTED_NOTE, needsCleanBoot, readSlotState, releaseReusable, tryAcquireSlot } from "./sim-pool-lock";
import { SPAWN_WAIT_MS, SUBPROCESS_TEST_TIMEOUT_MS, waitUntil } from "./sim-pool-test-support";

// Every test runs the pool CLI against fake tools; see sim-pool-test-support.ts for the sizing.
setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

const cli = join(import.meta.dir, "sim-pool.ts");

/** Eight sequential pool runs plus git commits: 38 s measured at background QoS under 16 CPU burners. */
const SLOW_CLI_TEST_TIMEOUT_MS = 180_000;
const temps: string[] = [];
const procs: ChildProcess[] = [];

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-sim-cli-${label}-`));
  temps.push(dir);
  return dir;
}

function initCheckout(root: string): void {
  spawnSync("git", ["init", "-q", root]);
  mkdirSync(join(root, "clients", "apple", "Oppi.xcodeproj"), { recursive: true });
  writeFileSync(join(root, "clients", "apple", "Oppi.xcodeproj", "project.pbxproj"), "// fixture\n");
}

function writeFakeXcrun(bin: string, fakeDir: string): void {
  mkdirSync(bin, { recursive: true });
  writeFileSync(
    join(bin, "xcrun"),
    `#!/usr/bin/env bash
set -euo pipefail
dir="${fakeDir}"
printf '%s\\n' "$*" >> "$dir/xcrun.calls"
# An xcresult's summary and the tests it lists: whatever the fixture's fake xcodebuild was told ran.
# Like xcresulttool, a bundle xcodebuild has not finished writing (no Info.plist) cannot be read.
if [[ "\${1:-}" == "xcresulttool" ]]; then
  bundle=""; prev=""
  for a in "$@"; do [ "$prev" = --path ] && bundle="$a"; prev="$a"; done
  if [[ -n "$bundle" && ! -f "$bundle/Info.plist" ]]; then
    echo "Error: Failed to create a new result bundle reader, underlying error: Info.plist at $bundle/Info.plist does not exist, the result bundle might be corrupted or the provided path is not a result bundle" >&2
    exit 64
  fi
fi
if [[ "\${1:-}" == "xcresulttool" && " $* " == *" summary "* && -f "$dir/xcresult-summary.json" ]]; then cat "$dir/xcresult-summary.json"; exit 0; fi
if [[ "\${1:-}" == "xcresulttool" && " $* " == *" tests "* && -f "$dir/xcresult.json" ]]; then cat "$dir/xcresult.json"; exit 0; fi
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun: unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    if [[ "\${1:-}" == "runtimes" ]]; then cat "$dir/runtimes.json"; exit 0; fi
    cat "$dir/devices.json"
    ;;
  bootstatus|boot|shutdown|erase|delete|create|spawn|io|uninstall|keychain|privacy)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    # Model CoreSimulator: boot bakes the caller's SIMCTL_CHILD_* into the
    # device environment until shutdown; spawn env prints that environment.
    if [[ "$sub" == "boot" ]]; then
      env | sed -n 's/^SIMCTL_CHILD_//p' >> "$dir/device.env" || true
    fi
    if [[ "$sub" == "shutdown" ]]; then rm -f "$dir/device.env"; fi
    if [[ "$sub" == "spawn" && "\${2:-}" == "/usr/bin/env" && -f "$dir/device.env" ]]; then cat "$dir/device.env"; fi
    if [[ "$sub" == "create" ]]; then echo UDID-CREATED; fi
    if [[ "$sub" == "io" ]]; then echo "Recording started" >&2; fi
    if [[ "$sub" == "erase" && -f "$dir/erase.sleep" ]]; then sleep "$(cat "$dir/erase.sleep")"; fi
    exit 0
    ;;
  *)
    echo "fake-xcrun: unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "xcodebuild"),
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "xcodebuild" || "\${1:-}" == */xcodebuild ]]; then
  echo "unexpected extra executable token: $1" >&2
  exit 99
fi
printf '%s\\n' "$@" >> "${fakeDir}/xcodebuild.calls"
printf -- '--\\n' >> "${fakeDir}/xcodebuild.calls"
${FAKE_BUILD_FOR_TESTING}
printf '%s\\n' "$@" > "${fakeDir}/xcodebuild.args"
echo "** BUILD SUCCEEDED **"
echo "Test run with 3 tests passed"
exit 0
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "sample"),
    `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "${fakeDir}/sample.calls"
if ! kill -0 "$1" 2>/dev/null; then
  echo "sample: pid $1 is not running" >&2
  exit 1
fi
echo "Sample of process $1 for \${2:-?} seconds"
`,
    { mode: 0o755 },
  );
}

function devicesJson(): string {
  return `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ]
  }
}`;
}

function runtimesJson(): string {
  return `{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      "platform": "iOS",
      "isAvailable": true,
      "version": "18.5",
      "buildversion": "22F77",
      "name": "iOS 18.5",
      "bundlePath": "/r",
      "runtimeRoot": "/r"
    }
  ]
}`;
}

/**
 * Shell for a fake xcodebuild: a `build-for-testing` call (sim-pool's slotless build phase)
 * writes `<scheme>_iphonesimulator-arm64.xctestrun` into its DerivedData and exits 0.
 */
const FAKE_BUILD_FOR_TESTING = `case " $* " in *" build-for-testing "*)
  dd=""; scheme=""; prev=""
  for a in "$@"; do
    [ "$prev" = -derivedDataPath ] && dd="$a"
    [ "$prev" = -scheme ] && scheme="$a"
    prev="$a"
  done
  mkdir -p "$dd/Build/Products"
  : > "$dd/Build/Products/\${scheme}_iphonesimulator-arm64.xctestrun"
  echo "** TEST BUILD SUCCEEDED **"
  exit 0 ;;
esac`;

const swiftTestPrelude = `Test Suite 'All tests' passed at 2026-10-01 13:10:19.718.
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
◇ Test run started.
`;
const swiftPassed = "✔ Test run with 9 tests in 1 suite passed after 11.224 seconds.\n";
const swiftFailed = "✘ Test run with 9 tests in 1 suite failed after 11.224 seconds with 3 issues.\n";

const xctestE2E = (failures: number) => `Test Suite 'Selected tests' started at 2026-10-08 20:08:53.283.
Test Suite 'OppiE2ETests.xctest' started at 2026-10-08 20:08:53.284.
Test Suite 'ChatE2ETests' started at 2026-10-08 20:08:53.284.
Test Case '-[OppiE2ETests.ChatE2ETests testSend]' started.
Test Case '-[OppiE2ETests.ChatE2ETests testSend]' ${failures ? "failed" : "passed"} (20.972 seconds).
Test Suite 'ChatE2ETests' ${failures ? "failed" : "passed"} at 2026-10-08 20:09:14.260.
\t Executed 1 test, with ${failures} failure${failures === 1 ? "" : "s"} (0 unexpected) in 20.972 (20.976) seconds
Test Suite 'OppiE2ETests.xctest' ${failures ? "failed" : "passed"} at 2026-10-08 20:09:14.261.
\t Executed 1 test, with ${failures} failure${failures === 1 ? "" : "s"} (0 unexpected) in 20.972 (20.977) seconds
Test Suite 'Selected tests' ${failures ? "failed" : "passed"} at 2026-10-08 20:09:14.261.
\t Executed 1 test, with ${failures} failure${failures === 1 ? "" : "s"} (0 unexpected) in 20.972 (20.978) seconds
2026-10-08 20:09:14.303 xcodebuild[75205:17669572] [MT] IDESchemeActionSDKRecord: operatingSystemBuild = <DVTBuildVersion 24A94232>, error = invalidDigitCount(94232).
`;
const e2eArgs = ["-scheme", "Oppi", "test", "-only-testing:OppiE2ETests/ChatE2ETests/testSend"];

/**
 * A `ps` for `OPPI_SIM_POOL_PS`: the real process table plus one synthetic child of the fake
 * xcodebuild (pid read from `pidFile`) whose CPU time grows four seconds per wall-clock second.
 */
function writeFakeBusyPs(path: string, pidFile: string): void {
  writeFileSync(path, `#!/usr/bin/perl
use Time::HiRes qw(time);
system("/bin/ps", @ARGV);
open(my $f, "<", "${pidFile}") or exit 0;
chomp(my $pid = <$f>);
my $cpu = 4 * (time - ${Date.now() / 1000});
my $minutes = int($cpu / 60);
printf("999999 %d %d:%05.2f\\n", $pid, $minutes, $cpu - 60 * $minutes);
`, { mode: 0o755 });
}

function runCompletionFixture(text: string, options: {
  /** Replaces the default unit-lane arguments. */
  args?: string[];
  extraArgs?: string[];
  /** Tests the run's xcresult lists, id (`Suite/test()`) to result; without it the run leaves no xcresult. */
  listed?: Record<string, "Passed" | "Failed" | "Skipped">;
  /** Overrides of the xcresult summary that `listed` implies (its `result`, failures). */
  summary?: Record<string, unknown>;
  /** The listed xcresult is a leftover from an earlier run (old mtime), not written by this one. */
  staleBundle?: boolean;
  /**
   * xcodebuild has not finished the listed xcresult when it prints the log: the bundle holds only
   * Staging, and `afterLog` (where `$bundle` is its path) may write its Info.plist.
   */
  unfinishedBundle?: boolean;
  env?: Record<string, string>;
  afterLog?: string;
  failQuery?: boolean;
  /** Seconds the fake simctl erase sleeps, to make hang-recovery time visible. */
  eraseSleep?: string;
  /**
   * Report a busy compiler under xcodebuild through `OPPI_SIM_POOL_PS` (four cores' worth of CPU,
   * computed from the wall clock) instead of spawning a real CPU spinner. A real spinner's share
   * of a loaded host decides whether the detector sees it; this curve cannot be starved.
   */
  busyCpu?: boolean;
  /** Limit for the whole pool run; the default suits runs that finish in a few seconds when the host is idle. */
  timeoutMs?: number;
} = {}) {
  const root = tempDir("completion");
  const fake = join(root, "fake");
  const bin = join(root, "bin");
  mkdirSync(fake);
  mkdirSync(join(root, "home"));
  initCheckout(root);
  writeFileSync(join(fake, "devices.json"), devicesJson());
  writeFileSync(join(fake, "runtimes.json"), runtimesJson());
  writeFakeXcrun(bin, fake);
  if (options.listed) {
    const cases = Object.entries(options.listed).map(([nodeIdentifier, result]) => ({ nodeType: "Test Case", result, nodeIdentifier }));
    writeFileSync(join(fake, "xcresult.json"), JSON.stringify({ testNodes: [{ nodeType: "Unit test bundle", children: cases }] }));
    const count = (result: string) => cases.filter((node) => node.result === result).length;
    writeFileSync(join(fake, "xcresult-summary.json"), JSON.stringify({
      result: count("Failed") > 0 ? "Failed" : "Passed",
      totalTestCount: cases.length, passedTests: count("Passed"), failedTests: count("Failed"), skippedTests: count("Skipped"), expectedFailures: 0,
      testFailures: cases.filter((node) => node.result === "Failed").map((node) => ({
        targetName: "OppiTests", testIdentifierString: node.nodeIdentifier, testName: node.nodeIdentifier.split("/").at(-1), failureText: `Expectation failed in ${node.nodeIdentifier}\nmore detail`,
      })),
      ...options.summary,
    }));
  }
  if (options.staleBundle) writeFileSync(join(fake, "xcresult.stale"), "");
  if (options.unfinishedBundle) writeFileSync(join(fake, "xcresult.unfinished"), "");
  if (options.eraseSleep) {
    writeFileSync(join(fake, "erase.sleep"), options.eraseSleep);
  }
  writeFileSync(join(bin, "xcodebuild"), `#!/bin/sh
set -eu
${FAKE_BUILD_FOR_TESTING}
echo attempt >> "${fake}/attempts"
dd=""; prev=""
for a in "$@"; do [ "$prev" = -derivedDataPath ] && dd="$a"; prev="$a"; done
if [ -f "${fake}/xcresult.stale" ]; then mkdir -p "$dd/Logs/Test/Old.xcresult"; touch -t 202001010000 "$dd/Logs/Test/Old.xcresult"
elif [ -f "${fake}/xcresult.unfinished" ]; then mkdir -p "$dd/Logs/Test/Run.xcresult/Staging"
elif [ -f "${fake}/xcresult.json" ]; then mkdir -p "$dd/Logs/Test/Run.xcresult"; : > "$dd/Logs/Test/Run.xcresult/Info.plist"; fi
bundle="$dd/Logs/Test/Run.xcresult"
cat <<'TEST_LOG'
${text}TEST_LOG
: > "${fake}/started"
${options.busyCpu ? `echo $$ > "${fake}/xcodebuild.pid"\n` : ""}${options.afterLog ?? "exec /bin/sleep 30"}
`, { mode: 0o755 });
  if (options.failQuery) {
    writeFileSync(join(bin, "pgrep"), `#!/bin/sh
if [ -f "${fake}/started" ]; then exit 2; fi
exec /usr/bin/pgrep "$@"
`, { mode: 0o755 });
  }
  if (options.busyCpu) {
    writeFakeBusyPs(join(fake, "ps"), join(fake, "xcodebuild.pid"));
  }
  const args = options.args ?? ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests"];
  const run = spawnSync("bun", [cli, "run", "--", "xcodebuild", ...args, ...(options.extraArgs ?? [])], {
    cwd: root,
    encoding: "utf8",
    timeout: options.timeoutMs ?? SPAWN_WAIT_MS,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_HANG_RETRIES: "1",
      OPPI_SIM_POOL_SILENCE_TIMEOUT: "1",
      OPPI_SIM_POOL_COMPLETION_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      ...(options.failQuery ? { OPPI_SIM_POOL_PGREP: join(bin, "pgrep") } : {}),
      ...(options.busyCpu ? { OPPI_SIM_POOL_PS: join(fake, "ps") } : {}),
      ...options.env,
    },
  });
  const logs = join(root, "clients", "apple", ".build", "logs");
  const summary = JSON.parse(readFileSync(join(logs, readdirSync(logs).find((name) => name.endsWith(".summary.json"))!), "utf8"));
  return {
    run, summary,
    attempts: readFileSync(join(fake, "attempts"), "utf8").trim().split("\n"),
    calls: readFileSync(join(fake, "xcrun.calls"), "utf8"),
    sampleCalls: existsSync(join(fake, "sample.calls")) ? readFileSync(join(fake, "sample.calls"), "utf8") : "",
    state: readSlotState(join(root, "locks"), 0),
    attempt: summary.attempt_artifacts?.[0] ? JSON.parse(readFileSync(summary.attempt_artifacts[0], "utf8")) : undefined,
  };
}

afterEach(() => {
  for (const child of procs.splice(0)) {
    if (child.exitCode == null && child.signalCode == null) {
      child.kill("SIGKILL");
    }
  }
  for (const dir of temps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

// These tests are about run behaviour; reaping after each run is covered in
// sim-pool-lifecycle.test.ts and here only adds simctl calls. Every CLI env
// spreads process.env, so turning the reaper off covers them all.
const savedIdleMinutes = process.env.OPPI_SIM_POOL_IDLE_MINUTES;
beforeAll(() => {
  process.env.OPPI_SIM_POOL_IDLE_MINUTES = "0";
});
afterAll(() => {
  if (savedIdleMinutes === undefined) {
    delete process.env.OPPI_SIM_POOL_IDLE_MINUTES;
  } else {
    process.env.OPPI_SIM_POOL_IDLE_MINUTES = savedIdleMinutes;
  }
});

describe("sim-pool CLI", () => {
  test("wrapper forwards arguments to bun", () => {
    const result = spawnSync("bash", [join(import.meta.dir, "sim-pool.sh")], { encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Usage:");
  });

  test("run -- xcodebuild does not pass an extra xcodebuild token", () => {
    const root = tempDir("run");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const home = join(root, "home");
    mkdirSync(fake, { recursive: true });
    mkdirSync(home, { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: home,
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8").trim().split("\n");
    expect(args[0]).toBe("-project");
    expect(args).not.toContain("xcodebuild");
    expect(args).toContain("-destination");
    expect(args).toContain("platform=iOS Simulator,id=UDID-POOL-0");
    expect(args).toContain("-derivedDataPath");
    expect(existsSync(join(root, "locks", "slot-0.lock"))).toBe(true);
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
    const calls = existsSync(join(fake, "xcrun.calls")) ? readFileSync(join(fake, "xcrun.calls"), "utf8") : "";
    expect(calls).not.toContain("delete unavailable");
  });

  function slotlessFixture(label: string) {
    const root = tempDir(label);
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      OPPI_HEAVY_DIR: join(root, "heavy"),
      OPPI_HEAVY_XCODE_BUILD: "1",
      OPPI_HEAVY_POLL: "0.1",
    };
    delete env.PIOS_ROOT;
    delete env.OPPI_HEAVY_HELD;
    const apple = join(root, "clients", "apple");
    const calls = () =>
      existsSync(join(fake, "xcodebuild.calls"))
        ? readFileSync(join(fake, "xcodebuild.calls"), "utf8").split("--\n").filter(Boolean).map((call) => call.trim().split("\n"))
        : [];
    const simctl = () => (existsSync(join(fake, "xcrun.calls")) ? readFileSync(join(fake, "xcrun.calls"), "utf8") : "");
    return { root, fake, apple, env, calls, simctl };
  }

  test("a build whose inputs did not change is skipped; a changed file, another invocation, or another commit builds", () => {
    const fx = slotlessFixture("skip-build");
    const git = (...args: string[]) => {
      const r = spawnSync("git", ["-C", fx.root, "-c", "user.name=t", "-c", "user.email=t@t", ...args], { encoding: "utf8" });
      expect(r.status).toBe(0);
    };
    // Everything the harness writes next to the checkout is ignored, like .build and Vendor in the real repo.
    writeFileSync(join(fx.root, ".gitignore"), "/bin/\n/fake/\n/home/\n/heavy/\n/locks/\n.build/\n");
    writeFileSync(join(fx.apple, "A.swift"), "let a = 1\n");
    git("add", ".");
    git("commit", "-q", "-m", "init");
    const build = (scheme = "OppiUnitTests") => {
      const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", scheme, "build-for-testing"], { cwd: fx.apple, env: fx.env, encoding: "utf8" });
      expect(result.status).toBe(0);
      return result.stderr + result.stdout;
    };
    expect(build()).not.toContain("Build skipped");
    expect(fx.calls()).toHaveLength(1);
    // Nothing changed: no second xcodebuild, and the summary says why.
    expect(build()).toContain("Build skipped");
    expect(fx.calls()).toHaveLength(1);
    const logs = join(fx.apple, ".build", "logs");
    const summaries = readdirSync(logs).filter((name) => name.endsWith(".summary.json")).sort();
    const skipped = JSON.parse(readFileSync(join(logs, summaries.at(-1)!), "utf8"));
    expect(skipped.build_phase.build_skipped).toBe(true);
    // A tracked edit rebuilds; so does a different scheme (another invocation), and then the first scheme again,
    // because the products now belong to the other build.
    writeFileSync(join(fx.apple, "A.swift"), "let a = 2\n");
    expect(build()).not.toContain("Build skipped");
    expect(fx.calls()).toHaveLength(2);
    expect(build("Oppi")).not.toContain("Build skipped");
    expect(fx.calls()).toHaveLength(3);
    expect(build()).not.toContain("Build skipped");
    expect(fx.calls()).toHaveLength(4);
    // A new commit with the same tree rebuilds; the build after it is skipped again.
    git("commit", "-q", "--allow-empty", "-m", "empty");
    expect(build()).not.toContain("Build skipped");
    expect(fx.calls()).toHaveLength(5);
    expect(build()).toContain("Build skipped");
    expect(fx.calls()).toHaveLength(5);
  }, SLOW_CLI_TEST_TIMEOUT_MS);

  test("a build with no test action runs in the checkout DerivedData without a simulator slot", () => {
    const fx = slotlessFixture("build-only");
    const productsDir = join(fx.root, "clone");
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "OppiUnitTests", "build-for-testing"], {
      cwd: fx.apple, env: { ...fx.env, OPPI_SIM_POOL_PRODUCTS_DIR: productsDir }, encoding: "utf8",
    });
    expect(result.status).toBe(0);
    // The caller asked for its own clone of the products (unit-shards).
    expect(readdirSync(join(productsDir, "Build", "Products"))).toEqual(["OppiUnitTests_iphonesimulator-arm64.xctestrun"]);
    const calls = fx.calls();
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain("generic/platform=iOS Simulator");
    expect(calls[0]).toContain("ARCHS=arm64");
    expect(realpathSync.native(calls[0][calls[0].indexOf("-derivedDataPath") + 1])).toBe(join(realpathSync.native(fx.apple), ".build", "dd"));
    expect(fx.simctl()).toBe("");
    expect(existsSync(join(fx.root, "locks", "slot-0.lock"))).toBe(false);
    const logs = join(fx.apple, ".build", "logs");
    const summary = JSON.parse(readFileSync(join(logs, readdirSync(logs).find((name) => name.endsWith(".summary.json"))!), "utf8"));
    expect(summary.simulator_slot).toBeNull();
    expect(summary.exit_code).toBe(0);
  });

  test("a test run builds without a slot, then runs the cloned products with the test flags in a slot", () => {
    const fx = slotlessFixture("split");
    // An xctestrun from an earlier SDK stays in DerivedData; the run must use only the new one.
    const products = join(fx.apple, ".build", "dd", "Build", "Products");
    mkdirSync(products, { recursive: true });
    writeFileSync(join(products, "OppiUnitTests_iphonesimulator27.0-arm64.xctestrun"), "stale");
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test",
        "-only-testing:OppiTests/FooTests", "-resultBundlePath", join(fx.root, "r.xcresult")],
      { cwd: fx.apple, env: fx.env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const [buildCall, testCall] = fx.calls();
    expect(buildCall).toContain("build-for-testing");
    expect(buildCall.some((arg) => arg.startsWith("-only-testing") || arg === "-resultBundlePath")).toBe(false);
    expect(testCall.slice(0, 2)).toEqual(["test-without-building", "-xctestrun"]);
    const runDir = testCall[testCall.indexOf("-derivedDataPath") + 1];
    expect(testCall[2]).toBe(join(runDir, "Build", "Products", "OppiUnitTests_iphonesimulator-arm64.xctestrun"));
    expect(realpathSync.native(join(runDir, ".."))).toBe(join(realpathSync.native(fx.apple), ".build", "runs"));
    expect(testCall).toContain("-only-testing:OppiTests/FooTests");
    expect(testCall).toContain(join(fx.root, "r.xcresult"));
    expect(testCall).toContain("platform=iOS Simulator,id=UDID-POOL-0");
    expect(testCall).not.toContain("-scheme");
    const logs = join(fx.apple, ".build", "logs");
    const summary = JSON.parse(readFileSync(join(logs, readdirSync(logs).find((name) => /^pool-.*\.summary\.json$/.test(name))!), "utf8"));
    expect(summary.derived_data_path).toBe(runDir);
    expect(summary.build_phase.exit_code).toBe(0);
    expect(summary.simulator_slot).toBe(0);
  });

  test("runs that start together and take the same slot one after the other each keep their own log and summary", async () => {
    const fx = slotlessFixture("same-slot");
    // Hold the first run in slot 0 until the second run is queued behind it and the 1-second
    // slotStamp advances, so the overlap is deterministic without sleeping in the second run.
    const firstLock = join(fx.fake, "first.lock");
    const firstSec = join(fx.fake, "first.sec");
    const releaseFile = join(fx.fake, "release");
    renameSync(join(fx.root, "bin", "xcodebuild"), join(fx.root, "bin", "xcodebuild.real"));
    writeFileSync(
      join(fx.root, "bin", "xcodebuild"),
      `#!/bin/sh
case " $* " in *" test-without-building "*)
  if mkdir "${firstLock}" 2>/dev/null; then
    date +%s > "${firstSec}"
    while [ ! -f "${releaseFile}" ]; do sleep 0.05; done
  fi
  ;;
esac
exec "${join(fx.root, "bin", "xcodebuild.real")}" "$@"
`,
      { mode: 0o755 },
    );
    const env = { ...fx.env, OPPI_SIM_POOL_WAIT: "60" };
    let stderr = "";
    const start = () => {
      const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests"], {
        cwd: fx.apple,
        env,
        stdio: ["ignore", "ignore", "pipe"],
      });
      child.stderr!.on("data", (chunk) => {
        stderr += String(chunk);
      });
      procs.push(child);
      return new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    };
    const runs = Promise.all([start(), start()]);
    try {
      const deadline = Date.now() + 30_000;
      while (Date.now() < deadline) {
        if (existsSync(firstSec) && stderr.includes("busy, waiting")) {
          const startedSec = Number(readFileSync(firstSec, "utf8").trim());
          if (Math.floor(Date.now() / 1000) > startedSec) break;
        }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      expect(existsSync(firstSec)).toBe(true);
      expect(stderr).toContain("busy, waiting");
      writeFileSync(releaseFile, "");
      expect(await runs).toEqual([0, 0]);
    } finally {
      writeFileSync(releaseFile, "");
    }
    const summaries = readdirSync(join(fx.apple, ".build", "logs")).filter((name) => /^pool-0-.*\.summary\.json$/.test(name));
    expect(summaries).toHaveLength(2);
  });

  test("a failed build ends the run before it takes a simulator slot", () => {
    const fx = slotlessFixture("build-fails");
    writeFileSync(join(fx.root, "bin", "xcodebuild"), "#!/bin/sh\necho 'error: boom' \nexit 65\n", { mode: 0o755 });
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "OppiUnitTests", "test"], {
      cwd: fx.apple, env: fx.env, encoding: "utf8",
    });
    expect(result.status).toBe(65);
    expect(fx.simctl()).toBe("");
    expect(existsSync(join(fx.root, "locks", "slot-0.lock"))).toBe(false);
  });

  describe("a lost build volume is an infrastructure failure", () => {
    /** A slotless fixture whose `.build` links into `<root>/ram`, a stand-in for the RAM disk. */
    function ramFixture(label: string, xcodebuild: (ram: string) => string) {
      const fx = slotlessFixture(label);
      const ram = join(fx.root, "ram");
      mkdirSync(ram);
      writeFileSync(join(fx.root, "bin", "xcodebuild"), `#!/bin/sh\nprintf '%s\\n' "$@" >> "${fx.fake}/xcodebuild.calls"\nprintf -- '--\\n' >> "${fx.fake}/xcodebuild.calls"\n${xcodebuild(ram)}`, { mode: 0o755 });
      const run = () => spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "OppiUnitTests", "test"], {
        cwd: fx.apple, env: { ...fx.env, OPPI_BUILD_ROOT: ram }, encoding: "utf8",
      });
      return { ...fx, ram, run };
    }
    const lastLine = (text: string) => text.trim().split("\n").at(-1) ?? "";

    test("the volume vanishing mid-build stops the build with one clear line, not a crash or a retry", () => {
      // The build writes its log, then the RAM disk goes (jetsam) while xcodebuild is still running.
      const fx = ramFixture("volume-vanishes", (ram) => `echo 'CompileSwift normal arm64 A.swift'\nsleep 0.3\nrm -rf "${ram}"\nexec /bin/sleep 30\n`);
      const result = fx.run();
      expect(result.stderr).not.toContain("ENOENT");
      expect(lastLine(result.stderr)).toMatch(/^error: INFRASTRUCTURE failure: build volume lost: \S+ disappeared mid-build; not a build or test failure of this change\./);
      expect(result.status).toBe(1);
      expect(fx.calls()).toHaveLength(1);
      expect(fx.simctl()).toBe("");
    });

    test("xcodebuild losing build.db to a dead device is the same failure", () => {
      const fx = ramFixture("device-not-configured", () =>
        `echo "error: unable to attach DB: error: accessing build database \\"$PWD/.build/dd/Build/Intermediates.noindex/XCBuildData/build.db\\": disk I/O error: Device not configured"\necho '** BUILD FAILED **'\nexit 65\n`);
      const result = fx.run();
      expect(result.status).toBe(65);
      expect(lastLine(result.stderr)).toMatch(/^error: INFRASTRUCTURE failure: build volume lost: xcodebuild lost its build database in \S+ \(.*Device not configured/);
    });

    test("a link into a build volume that is gone fails before anything builds, and says how to recover", () => {
      const fx = ramFixture("volume-missing", () => "exit 0\n");
      const folder = join(fx.ram, "wt");
      mkdirSync(fx.apple, { recursive: true });
      symlinkSync(folder, join(fx.apple, ".build"));
      rmSync(fx.ram, { recursive: true });
      const result = fx.run();
      expect(result.status).toBe(1);
      expect(lastLine(result.stderr)).toBe(
        `error: INFRASTRUCTURE failure: build volume missing: ${join(fx.apple, ".build")} links to ${folder}, but the build root ${fx.ram} (OPPI_BUILD_ROOT) is not mounted. ` +
          "Recreate the RAM disk (oppi-ramdisk.sh), then run again. Recreating the disk empties it under every build still running on it, so let those finish or stop first.",
      );
      expect(fx.calls()).toHaveLength(0);
    });
  });

  test("the build waits for a free machine-wide xcode-build slot", async () => {
    const fx = slotlessFixture("heavy-busy");
    mkdirSync(join(fx.root, "heavy"), { recursive: true });
    // The holder says "held" once it owns the lock, so the build below cannot get there first.
    const holder = spawn("/usr/bin/lockf", ["-k", join(fx.root, "heavy", "xcode-build.0"), "/bin/sh", "-c", "echo held; exec /bin/sleep 30"]);
    procs.push(holder);
    let held = "";
    holder.stdout!.on("data", (chunk) => { held += chunk; });
    await waitUntil(() => held.includes("held"), "the lock holder to own xcode-build.0");
    const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-scheme", "OppiUnitTests", "build-for-testing"], {
      cwd: fx.apple, env: fx.env,
    });
    procs.push(child);
    let stderr = "";
    child.stderr!.on("data", (chunk) => { stderr += chunk; });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    // The build has seen the busy slot (it says so) and keeps polling at OPPI_HEAVY_POLL (0.1 s);
    // it must not run xcodebuild through a few more polls. Slowness can only make this check pass
    // late, never fail it.
    await waitUntil(() => stderr.includes("xcode-build slots busy"), "the build to report busy xcode-build slots");
    await Bun.sleep(500);
    expect(fx.calls()).toHaveLength(0);
    holder.kill("SIGKILL");
    expect(await exited).toBe(0);
    expect(fx.calls()).toHaveLength(1);
  });

  test("a test run waits for a machine-wide ui-suite token before it takes a simulator", async () => {
    const fx = slotlessFixture("ui-suite-busy");
    const env = { ...fx.env, OPPI_SIM_POOL_WAIT: "60" };
    const idle = { canceled: false, waitWhileIdle: async () => {} };
    // Four test phases already run on the machine: every default token is taken.
    const held = [];
    for (let i = 0; i < 4; i += 1) held.push((await acquireHeavySlot("ui-suite", env, idle, () => {}, 0))!);
    const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests"], {
      cwd: fx.apple, env,
    });
    procs.push(child);
    let stderr = "";
    child.stderr!.on("data", (chunk) => { stderr += chunk; });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    await waitUntil(() => stderr.includes("ui-suite slots busy"), "the run to report busy ui-suite slots");
    // The message comes from inside the token wait, which runs before any simulator work, so the
    // build phase (it takes no token) has run and the test phase and its simulator have not.
    expect(fx.calls()).toHaveLength(1);
    expect(fx.simctl()).toBe("");
    expect(existsSync(join(fx.root, "locks", "slot-0.lock"))).toBe(false);
    held[1]!.lock!.release();
    expect(await exited).toBe(0);
    expect(fx.calls()).toHaveLength(2);
    expect(stderr).toContain("machine-wide ui-suite slot");
    for (const token of held) token.lock!.release();
  });

  test("mismatch device is replaced under the slot lock", () => {
    const root = tempDir("mismatch");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(
      join(fake, "devices.json"),
      `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3"
      }
    ]
  }
}`,
    );
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "test-without-building"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8");
    expect(args).toContain("id=UDID-CREATED");
    const calls = readFileSync(join(fake, "xcrun.calls"), "utf8");
    expect(calls).toContain("delete UDID-POOL-0");
    expect(calls).toContain("create Oppi-Pool-0");
    expect(calls).not.toContain("delete unavailable");
  });

  test("run skips a runtime-mismatched slot and uses a matching sibling", () => {
    const root = tempDir("mixed-runtime");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(
      join(fake, "devices.json"),
      `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-1",
        "name": "Oppi-Pool-1",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ]
  }
}`,
    );
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "2",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8");
    expect(args).toContain("id=UDID-POOL-1");
    expect(args).not.toContain("UDID-POOL-0");
    const calls = readFileSync(join(fake, "xcrun.calls"), "utf8");
    expect(calls).not.toContain("delete UDID-POOL-0");
  });

  test("run replaces a mismatched slot when the matching sibling is busy", () => {
    const root = tempDir("repair-busy-match");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    mkdirSync(join(root, "locks"), { recursive: true });
    initCheckout(root);
    const held = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 1, argv: ["run"] });
    expect(held.ok).toBe(true);
    writeFileSync(
      join(fake, "devices.json"),
      `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-1",
        "name": "Oppi-Pool-1",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ]
  }
}`,
    );
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "2",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8");
    expect(args).toContain("id=UDID-CREATED");
    expect(args).not.toContain("UDID-POOL-1");
    const calls = readFileSync(join(fake, "xcrun.calls"), "utf8");
    expect(calls).toContain("delete UDID-POOL-0");
    expect(calls).toContain("create Oppi-Pool-0");
    if (held.ok) {
      releaseReusable(held.owned);
    }
  });

  test("in-flight slot is not reused by a second run", () => {
    const root = tempDir("busy");
    mkdirSync(join(root, "locks"), { recursive: true });
    const held = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(held.ok).toBe(true);
    initCheckout(root);
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const developerDir = join(root, "Developer");
    mkdirSync(fake, { recursive: true });
    mkdirSync(developerDir, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      DEVELOPER_DIR: developerDir,
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "test-without-building"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/busy or quarantined|busy, quarantined|in-flight/);
  });

  for (const finished of [false, true]) {
  test(`TERM ${finished ? "after test completion" : "during xcodebuild"} fails the run and frees the slot once the child group is idle`, async () => {
    const root = tempDir("run-term");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const home = join(root, "home");
    mkdirSync(fake, { recursive: true });
    mkdirSync(home, { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcodebuild"),
      `#!/usr/bin/env bash
set -euo pipefail
${FAKE_BUILD_FOR_TESTING}
cat <<'TEST_LOG'
${finished ? swiftTestPrelude + swiftPassed : ""}TEST_LOG
printf 'started\n' > "${fake}/xcodebuild.started"
sleep 30
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: home,
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-scheme", finished ? "OppiUnitTests" : "Oppi", finished ? "test" : "test-without-building", "-only-testing:OppiTests"], {
      cwd: join(root, "clients", "apple"),
      env,
      stdio: "ignore",
    });
    procs.push(child);
    await waitUntil(() => existsSync(join(fake, "xcodebuild.started")), "the fake xcodebuild to start");
    child.kill("SIGTERM");
    const code = await new Promise<number | null>((resolve) => child.once("exit", (value) => resolve(value)));
    expect(code).toBe(143);
    const reuse = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      // The interrupted run left the slot owing a clean boot.
      expect(needsCleanBoot(reuse.previous)).toBe(true);
      releaseReusable(reuse.owned, undefined, INTERRUPTED_NOTE);
    }
    // The next run boots the still-booted simulator fresh, then releases the slot clean.
    writeFileSync(join(bin, "xcodebuild"), `#!/bin/sh\n${FAKE_BUILD_FOR_TESTING}\nexit 0\n`, { mode: 0o755 });
    rmSync(join(fake, "simctl.log"), { force: true });
    const next = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "test-without-building"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(next.status).toBe(0);
    expect(readFileSync(join(fake, "simctl.log"), "utf8")).toMatch(/shutdown UDID-POOL-0[\s\S]*boot UDID-POOL-0/);
    const state = readSlotState(join(root, "locks"), 0);
    expect(state !== "unreadable" && state?.note).toBeFalsy();
  });

  }

  test("run uses OPPI_ROOT checkout even when launched from another clients/apple", () => {
    const mainRoot = tempDir("main-checkout");
    const worktree = tempDir("worktree-checkout");
    const fake = join(worktree, "fake");
    const bin = join(worktree, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(worktree, "home"), { recursive: true });
    initCheckout(mainRoot);
    initCheckout(worktree);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcodebuild"),
      `#!/usr/bin/env bash
set -euo pipefail
pwd > "${fake}/xcodebuild.cwd"
printf '%s\\n' "$@" > "${fake}/xcodebuild.args"
echo "** BUILD SUCCEEDED **"
exit 0
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(worktree, "home"),
      OPPI_ROOT: worktree,
      OPPI_SIM_POOL_LOCK_DIR: join(worktree, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(mainRoot, "clients", "apple"), env, encoding: "utf8" },
    );
    // Status 0 is required; signal and spawn error are included so a child that
    // dies before reaching pool logic (status null) is diagnosable from the failure.
    expect({ status: result.status, signal: result.signal, error: result.error?.message }).toEqual({
      status: 0,
      signal: null,
      error: undefined,
    });
    const appleDir = realpathSync.native(join(worktree, "clients", "apple"));
    expect(result.stdout + result.stderr).toContain(`Apple checkout ${appleDir}`);
    expect(readFileSync(join(fake, "xcodebuild.cwd"), "utf8").trim()).toBe(appleDir);
  });

  test("run --root targets that checkout from another tree", () => {
    const mainRoot = tempDir("main-root-flag");
    const worktree = tempDir("worktree-root-flag");
    const fake = join(worktree, "fake");
    const bin = join(worktree, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(worktree, "home"), { recursive: true });
    initCheckout(mainRoot);
    initCheckout(worktree);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcodebuild"),
      `#!/usr/bin/env bash
set -euo pipefail
pwd > "${fake}/xcodebuild.cwd"
printf '%s\\n' "$@" > "${fake}/xcodebuild.args"
echo "** BUILD SUCCEEDED **"
exit 0
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(worktree, "home"),
      OPPI_SIM_POOL_LOCK_DIR: join(worktree, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    delete env.OPPI_ROOT;
    const result = spawnSync(
      "bun",
      [
        cli,
        "run",
        "--root",
        worktree,
        "--",
        "xcodebuild",
        "-project",
        "Oppi.xcodeproj",
        "-scheme",
        "Oppi",
        "build",
      ],
      { cwd: join(mainRoot, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    expect(readFileSync(join(fake, "xcodebuild.cwd"), "utf8").trim()).toBe(
      realpathSync.native(join(worktree, "clients", "apple")),
    );
  });

  test("warm reuse of a booted simulator does not erase or force shutdown", () => {
    const root = tempDir("warm");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("bootstatus");
    expect(simctl).not.toContain("erase");
    expect(simctl).not.toMatch(/^shutdown /m);
    // The leased slot starts every run without the previous run's app, data, or keychain.
    const calls = readFileSync(join(fake, "xcrun.calls"), "utf8");
    expect(calls).toMatch(/simctl uninstall \S+ dev\.chenda\.Oppi\n(.*\n)*simctl keychain \S+ reset\n/);
    // The uninstall forgot the microphone decision; the reset answers it ("Don't Allow", as the UI tests do)
    // so no system alert covers the first screen. Order matters: the privacy row is written after the uninstall.
    expect(calls).toMatch(/simctl uninstall \S+ dev\.chenda\.Oppi\n(.*\n)*simctl privacy \S+ revoke microphone dev\.chenda\.Oppi\n/);
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
  });

  test("a failed app-state reset fails the run before xcodebuild starts", () => {
    const root = tempDir("reset-fails");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    // The real fake handles everything except the keychain reset, which fails like a broken simulator would.
    renameSync(join(bin, "xcrun"), join(bin, "xcrun.real"));
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
if [[ "\${2:-}" == "keychain" ]]; then echo "simctl keychain: unable to reset" >&2; exit 1; fi
exec "${bin}/xcrun.real" "$@"
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("simctl keychain reset failed");
    expect(existsSync(join(fake, "xcodebuild.calls"))).toBe(false);
  });

  function runPoolWithFakeSimulator(
    label: string,
    options: { deviceState: "Booted" | "Shutdown"; deviceEnv?: string; callerEnv?: NodeJS.ProcessEnv },
  ): { status: number | null; fake: string; simctl: string; deviceEnv: string; stderr: string } {
    const root = tempDir(label);
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(
      join(fake, "devices.json"),
      devicesJson().replace('"state": "Booted"', `"state": "${options.deviceState}"`),
    );
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    if (options.deviceEnv) {
      writeFileSync(join(fake, "device.env"), options.deviceEnv);
    }
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
      ...options.callerEnv,
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    const read = (name: string) => (existsSync(join(fake, name)) ? readFileSync(join(fake, name), "utf8") : "");
    return {
      status: result.status,
      fake,
      simctl: read("simctl.log"),
      deviceEnv: read("device.env"),
      stderr: result.stderr,
    };
  }

  test("an E2E lane that boots the slot does not bake its SIMCTL_CHILD_ env into the device", () => {
    const run = runPoolWithFakeSimulator("e2e-boot", {
      deviceState: "Shutdown",
      callerEnv: {
        SIMCTL_CHILD_PI_E2E_INVITE_URL: "oppi://connect?v=3&invite=secret",
        SIMCTL_CHILD_OPPI_E2E_DEVICE_TOKEN: "secret-token",
      },
    });
    expect(run.status).toBe(0);
    expect(run.simctl).toContain("boot ");
    expect(run.deviceEnv).toBe("");
  });

  test("a booted slot carrying leaked E2E device env is recycled before the run", () => {
    const run = runPoolWithFakeSimulator("leaked-device-env", {
      deviceState: "Booted",
      deviceEnv: "PI_E2E_INVITE_URL=oppi://connect?v=3&invite=stale\nSOME_OTHER=1\n",
    });
    expect(run.status).toBe(0);
    expect(run.simctl).toMatch(/^shutdown /m);
    expect(run.simctl).toMatch(/^boot /m);
    expect(run.simctl).not.toContain("erase");
    expect(run.deviceEnv).toBe("");
    expect(run.stderr).toContain("PI_E2E_INVITE_URL");
    expect(run.stderr).not.toContain("stale");
  });

  test("a booted slot with a clean device environment is reused, even when the caller exports SIMCTL_CHILD_ E2E env", () => {
    const run = runPoolWithFakeSimulator("clean-reuse", {
      deviceState: "Booted",
      callerEnv: { SIMCTL_CHILD_PI_E2E_INVITE_URL: "oppi://connect?v=3&invite=lane" },
    });
    expect(run.status).toBe(0);
    expect(run.simctl).not.toMatch(/^shutdown /m);
    expect(run.simctl).not.toMatch(/^boot /m);
    expect(run.deviceEnv).toBe("");
  });

  test("FORCE_CLEAN_BOOT shuts down before boot and does not erase", () => {
    const root = tempDir("clean-boot");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_FORCE_CLEAN_BOOT: "1",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const simctl = readFileSync(join(fake, "simctl.log"), "utf8");
    expect(simctl).toContain("shutdown");
    expect(simctl).toContain("boot ");
    expect(simctl).not.toContain("erase");
  });

  test("failed recovery shutdown does not erase", () => {
    const root = tempDir("no-erase");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
printf '%s\\n' "$*" >> "$dir/xcrun.calls"
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun: unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    if [[ "\${1:-}" == "runtimes" ]]; then cat "$dir/runtimes.json"; exit 0; fi
    cat "$dir/devices.json"
    ;;
  bootstatus)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    exit 0
    ;;
  shutdown)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    # The warm-reuse probe (simctl spawn ... env) is the last simctl call before
    # the build starts, so any shutdown after it is the hang-recovery shutdown.
    # Keyed on the call log, not on the fake xcodebuild having started, so the
    # outcome does not depend on how fast that script gets scheduled.
    if grep -q '^spawn ' "$dir/simctl.log"; then
      echo "Unable to shutdown device in current state: Booted" >&2
      exit 1
    fi
    exit 0
    ;;
  erase|boot|delete|create|spawn|io|uninstall|keychain|privacy)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    exit 0
    ;;
  *)
    echo "fake-xcrun: unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
      { mode: 0o755 },
    );
    writeFileSync(
      join(bin, "xcodebuild"),
      `#!/usr/bin/env bash
set -euo pipefail
printf 'started\\n' > "${fake}/xcodebuild.started"
echo "Resolve Package Graph"
sleep 30
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_POOL_SILENCE_TIMEOUT: "1",
      OPPI_SIM_POOL_HANG_RETRIES: "1",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).not.toBe(0);
    // Prove the failure came from the hang-recovery path, not from an earlier step.
    expect(result.stderr).toContain("hang detected");
    expect(result.stderr).toContain("WARNING: Recovery is ERASING simulator");
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("shutdown");
    expect(simctl).not.toContain("erase");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
  });

  for (const [text, code, outcome, issues] of [
    [swiftPassed, 0, "passed", 0],
    [swiftFailed, 65, "failed", 3],
    [swiftFailed + "** TEST FAILED **\n", 65, "failed", 3],
  ] as const) {
    test(`finished-then-hung ${outcome}${text.includes("** TEST FAILED **") ? " after Xcode footer" : ""} keeps the test result and never retries or erases`, () => {
      const result = runCompletionFixture(swiftTestPrelude + text);
      expect(result.run.status).toBe(code);
      expect(result.attempts).toHaveLength(1);
      expect(result.calls).not.toMatch(/simctl (shutdown|erase)/);
      expect(result.summary).toMatchObject({
        exit_code: code, attempt_count: 1, hang_detected: true,
        completion_hang_detected: true, xcodebuild_exit_code: null, xcodebuild_signal: "SIGTERM",
        test_completion: { outcome, tests: 9, suites: 1, issues, summary: text.split("\n")[0] },
      });
      expect(result.attempt.test_completion).toEqual(result.summary.test_completion);
      expect(result.attempt.completion_hang_detected).toBe(true);
      expect(result.run.stdout).toContain(text.split("\n")[0]);
      // Stopping xcodebuild left no readable bundle: the counts say so and never claim zero tests.
      expect(result.summary.test_results).toEqual({ unreadable: expect.stringContaining("no .xcresult in") });
      expect(result.run.stdout).toContain("Tests: result unreadable (no .xcresult in");
      expect(`${result.run.stdout}${result.run.stderr}`).not.toMatch(/zero tests|Tests: 0\b/);
      expect(result.state === "unreadable" ? undefined : result.state?.status).toBe("reusable");
    });
  }

  for (const [failures, code, outcome, skipped] of [[0, 0, "passed", false], [1, 65, "failed", false], [0, 0, "passed", true]] as const) {
    test(`finished-then-lingering E2E run (${outcome}${skipped ? ", with skipped tests" : ""}) keeps its XCTest result and never re-runs`, () => {
      const text = skipped ? xctestE2E(failures).replaceAll("with 0 failures", "with 1 test skipped and 0 failures") : xctestE2E(failures);
      const result = runCompletionFixture(text, { args: e2eArgs });
      expect(result.run.status).toBe(code);
      expect(result.attempts).toHaveLength(1);
      expect(result.calls).not.toMatch(/simctl (shutdown|erase)/);
      expect(result.summary).toMatchObject({
        exit_code: code, completion_hang_detected: true,
        test_completion: { outcome, tests: 1, suites: 1, issues: failures },
      });
    });
  }

  // A failing UI or E2E run: after the summary xcodebuild collects diagnostics and only then writes
  // the bundle's Info.plist. Stopping it before that left the xcresult unreadable and the shard an
  // infrastructure failure with no counts.
  test("a lingering failed XCTest run is stopped only after it finishes writing its result bundle", () => {
    const result = runCompletionFixture(xctestE2E(1), {
      args: e2eArgs,
      listed: { "ChatE2ETests/testSend()": "Failed" },
      unfinishedBundle: true,
      // Three completion waits; the run's 2-second silence window passes too while it writes.
      afterLog: `/bin/sleep 3; : > "$bundle/Info.plist"; exec /bin/sleep 30`,
      env: { OPPI_SIM_POOL_RESULT_TIMEOUT: "60", OPPI_SIM_POOL_SILENCE_TIMEOUT: "2" },
      timeoutMs: 60_000,
    });
    expect(result.run.status).toBe(65);
    expect(result.summary).toMatchObject({
      exit_code: 65, attempt_count: 1, completion_hang_detected: true,
      test_completion: { outcome: "failed", tests: 1, issues: 1 },
      test_results: { result: "Failed", total: 1, passed: 0, failed: 1, bundle: expect.stringMatching(/Run\.xcresult$/) },
    });
    expect(result.run.stdout).toContain("Tests: 1 (0 passed, 1 failed, 0 skipped); xcresult Failed");
    expect(result.run.stdout).toContain("ChatE2ETests/testSend()");
    expect(result.attempts).toHaveLength(1);
    expect(result.calls).not.toMatch(/simctl (shutdown|erase)/);
    expect(result.run.stderr).toContain("xcodebuild is still writing");
    expect(result.run.stderr).toContain("completion hang:");
    // Stopped once the bundle was written, well before the result wait ran out.
    expect(result.summary.elapsed_seconds).toBeGreaterThanOrEqual(3);
    expect(result.summary.elapsed_seconds).toBeLessThan(40);
  });

  test("a lingering XCTest run that never finishes its result bundle is still stopped at the result wait", () => {
    const result = runCompletionFixture(xctestE2E(1), {
      args: e2eArgs,
      listed: { "ChatE2ETests/testSend()": "Failed" },
      unfinishedBundle: true,
      afterLog: "exec /bin/sleep 120",
      env: { OPPI_SIM_POOL_RESULT_TIMEOUT: "3" },
      timeoutMs: 60_000,
    });
    expect(result.run.status).toBe(65);
    expect(result.attempts).toHaveLength(1);
    expect(result.calls).not.toMatch(/simctl (shutdown|erase)/);
    expect(result.run.stderr).toMatch(/completion hang: .* xcodebuild still alive after [34]s/);
    expect(result.summary).toMatchObject({
      exit_code: 65, completion_hang_detected: true, xcodebuild_exit_code: null, xcodebuild_signal: "SIGTERM",
      test_results: { bundle: expect.stringMatching(/Run\.xcresult$/), unreadable: expect.stringContaining("Info.plist") },
    });
    expect(result.run.stdout).toContain("Tests: result unreadable (xcresulttool exit 64");
    expect(result.summary.elapsed_seconds).toBeLessThan(15);
  });

  // A passing UI run collects no diagnostics, but xcodebuild still writes the bundle after the
  // summary, longer than the completion wait on a loaded host. Stopping it then left gate shards
  // with an unreadable xcresult and no counts.
  test("a lingering passed XCTest run is stopped only after it finishes writing its result bundle", () => {
    const result = runCompletionFixture(xctestE2E(0), {
      args: e2eArgs,
      listed: { "ChatE2ETests/testSend()": "Passed" },
      unfinishedBundle: true,
      // Three completion waits; the run's 2-second silence window passes too while it writes.
      afterLog: `/bin/sleep 3; : > "$bundle/Info.plist"; exec /bin/sleep 30`,
      env: { OPPI_SIM_POOL_RESULT_TIMEOUT: "60", OPPI_SIM_POOL_SILENCE_TIMEOUT: "2" },
      timeoutMs: 60_000,
    });
    expect(result.run.status).toBe(0);
    expect(result.summary).toMatchObject({
      exit_code: 0, attempt_count: 1, completion_hang_detected: true,
      test_completion: { outcome: "passed", tests: 1 },
      test_results: { result: "Passed", total: 1, passed: 1, failed: 0, bundle: expect.stringMatching(/Run\.xcresult$/) },
    });
    expect(result.run.stdout).toContain("Tests: 1 (1 passed, 0 failed, 0 skipped); xcresult Passed");
    expect(result.run.stderr).toContain("xcodebuild is still writing");
    // Stopped once the bundle was written, well before the result wait ran out.
    expect(result.summary.elapsed_seconds).toBeGreaterThanOrEqual(3);
    expect(result.summary.elapsed_seconds).toBeLessThan(40);
  });

  test("silent build that keeps the CPU busy is progress, not a hang", () => {
    // Like swift-frontend emitting a module: no log output for two silence windows
    // while a compiler under xcodebuild burns CPU, then a clean exit.
    const result = runCompletionFixture("", {
      env: { OPPI_SIM_POOL_SILENCE_TIMEOUT: "2" },
      busyCpu: true,
      afterLog: "/bin/sleep 4; exit 0",
      // The run lasts a fixed ~4s plus pool start-up, which took 5s more than usual on a host at
      // load ~100 (9.9s of the default 15s measured); a hang-kill would end it near 2s instead.
      timeoutMs: 30_000,
    });
    expect(result.run.status).toBe(0);
    expect(result.attempts).toHaveLength(1);
    expect(result.summary.hang_detected).toBe(false);
    expect(result.run.stderr).not.toContain("hang detected");
  });

  test("CPU alone cannot keep a silent run alive past five silence windows", () => {
    const result = runCompletionFixture("", {
      env: { OPPI_SIM_POOL_HANG_RETRIES: "0" },
      busyCpu: true,
      afterLog: "exec /bin/sleep 120",
      // The kill comes at a fixed ~6s (five windows plus one) after pool start-up, which took up to
      // 5s more at load ~100 (11.3s of the default 15s measured).
      timeoutMs: 30_000,
    });
    // The reported CPU never stops and xcodebuild would sleep 120 seconds, so only the cap can
    // end this run inside the 30-second limit.
    expect(result.run.status).not.toBe(0);
    expect(result.summary.hang_detected).toBe(true);
    // Up to five 1-second windows of CPU-only life, then the kill. Without the CPU signal the
    // kill would come after one window instead. elapsed_seconds starts once xcodebuild runs, so
    // pool start-up under load is not in it: the kill is wall-clock math against the last output
    // (~6s expected; 6, 6, 7, 7, 6 measured at 4x load). More than eight means the cap grew.
    expect(result.summary.elapsed_seconds).toBeGreaterThanOrEqual(4);
    expect(result.summary.elapsed_seconds).toBeLessThan(9);
  });

  test("silent hang is retried after a simulator erase", () => {
    const result = runCompletionFixture("Resolve Package Graph\nTest session started\n", { eraseSleep: "1" });
    expect(result.run.status).not.toBe(0);
    expect(result.attempts).toHaveLength(2);
    expect(result.calls).toContain("simctl erase");
    expect(result.summary.host_crash_line).toBeUndefined();
    expect(result.summary.stalled_before_project_open).toBeUndefined();
    const timing = result.summary.timing_breakdown_seconds as { simulator_prepare: number };
    const epochs = result.summary.timing_phase_epochs as {
      simulator_prepare_start: number;
      simulator_prepare_end: number;
    };
    expect(timing.simulator_prepare).toBe(epochs.simulator_prepare_end - epochs.simulator_prepare_start);
  });

  test("hang before Resolve Package Graph is diagnosed once and not erased", () => {
    const result = runCompletionFixture(
      "Command line invocation:\n    /fake/xcodebuild\n\nBuild settings from command line:\n    COMPILER_INDEX_STORE_ENABLE = NO\n",
    );
    expect(result.run.status).not.toBe(0);
    expect(result.attempts).toHaveLength(1);
    expect(result.calls).not.toContain("simctl erase");
    expect(result.run.stderr).toContain(
      "xcodebuild stalled before opening the project (likely another process such as Xcode.app holding the project)",
    );
    expect(result.run.stdout).toContain(
      "xcodebuild stalled before opening the project (likely another process such as Xcode.app holding the project); skipped simulator retry.",
    );
    expect(result.sampleCalls).toMatch(/^[0-9]+ 3$/m);
    expect(result.attempt?.sample_output).toMatch(/Sample of process [0-9]+ for 3 seconds/);
    expect(result.attempt?.stalled_before_project_open).toBe(true);
    expect(result.summary.sample_output).toBe(result.attempt?.sample_output);
    expect(result.summary.stalled_before_project_open).toBe(true);
  });

  test("hang after a Swift runtime crash is not retried or erased and the summary shows the crash", () => {
    const crash = "/Users/x/Oppi/App/OppiApp.swift:430: Fatal error: No Observable object of type ConnectionCoordinator found";
    const result = runCompletionFixture(`${crash}\n`);
    expect(result.run.status).not.toBe(0);
    expect(result.attempts).toHaveLength(1);
    expect(result.calls).not.toContain("simctl erase");
    expect(result.run.stderr).toContain("Skipping simulator retry: the test host crashed");
    expect(result.run.stdout).toContain(`Test host crashed; skipped simulator retry:\n${crash}`);
    expect(result.summary).toMatchObject({ hang_detected: true, attempt_count: 1, host_crash_line: crash });
  });

  test("crash line relayed behind an os_log prefix, or without a location, also skips the retry", () => {
    const relayed = "2026-10-15 07:50:15.632817-0700 Oppi[56780:74827238] Oppi/OppiApp.swift:469: Fatal error: boom";
    const result = runCompletionFixture(`${relayed}\n`);
    expect(result.attempts).toHaveLength(1);
    expect(result.summary.host_crash_line).toBe(relayed);
    const bare = runCompletionFixture("Fatal error: boom\n");
    expect(bare.attempts).toHaveLength(1);
    expect(bare.summary.host_crash_line).toBe("Fatal error: boom");
  });

  test("app log and test names that mention a crash do not suppress the hang retry", () => {
    const result = runCompletionFixture([
      "Resolve Package Graph",
      "Dictation error (fatal=true): STT crashed",
      "Test case 'crashed host report fixture Fatal error: boom' started",
      "Test case 'OppiApp.swift:469: Fatal error: friction-repro' started",
      "Build log] Fatal error: boom",
      "",
    ].join("\n"));
    expect(result.attempts).toHaveLength(2);
    expect(result.calls).toContain("simctl erase");
    expect(result.summary.host_crash_line).toBeUndefined();
  });

  test("completion deadline is not postponed by continuing app log output", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      afterLog: "while :; do echo app-heartbeat; /bin/sleep 0.1; done",
    });
    expect(result.run.status).toBe(0);
    expect(result.summary.completion_hang_detected).toBe(true);
    expect(result.run.stderr).toContain("completion hang:");
    expect(result.attempts).toHaveLength(1);
  });

  // The 17 finishedTests rejection guards live in-process in sim-pool-ops.test.ts (with positive
  // controls); the hang-retry CLI path is covered by the tests above.

  test("real nonzero xcodebuild exit after a passed test summary is not masked", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, { afterLog: "exit 65" });
    expect(result.run.status).toBe(65);
    expect(result.summary.hang_detected).toBe(false);
    expect(result.attempts).toHaveLength(1);
  });

  test("a run the xcresult calls failed fails, though no test failed and xcodebuild exited 0", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      listed: { "FooTests/testA()": "Passed" },
      summary: { result: "Failed" },
      afterLog: "exit 0",
    });
    expect(result.run.status).toBe(65);
    expect(result.summary.test_results).toMatchObject({ result: "Failed", total: 1, passed: 1, failed: 0 });
    expect(result.run.stderr).toContain("the run failed with xcodebuild's exit 0: the xcresult says Failed, 0 failed of 1");
  });

  test("a failed Swift Testing summary fails the run though the xcresult and xcodebuild call it passed", () => {
    // What a land gate missed: an issue recorded after its test returned (a request that outlived
    // its test) fails the run's summary, every test case passes, xcodebuild exits 0, and Xcode
    // 27.1's xcresult says Passed. The run must not pass the lane, with or without a bundle.
    const withBundle = runCompletionFixture(swiftTestPrelude + swiftFailed, { listed: { "FooTests/testA()": "Passed" }, afterLog: "exit 0" });
    expect(withBundle.run.status).toBe(65);
    expect(withBundle.summary.test_results).toMatchObject({ result: "Passed", total: 1 });
    expect(withBundle.run.stderr).toContain(`the run failed with xcodebuild's exit 0: ${swiftFailed.trim()}`);
    const result = runCompletionFixture(swiftTestPrelude + swiftFailed, { afterLog: "exit 0" });
    expect(result.run.status).toBe(65);
    expect(result.summary.exit_code).toBe(65);
    expect(result.summary.hang_detected).toBe(false);
    expect(result.run.stderr).toContain(`the run failed with xcodebuild's exit 0: ${swiftFailed.trim()}`);
    expect(result.attempts).toHaveLength(1);
    expect(result.calls).not.toMatch(/simctl (shutdown|erase)/);
  });

  test("a run summary printed behind the test host's unfinished stderr line still decides the run", () => {
    // What a release gate hit: xcodebuild merges the host's stdout and stderr by chunk, so the
    // summary of a 5,127-test run followed half an os_log line, and the run read as zero tests.
    const stderrHead = "2026-11-14 12:24:21.110089-0800 Oppi[89210:124240232] [cfprefsd] WebContent[2506] Couldn't open /var/run/Library/Managed Pr";
    const stderrTail = "eferences/com.apple.Accessibility.plist due to No such file or directory\n";
    // The counts and the verdict come from the xcresult, wherever the log's run line landed.
    const nine = Object.fromEntries(Array.from({ length: 9 }, (_, i) => [`FooTests/test${i}()`, "Passed" as const]));
    const glued = swiftTestPrelude + stderrHead + swiftPassed + stderrTail;
    const passed = runCompletionFixture(glued, { args: ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests"], listed: nine, afterLog: "exit 0" });
    expect(passed.run.status).toBe(0);
    expect(passed.run.stderr).not.toContain("zero tests ran");
    expect(passed.summary.test_results).toMatchObject({ result: "Passed", total: 9, passed: 9, failed: 0, skipped: 0 });
    expect(passed.run.stdout).toContain("Tests: 9 (9 passed, 0 failed, 0 skipped); xcresult Passed");
    const failed = runCompletionFixture(swiftTestPrelude + stderrHead + swiftFailed + stderrTail, {
      listed: { ...nine, "FooTests/test8()": "Failed" },
      afterLog: "exit 0",
    });
    expect(failed.run.status).toBe(65);
    expect(failed.summary.test_results).toMatchObject({ result: "Failed", total: 9, passed: 8, failed: 1 });
    expect(failed.run.stdout).toContain("Failed tests (1):\n✘ OppiTests/FooTests/test8(): Expectation failed in FooTests/test8()\n");
    // An xcodebuild that lingers after such a summary is still a finished run, not a hang to retry,
    // and its counts are still the xcresult's.
    const lingering = runCompletionFixture(glued, { listed: nine });
    expect(lingering.run.status).toBe(0);
    expect(lingering.attempts).toHaveLength(1);
    expect(lingering.summary.test_completion).toMatchObject({ outcome: "passed", tests: 9 });
    expect(lingering.summary.test_results).toMatchObject({ total: 9, passed: 9 });
  });

  test("a selector run whose xcresult lists no test fails as zero tests, whatever the log printed", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      args: ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/Missing"],
      listed: {},
      afterLog: "exit 0",
    });
    expect(result.run.status).toBe(65);
    expect(result.run.stderr).toContain("error: zero tests ran for OppiTests/Missing: no test matches the selector (the xcresult lists no test)");
  });

  test("a passing run fails when any -only-testing selector matched no test the run lists, whatever else matched", () => {
    const log = swiftTestPrelude + swiftPassed;
    const unit = (...selectors: string[]) => ["-scheme", "OppiUnitTests", "test", ...selectors.map((selector) => `-only-testing:${selector}`)];
    // The file name matches nothing; the type name beside it runs, which is what hid it.
    const bad = runCompletionFixture(log, {
      args: unit("OppiTests/FooTests.swift", "OppiTests/FooTests"),
      listed: { "FooTests/testA()": "Passed", "FooTests/testB()": "Passed" },
      afterLog: "exit 0",
    });
    expect(bad.run.status).toBe(65);
    expect(bad.summary.exit_code).toBe(65);
    expect(bad.run.stderr).toContain("error: selector OppiTests/FooTests.swift matched no test (name a target, type, or test; not a file)");
    expect(bad.run.stderr).not.toContain("selector OppiTests/FooTests matched");
    // Target, Type, Type/method (Swift Testing and XCTest ids alike), and -skip-testing, which is never a selector.
    const good = runCompletionFixture(log, {
      args: [...unit("OppiTests", "OppiTests/FooTests", "OppiTests/FooTests/testA", "OppiTests/BarTests/testC"), "-skip-testing:OppiTests/Gone"],
      listed: { "FooTests/testA()": "Passed", "BarTests/testC": "Passed" },
      afterLog: "exit 0",
    });
    expect(good.run.status).toBe(0);
    expect(good.run.stderr).not.toContain("matched no test");
    // A method selector names one test: the type's other tests do not satisfy it.
    const method = runCompletionFixture(log, {
      args: unit("OppiTests/FooTests/testMissing"),
      listed: { "FooTests/testA()": "Passed" },
      afterLog: "exit 0",
    });
    expect(method.run.status).toBe(65);
    expect(method.run.stderr).toContain("selector OppiTests/FooTests/testMissing matched no test");
  });

  test("a selector whose tests are all skipped is matched: the xcresult lists them", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      args: ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests", "-only-testing:OppiTests/GatedTests", "-only-testing:OppiTests/GatedTests/testB"],
      listed: { "FooTests/testA()": "Passed", "GatedTests/testB()": "Skipped", "GatedTests/testC()": "Skipped" },
      afterLog: "exit 0",
    });
    expect(result.run.status).toBe(0);
    expect(result.run.stderr).not.toContain("matched no test");
  });

  test("an xcresult an earlier run left in the derived data is not this run's: the result is unreadable, never zero tests", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      args: ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests/FooTests.swift"],
      listed: { "FooTests/testA()": "Passed" },
      staleBundle: true,
      afterLog: "exit 0",
    });
    expect(result.run.status).toBe(0);
    expect(result.run.stderr).toContain("test result unreadable: no .xcresult in");
    expect(result.run.stderr).toContain("written by this run; the run's counts and selectors are not checked");
    expect(result.summary.test_results).toEqual({ unreadable: expect.stringContaining("written by this run") });
  });

  test("a bundle xcresulttool cannot read is reported as unreadable with its reason", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      listed: { "FooTests/testA()": "Passed" },
      summary: { totalTestCount: "not a count" },
      afterLog: "exit 0",
    });
    expect(result.summary.test_results).toEqual({ bundle: expect.stringMatching(/Run\.xcresult$/), unreadable: expect.stringContaining("is not test-results JSON") });
    expect(result.run.stdout).toContain("Tests: result unreadable (xcresulttool output");
  });

  test("nonzero exit racing completion-hang cleanup is not masked", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      afterLog: "trap 'exit 65' TERM; while :; do /bin/sleep 0.1; done",
    });
    expect(result.run.status).toBe(65);
    expect(result.summary.xcodebuild_exit_code).toBe(65);
    expect(result.attempts).toHaveLength(1);
  });

  test("finished tests with uncertain process-group cleanup cannot pass or retry", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, { failQuery: true });
    expect(result.run.status).toBe(1);
    expect(result.attempts).toHaveLength(1);
    expect(result.summary.incomplete).toBe(true);
    expect(result.summary.test_completion).toBeUndefined();
    expect(result.state === "unreadable" ? undefined : result.state?.status).toBe("uncertain");
  });

  test("full-path xcodebuild keeps argv after the executable", () => {
    const root = tempDir("fullpath");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const xcode = join(bin, "custom-xcodebuild");
    writeFileSync(xcode, readFileSync(join(bin, "xcodebuild"), "utf8"), { mode: 0o755 });
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", xcode, "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8").trim().split("\n");
    expect(args[0]).toBe("-project");
    expect(args).not.toContain(xcode);
    expect(args).not.toContain("xcodebuild");
  });

  test("run rewrites -resultBundlePath into the xcodebuild argv", () => {
    const root = tempDir("bundle");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [
        cli,
        "run",
        "--",
        "xcodebuild",
        "-project",
        "Oppi.xcodeproj",
        "-scheme",
        "Oppi",
        "test",
        "-resultBundlePath",
        "/tmp/OppiTests.xcresult",
      ],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const args = readFileSync(join(fake, "xcodebuild.args"), "utf8").trim().split("\n");
    expect(args).toContain("-resultBundlePath");
    expect(args).toContain("/tmp/OppiTests.xcresult");
  });

  test("always video policy records video_recording on the final artifact", () => {
    const root = tempDir("video");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const videos = join(root, "videos");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    mkdirSync(videos, { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_POOL_VIDEO_POLICY: "always",
      OPPI_SIM_POOL_VIDEO_DIR: videos,
      OPPI_SIM_POOL_VIDEO_NAME: "pool-video",
      OPPI_SIM_POOL_VIDEO_READY_TIMEOUT: "1",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const simctl = readFileSync(join(fake, "simctl.log"), "utf8");
    expect(simctl).toContain("io ");
    const logs = join(root, "clients", "apple", ".build", "logs");
    const summaries = existsSync(logs)
      ? readdirSync(logs).filter((name) => name.endsWith(".summary.json"))
      : [];
    expect(summaries.length).toBeGreaterThan(0);
    const artifact = JSON.parse(readFileSync(join(logs, summaries[0]), "utf8")) as {
      video_recording?: { policy?: string };
    };
    expect(artifact.video_recording?.policy).toBe("always");
  });

  test("status uses PATH xcrun and does not require a live simulator", () => {
    const root = tempDir("status");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync("bun", [cli, "status"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("Pool count: 1");
    expect(result.stdout).toContain("Oppi-Pool-0");
    expect(result.stdout).toContain("UDID-POOL-0");
  });

  test("post-build failed group query does not report CLI success", () => {
    const root = tempDir("final-query");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
printf '%s\\n' "$*" >> "$dir/xcrun.calls"
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun: unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    if [[ "\${1:-}" == "runtimes" ]]; then cat "$dir/runtimes.json"; exit 0; fi
    cat "$dir/devices.json"
    ;;
  bootstatus|boot|erase|delete|create|spawn|io|uninstall|keychain|privacy)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    if [[ "$sub" == "create" ]]; then echo UDID-CREATED; fi
    if [[ "$sub" == "io" ]]; then echo "Recording started" >&2; fi
    exit 0
    ;;
  shutdown)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    : > "$dir/fail-query"
    exit 0
    ;;
  *)
    echo "fake-xcrun: unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
      { mode: 0o755 },
    );
    writeFileSync(
      join(bin, "pgrep"),
      `#!/bin/bash
if [[ -f '${fake}/fail-query' ]]; then
  /bin/rm '${fake}/fail-query'
  : > '${fake}/injected'
  exit 2
fi
exec /usr/bin/pgrep "$@"
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_PGREP: join(bin, "pgrep"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_KEEP_BOOTED: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(existsSync(join(fake, "injected"))).toBe(true);
    expect(result.status).not.toBe(0);
    expect(result.status).not.toBe(130);
    expect(result.status).not.toBe(143);
    expect(result.stdout).not.toContain("========== BUILD SUCCEEDED ==========");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("uncertain");
    const logs = join(root, "clients", "apple", ".build", "logs");
    const summaries = existsSync(logs)
      ? readdirSync(logs).filter((name) => name.endsWith(".summary.json"))
      : [];
    expect(summaries.length).toBeGreaterThan(0);
    const artifact = JSON.parse(readFileSync(join(logs, summaries[0]), "utf8")) as {
      exit_code?: number;
      incomplete?: boolean;
    };
    expect(artifact.exit_code).not.toBe(0);
    expect(artifact.incomplete).toBe(true);
  });

  test("failed requested shutdown after a successful build is a CLI failure", () => {
    const root = tempDir("final-shutdown");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
printf '%s\\n' "$*" >> "$dir/xcrun.calls"
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun: unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    if [[ "\${1:-}" == "runtimes" ]]; then cat "$dir/runtimes.json"; exit 0; fi
    cat "$dir/devices.json"
    ;;
  bootstatus|boot|erase|delete|create|spawn|io|uninstall|keychain|privacy)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    if [[ "$sub" == "create" ]]; then echo UDID-CREATED; fi
    if [[ "$sub" == "io" ]]; then echo "Recording started" >&2; fi
    exit 0
    ;;
  shutdown)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    echo "Unable to shutdown device in current state: Booted" >&2
    exit 1
    ;;
  *)
    echo "fake-xcrun: unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_KEEP_BOOTED: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).not.toBe(0);
    expect(result.status).not.toBe(130);
    expect(result.status).not.toBe(143);
    expect(result.stdout).not.toContain("========== BUILD SUCCEEDED ==========");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
    const logs = join(root, "clients", "apple", ".build", "logs");
    const summaries = existsSync(logs)
      ? readdirSync(logs).filter((name) => name.endsWith(".summary.json"))
      : [];
    expect(summaries.length).toBeGreaterThan(0);
    const artifact = JSON.parse(readFileSync(join(logs, summaries[0]), "utf8")) as {
      exit_code?: number;
      incomplete?: boolean;
    };
    expect(artifact.exit_code).not.toBe(0);
    expect(artifact.incomplete).toBe(true);
  });

  test("late final artifact write failure does not report CLI success", () => {
    const root = tempDir("final-artifact");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const logs = join(root, "clients", "apple", ".build", "logs");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
printf '%s\\n' "$*" >> "$dir/xcrun.calls"
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun: unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    if [[ "\${1:-}" == "runtimes" ]]; then cat "$dir/runtimes.json"; exit 0; fi
    cat "$dir/devices.json"
    ;;
  bootstatus|boot|erase|delete|create|spawn|io|uninstall|keychain|privacy)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    if [[ "$sub" == "create" ]]; then echo UDID-CREATED; fi
    if [[ "$sub" == "io" ]]; then echo "Recording started" >&2; fi
    exit 0
    ;;
  shutdown)
    printf '%s\\n' "$sub \${1:-}" >> "$dir/simctl.log"
    chmod a-w "${logs}"
    exit 0
    ;;
  *)
    echo "fake-xcrun: unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_KEEP_BOOTED: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    if (existsSync(logs)) {
      chmodSync(logs, 0o755);
    }
    expect(result.status).not.toBe(0);
    expect(result.status).not.toBe(130);
    expect(result.status).not.toBe(143);
    expect(result.stdout).not.toContain("========== BUILD SUCCEEDED ==========");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
  });

  test("successful build and requested shutdown stays reusable", () => {
    const root = tempDir("final-success");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
    mkdirSync(join(root, "home"), { recursive: true });
    initCheckout(root);
    writeFileSync(join(fake, "devices.json"), devicesJson());
    writeFileSync(join(fake, "runtimes.json"), runtimesJson());
    writeFakeXcrun(bin, fake);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
      OPPI_SIM_POOL_KEEP_BOOTED: "0",
      OPPI_SIM_POOL_BOOT_TIMEOUT: "1",
      OPPI_SIM_POOL_PROGRESS_POLL: "0.05",
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    delete env.PIOS_ROOT;
    const result = spawnSync(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("========== BUILD SUCCEEDED ==========");
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("shutdown");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
    const logs = join(root, "clients", "apple", ".build", "logs");
    const summaries = existsSync(logs)
      ? readdirSync(logs).filter((name) => name.endsWith(".summary.json"))
      : [];
    expect(summaries.length).toBeGreaterThan(0);
    const artifact = JSON.parse(readFileSync(join(logs, summaries[0]), "utf8")) as {
      exit_code?: number;
      incomplete?: boolean;
    };
    expect(artifact.exit_code).toBe(0);
    expect(artifact.incomplete).toBeUndefined();
    const reuse = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
  });
});
