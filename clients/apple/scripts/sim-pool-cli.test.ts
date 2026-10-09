import { afterEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readSlotState, releaseReusable, tryAcquireSlot } from "./sim-pool-lock";

const cli = join(import.meta.dir, "sim-pool.ts");
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
  bootstatus|boot|shutdown|erase|delete|create|spawn|io)
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
printf '%s\\n' "$@" > "${fakeDir}/xcodebuild.args"
echo "** BUILD SUCCEEDED **"
echo "Test run with 3 tests passed"
exit 0
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

function runCompletionFixture(text: string, options: {
  /** Replaces the default unit-lane arguments. */
  args?: string[];
  extraArgs?: string[];
  env?: Record<string, string>;
  afterLog?: string;
  failQuery?: boolean;
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
  writeFileSync(join(bin, "xcodebuild"), `#!/bin/sh
set -eu
echo attempt >> "${fake}/attempts"
cat <<'TEST_LOG'
${text}TEST_LOG
: > "${fake}/started"
${options.afterLog ?? "exec /bin/sleep 30"}
`, { mode: 0o755 });
  if (options.failQuery) {
    writeFileSync(join(bin, "pgrep"), `#!/bin/sh
if [ -f "${fake}/started" ]; then exit 2; fi
exec /usr/bin/pgrep "$@"
`, { mode: 0o755 });
  }
  const args = options.args ?? ["-scheme", "OppiUnitTests", "test", "-only-testing:OppiTests"];
  const run = spawnSync("bun", [cli, "run", "--", "xcodebuild", ...args, ...(options.extraArgs ?? [])], {
    cwd: root,
    encoding: "utf8",
    timeout: 15_000,
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
      ...options.env,
    },
  });
  const logs = join(root, "clients", "apple", ".build", "logs");
  const summary = JSON.parse(readFileSync(join(logs, readdirSync(logs).find((name) => name.endsWith(".summary.json"))!), "utf8"));
  return {
    run, summary,
    attempts: readFileSync(join(fake, "attempts"), "utf8").trim().split("\n"),
    calls: readFileSync(join(fake, "xcrun.calls"), "utf8"),
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

describe("sim-pool CLI", () => {
  test("ipad diagnostic uses repo runner and refuses unleased ensure", () => {
    const text = readFileSync(join(import.meta.dir, "ipad-shell-diagnostic.sh"), "utf8");
    expect(text).not.toContain("reserve_lower_pool_slots");
    expect(text).toContain("OPPI_SIM_POOL_SLOT_START");
    expect(text).toContain("clients/apple/scripts/sim-pool.sh");
    expect(text).not.toContain(".pi/agent/skills/oppi-dev/scripts/sim-pool.sh");
    const directory = tempDir("ipad-diag");
    const developerDir = join(directory, "Developer");
    const bin = join(directory, "bin");
    mkdirSync(developerDir);
    mkdirSync(bin);
    writeFileSync(
      join(bin, "xcrun"),
      "#!/bin/sh\nprintf '%s\\n' '{\"devicetypes\":[{\"name\":\"iPad\",\"identifier\":\"com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation\"}]}'\n",
      { mode: 0o755 },
    );
    const result = spawnSync("bash", [join(import.meta.dir, "ipad-shell-diagnostic.sh"), "ensure"], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        DEVELOPER_DIR: developerDir,
      },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("unsupported without a pool lease");
  });

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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "build"], {
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "build"], {
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
    const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-scheme", finished ? "OppiUnitTests" : "Oppi", finished ? "test" : "build", "-only-testing:OppiTests"], {
      cwd: join(root, "clients", "apple"),
      env,
      stdio: "ignore",
    });
    procs.push(child);
    const start = Date.now();
    while (!existsSync(join(fake, "xcodebuild.started")) && Date.now() - start < 8000) {
      await Bun.sleep(20);
    }
    expect(existsSync(join(fake, "xcodebuild.started"))).toBe(true);
    child.kill("SIGTERM");
    const code = await new Promise<number | null>((resolve) => child.once("exit", (value) => resolve(value)));
    expect(code).toBe(143);
    const reuse = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      releaseReusable(reuse.owned);
    }
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("bootstatus");
    expect(simctl).not.toContain("erase");
    expect(simctl).not.toMatch(/^shutdown /m);
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
      [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "build"],
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
  erase|boot|delete|create|spawn|io)
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
      [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "build"],
      { cwd: join(root, "clients", "apple"), env, encoding: "utf8" },
    );
    expect(result.status).not.toBe(0);
    // Prove the failure came from the hang-recovery path, not from an earlier step.
    expect(result.stderr).toContain("hang detected");
    expect(result.stderr).toContain("Recovery: shutting down + erasing");
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("shutdown");
    expect(simctl).not.toContain("erase");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
  }, 15000);

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
      expect(result.run.stdout).toContain("Result bundle/coverage may be incomplete");
      expect(result.state === "unreadable" ? undefined : result.state?.status).toBe("reusable");
    }, 15_000);
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
    }, 15_000);
  }

  test("silent build that keeps the CPU busy is progress, not a hang", () => {
    // Like swift-frontend emitting a module: no log output for longer than the
    // silence timeout, in a child process outside xcodebuild's process group.
    const result = runCompletionFixture("", {
      env: { OPPI_SIM_POOL_SILENCE_TIMEOUT: "2" },
      afterLog: "/usr/bin/perl -e 'my $end = time + 5; 1 while time < $end' & wait; exit 0",
    });
    expect(result.run.status).toBe(0);
    expect(result.attempts).toHaveLength(1);
    expect(result.summary.hang_detected).toBe(false);
    expect(result.run.stderr).not.toContain("hang detected");
  }, 15_000);

  test("CPU alone cannot keep a silent run alive past five silence windows", () => {
    const result = runCompletionFixture("", {
      env: { OPPI_SIM_POOL_HANG_RETRIES: "0" },
      afterLog: "exec /usr/bin/perl -e 'my $end = time + 12; 1 while time < $end'",
    });
    expect(result.run.status).not.toBe(0);
    expect(result.summary.hang_detected).toBe(true);
    // Up to five 1-second windows of CPU-only life, then the kill; the spinner would run 12
    // seconds. Without the CPU signal the kill would come after one window instead.
    expect(result.summary.elapsed_seconds).toBeGreaterThanOrEqual(4);
    expect(result.summary.elapsed_seconds).toBeLessThan(11);
  }, 20_000);

  test("completion deadline is not postponed by continuing app log output", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      afterLog: "while :; do echo app-heartbeat; /bin/sleep 0.1; done",
    });
    expect(result.run.status).toBe(0);
    expect(result.summary.completion_hang_detected).toBe(true);
    expect(result.run.stderr).toContain("completion hang:");
    expect(result.attempts).toHaveLength(1);
  }, 15_000);

  const completionGuards = [
    { name: "pre-test launch stall", text: "Build succeeded; launching test host...\n" },
    { name: "foreign project", text: swiftTestPrelude + swiftPassed, extraArgs: ["-project", "/tmp/Other.xcodeproj"] },
    { name: "suite result without run completion", text: swiftTestPrelude + "✔ Suite example passed after 1.0 seconds.\n" },
    { name: "zero tests", text: swiftTestPrelude + swiftPassed.replace("9 tests", "0 tests") },
    { name: "truncated terminal line", text: swiftTestPrelude + swiftPassed.replace("seconds.", "seconds") },
    { name: "no XCTest completion", text: "◇ Test run started.\n" + swiftPassed },
    { name: "later test activity", text: swiftTestPrelude + swiftPassed + "◇ Test unfinished() started.\n" },
    { name: "multiple test processes", text: swiftTestPrelude + swiftPassed + swiftTestPrelude + swiftPassed },
    { name: "multiple bundles", text: swiftTestPrelude + swiftPassed, extraArgs: ["-only-testing:OppiE2ETests"] },
    { name: "repeated tests", text: swiftTestPrelude + swiftPassed, extraArgs: ["-test-iterations", "2"] },
    { name: "parallel workers", text: swiftTestPrelude + swiftPassed, extraArgs: ["-parallel-testing-enabled", "YES"] },
    { name: "XCTest failures", text: swiftTestPrelude.replace("with 0 failures", "with 1 failures") + swiftPassed },
    { name: "infrastructure failure", text: swiftTestPrelude + swiftPassed + "Testing failed:\nrunner disconnected\n" },
    { name: "XCTest run of two bundles", text: xctestE2E(0), args: [...e2eArgs, "-only-testing:OppiUITests"] },
    { name: "XCTest activity after the top-level result", text: xctestE2E(0) + "Test Suite 'Selected tests' started at 2026-10-08 20:09:15.000.\n", args: e2eArgs },
    { name: "XCTest run of a parallel scheme", text: xctestE2E(0), args: ["-scheme", "OppiMac", "test", "-only-testing:OppiMacTests"] },
    { name: "XCTest passed with failures", text: xctestE2E(1).replaceAll("failed at", "passed at"), args: e2eArgs },
  ];
  for (const guard of completionGuards) {
    test(`${guard.name} cannot turn an incomplete hang into a pass`, () => {
      const result = runCompletionFixture(guard.text, { args: guard.args, extraArgs: guard.extraArgs });
      expect(result.run.status).toBe(143);
      expect(result.attempts).toHaveLength(2);
      expect(result.summary.hang_detected).toBe(true);
      expect(result.summary.completion_hang_detected).toBeUndefined();
      expect(result.summary.test_completion).toBeUndefined();
      expect(result.calls).toContain("simctl erase");
    }, 15_000);
  }

  test("real nonzero xcodebuild exit after a passed test summary is not masked", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, { afterLog: "exit 65" });
    expect(result.run.status).toBe(65);
    expect(result.summary.hang_detected).toBe(false);
    expect(result.attempts).toHaveLength(1);
  });

  test("nonzero exit racing completion-hang cleanup is not masked", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, {
      afterLog: "trap 'exit 65' TERM; while :; do /bin/sleep 0.1; done",
    });
    expect(result.run.status).toBe(65);
    expect(result.summary.xcodebuild_exit_code).toBe(65);
    expect(result.attempts).toHaveLength(1);
  }, 15_000);

  test("finished tests with uncertain process-group cleanup cannot pass or retry", () => {
    const result = runCompletionFixture(swiftTestPrelude + swiftPassed, { failQuery: true });
    expect(result.run.status).toBe(1);
    expect(result.attempts).toHaveLength(1);
    expect(result.summary.incomplete).toBe(true);
    expect(result.summary.test_completion).toBeUndefined();
    expect(result.state === "unreadable" ? undefined : result.state?.status).toBe("uncertain");
  }, 15_000);

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
      [cli, "run", "--", xcode, "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
  bootstatus|boot|erase|delete|create|spawn|io)
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
  bootstatus|boot|erase|delete|create|spawn|io)
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
  bootstatus|boot|erase|delete|create|spawn|io)
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"],
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
