import { afterEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readSlotState, tryAcquireSlot } from "./sim-pool-lock";

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
    const result = spawnSync("bash", [join(import.meta.dir, "ipad-shell-diagnostic.sh"), "ensure"], {
      encoding: "utf8",
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

  test("mismatch device fails without deleting", () => {
    const root = tempDir("mismatch");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    mkdirSync(fake, { recursive: true });
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
      OPPI_SIM_RUNTIME: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    };
    mkdirSync(join(root, "home"), { recursive: true });
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "build"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("Refusing to delete");
  });

  test("in-flight slot is not reused by a second run", () => {
    const root = tempDir("busy");
    mkdirSync(join(root, "locks"), { recursive: true });
    const held = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(held.ok).toBe(true);
    initCheckout(root);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      HOME: join(root, "home"),
      OPPI_ROOT: root,
      OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_POOL_WAIT: "0",
      OPPI_SIM_SLIM: "0",
    };
    mkdirSync(join(root, "home"), { recursive: true });
    const result = spawnSync("bun", [cli, "run", "--", "xcodebuild", "build"], {
      cwd: join(root, "clients", "apple"),
      env,
      encoding: "utf8",
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/busy or quarantined|in-flight/);
  });

  test("TERM during xcodebuild does not publish reusable", async () => {
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
    const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-scheme", "Oppi", "build"], {
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
    expect(code).not.toBe(0);
    const reuse = tryAcquireSlot({ lockDir: join(root, "locks"), slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(false);
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
    if [[ -f "$dir/xcodebuild.started" ]]; then
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
    const simctl = existsSync(join(fake, "simctl.log")) ? readFileSync(join(fake, "simctl.log"), "utf8") : "";
    expect(simctl).toContain("shutdown");
    expect(simctl).not.toContain("erase");
    const state = readSlotState(join(root, "locks"), 0);
    expect(state === "unreadable" ? undefined : state?.status).not.toBe("reusable");
  }, 15000);

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
    expect(state === "unreadable" ? undefined : state?.status).toBe("uncertain");
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
