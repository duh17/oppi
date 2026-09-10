import { afterEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  readSlotState,
  releaseReusable,
  releaseUncertain,
  tryAcquireSlot,
} from "./sim-pool-lock";

const cli = join(import.meta.dir, "sim-pool.ts");
const temps: string[] = [];
const procs: ChildProcess[] = [];

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function killPid(pid: number, signal: NodeJS.Signals = "SIGKILL"): void {
  if (!Number.isSafeInteger(pid) || pid <= 1) {
    return;
  }
  try {
    process.kill(pid, signal);
  } catch {
    // already gone
  }
}

function killGroup(pgid: number): void {
  if (!Number.isSafeInteger(pgid) || pgid <= 1) {
    return;
  }
  try {
    process.kill(-pgid, "SIGKILL");
  } catch {
    // already gone
  }
}

function waitForFile(path: string, timeoutMs = 4000): Promise<string> {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (existsSync(path)) {
        const text = readFileSync(path, "utf8");
        if (text.trim().length > 0) {
          resolve(text);
          return;
        }
      }
      if (Date.now() - start > timeoutMs) {
        reject(new Error(`timeout waiting for ${path}`));
        return;
      }
      setTimeout(tick, 20);
    };
    tick();
  });
}

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-sim-shut-${label}-`));
  temps.push(dir);
  return dir;
}

function writeDevices(path: string, extra = ""): void {
  writeFileSync(
    path,
    `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      },
      {
        "udid": "UDID-POOL-1",
        "name": "Oppi-Pool-1",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      },
      {
        "udid": "UDID-POOL-2",
        "name": "Oppi-Pool-2",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      },
      {
        "udid": "UDID-OTHER",
        "name": "iPhone 16 Pro",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
      ${extra}
    ]
  }
}`,
  );
}

function installFakeXcrun(bin: string, fakeDir: string): void {
  mkdirSync(bin, { recursive: true });
  writeFileSync(
    join(bin, "xcrun"),
    `#!/usr/bin/env bash
set -euo pipefail
dir="${fakeDir}"
if [[ "\${1:-}" != "simctl" ]]; then
  echo "fake-xcrun unexpected $*" >&2
  exit 127
fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    list_n=0
    if [[ -f "$dir/list_count" ]]; then list_n=$(cat "$dir/list_count"); fi
    list_n=$((list_n + 1))
    printf '%s\\n' "$list_n" > "$dir/list_count"
    if [[ -f "$dir/fail_list_count" && "$(cat "$dir/fail_list_count")" == "$list_n" ]]; then
      echo "fake-xcrun: simulated list failure" >&2
      exit 1
    fi
    if [[ "$list_n" -ge 2 && -f "$dir/devices_recheck.json" ]]; then
      cat "$dir/devices_recheck.json"
    else
      cat "$dir/devices.json"
    fi
    ;;
  shutdown)
    printf '%s\\n' "\${1:-}" >> "$dir/shutdown.log"
    if [[ -f "$dir/fail_shutdown" ]]; then
      echo "simctl: Unable to shutdown device \${1:-}" >&2
      exit 1
    fi
    if [[ -f "$dir/hold_shutdown" ]]; then
      sleep 30
    fi
    ;;
  *)
    echo "fake-xcrun unexpected simctl $sub $*" >&2
    exit 127
    ;;
esac
`,
    { mode: 0o755 },
  );
}

function shutdown(lockDir: string, fakeDir: string, bin: string): ReturnType<typeof spawnSync> {
  return spawnSync("bun", [cli, "shutdown-idle"], {
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      OPPI_SIM_POOL_LOCK_DIR: lockDir,
      OPPI_SIM_POOL_COUNT: "6",
    },
    encoding: "utf8",
  });
}

function shutdownLog(fakeDir: string): string {
  const path = join(fakeDir, "shutdown.log");
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

afterEach(() => {
  for (const child of procs.splice(0)) {
    if (child.exitCode == null && child.signalCode == null) {
      child.kill("SIGKILL");
    }
  }
  for (const dir of temps.splice(0)) {
    for (const name of ["desc-pid", "shutdown-pgid", "child-pid"]) {
      const path = join(dir, name);
      if (existsSync(path)) {
        const pid = Number(readFileSync(path, "utf8").trim());
        killPid(pid);
        killGroup(pid);
      }
      const nested = join(dir, "fake", name);
      if (existsSync(nested)) {
        const pid = Number(readFileSync(nested, "utf8").trim());
        killPid(pid);
        killGroup(pid);
      }
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("sim-pool shutdown-idle", () => {
  test("skips live flock and shuts down an unlocked sibling", () => {
    const root = tempDir("live");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeDevices(join(fake, "devices.json"));
    installFakeXcrun(bin, fake);
    const held = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(held.ok).toBe(true);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).toBe(0);
    const log = shutdownLog(fake);
    expect(log).not.toContain("UDID-POOL-0");
    expect(log).toContain("UDID-POOL-1");
    expect(log).not.toContain("UDID-POOL-2");
    expect(log).not.toContain("UDID-OTHER");
  });

  test("skips legacy and in-flight slots without reaping", () => {
    const root = tempDir("legacy");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeDevices(join(fake, "devices.json"));
    installFakeXcrun(bin, fake);
    mkdirSync(join(lockDir, "slot-0"), { recursive: true });
    writeFileSync(join(lockDir, "slot-0", "pid"), "not-a-pid\n");
    const held = tryAcquireSlot({ lockDir, slot: 1, argv: ["run"] });
    expect(held.ok).toBe(true);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).toBe(0);
    expect(shutdownLog(fake)).toBe("");
    expect(existsSync(join(lockDir, "slot-0", "pid"))).toBe(true);
  });

  test("reports shutdown failure", () => {
    const root = tempDir("fail");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeDevices(join(fake, "devices.json"));
    writeFileSync(join(fake, "fail_shutdown"), "1");
    installFakeXcrun(bin, fake);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("UDID-POOL-0");
    const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      releaseReusable(reuse.owned);
    }
  });

  test("skips non-Booted recheck", () => {
    const root = tempDir("recheck");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(
      join(fake, "devices_recheck.json"),
      `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-POOL-0",
        "name": "Oppi-Pool-0",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ]
  }
}`,
    );
    installFakeXcrun(bin, fake);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).toBe(0);
    expect(shutdownLog(fake)).toBe("");
  });

  test("failed recheck is reported", () => {
    const root = tempDir("recheck-fail");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(join(fake, "fail_list_count"), "2");
    installFakeXcrun(bin, fake);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("failed to recheck");
    expect(shutdownLog(fake)).toBe("");
  });

  test("idle booted pool devices are shut down and non-pool devices are not", () => {
    const root = tempDir("idle");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeDevices(join(fake, "devices.json"));
    installFakeXcrun(bin, fake);
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).toBe(0);
    const log = shutdownLog(fake);
    expect(log).toContain("UDID-POOL-0");
    expect(log).toContain("UDID-POOL-1");
    expect(log).not.toContain("UDID-POOL-2");
    expect(log).not.toContain("UDID-OTHER");
  });

  test("contender planted during list is skipped", () => {
    const root = tempDir("race");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeDevices(join(fake, "devices.json"));
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
if [[ "\$1" != "simctl" ]]; then exit 127; fi
shift
if [[ "\$1" == "list" ]]; then
  mkdir -p "${lockDir}/slot-0"
  echo 1 > "${lockDir}/slot-0/pid"
  cat "$dir/devices.json"
  exit 0
fi
if [[ "\$1" == "shutdown" ]]; then echo "\$2" >> "$dir/shutdown.log"; exit 0; fi
exit 127
`,
      { mode: 0o755 },
    );
    const result = shutdown(lockDir, fake, bin);
    expect(result.status).toBe(0);
    expect(shutdownLog(fake)).not.toContain("UDID-POOL-0");
    expect(existsSync(join(lockDir, "slot-0", "pid"))).toBe(true);
  });

  test("second shutdown skips a slot the first still holds", async () => {
    const root = tempDir("two");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(join(fake, "hold_shutdown"), "1");
    installFakeXcrun(bin, fake);
    const first = spawn("bun", [cli, "shutdown-idle"], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}`, OPPI_SIM_POOL_LOCK_DIR: lockDir },
      stdio: "ignore",
    });
    procs.push(first);
    await waitForFile(join(fake, "shutdown.log"));
    const second = shutdown(lockDir, fake, bin);
    expect(second.status).toBe(0);
    expect(shutdownLog(fake).trim().split("\n").length).toBe(1);
    first.kill("SIGTERM");
    await new Promise((resolve) => first.once("exit", resolve));
  });

  test("TERM during held shutdown reaps the simctl child", async () => {
    const root = tempDir("term");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(join(fake, "hold_shutdown"), "1");
    installFakeXcrun(bin, fake);
    const child = spawn("bun", [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
      },
      stdio: "ignore",
    });
    procs.push(child);
    await waitForFile(join(fake, "shutdown.log"));
    child.kill("SIGTERM");
    const code = await new Promise<number | null>((resolve) => child.once("exit", (value) => resolve(value)));
    expect(code).not.toBe(0);
    const state = readSlotState(lockDir, 0);
    expect(state === "unreadable" ? undefined : state?.pgids.length).toBeGreaterThan(0);
    const second = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(second.ok).toBe(true);
    if (second.ok) {
      releaseReusable(second.owned);
    }
  });

  test("contender cannot acquire while shutdown-idle still holds the slot", async () => {
    const root = tempDir("inverse");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(join(fake, "hold_shutdown"), "1");
    installFakeXcrun(bin, fake);
    const first = spawn("bun", [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        HOME: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
      },
      stdio: "ignore",
    });
    procs.push(first);
    await waitForFile(join(fake, "shutdown.log"));
    const contender = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(contender.ok).toBe(false);
    const run = spawnSync("bun", [cli, "run", "--", "xcodebuild", "build"], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        HOME: root,
        OPPI_ROOT: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
        OPPI_SIM_POOL_WAIT: "0",
        OPPI_SIM_SLIM: "0",
      },
      encoding: "utf8",
    });
    expect(run.status).not.toBe(0);
    first.kill("SIGTERM");
    await new Promise((resolve) => first.once("exit", resolve));
  });

  test("shutdown-idle does not publish reusable while a descendant is alive",
    async () => {
    const root = tempDir("overlap");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "udid": "UDID-PRIVATE-PROBE",
        "name": "Oppi-Pool-0",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
      }
    ]
  }
}`,
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/bin/bash
set -euo pipefail
[[ "$1" == simctl ]] || exit 99
case "$2" in
list) /bin/cat "$FAKE_ROOT/devices.json" ;;
shutdown)
  echo $$ > "$FAKE_ROOT/shutdown-pgid"
  /bin/sh -c 'trap "" TERM; echo $$ > "$FAKE_ROOT/desc-pid"; /bin/sleep 30' >/dev/null 2>&1 &
  while [[ ! -s "$FAKE_ROOT/desc-pid" ]]; do /bin/sleep 0.01; done
  exit 0
  ;;
*) exit 98 ;;
esac
`,
      { mode: 0o755 },
    );
    const child = spawn(process.execPath, [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:/usr/bin:/bin`,
        HOME: root,
        OPPI_ROOT: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
        FAKE_ROOT: fake,
      },
      stdio: "ignore",
    });
    procs.push(child);
    const descPath = join(fake, "desc-pid");
    const statePath = join(lockDir, "slot-0.state.json");
    const descText = await waitForFile(descPath);
    let overlap = false;
    let descendantPid = Number(descText.trim());
    const deadline = Date.now() + 7000;
    while (Date.now() < deadline && child.exitCode == null) {
      if (existsSync(statePath) && existsSync(descPath)) {
        let state: { status?: string } | null = null;
        try {
          state = JSON.parse(readFileSync(statePath, "utf8")) as { status?: string };
        } catch {
          state = null;
        }
        const pid = Number(readFileSync(descPath, "utf8").trim());
        if (state?.status === "reusable" && alive(pid)) {
          const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["private-contender"] });
          const childStillAlive = alive(pid);
          overlap = acquired.ok && childStillAlive;
          descendantPid = pid;
          if (acquired.ok) {
            releaseUncertain(acquired.owned, "overlap fixture only");
          }
          break;
        }
        descendantPid = pid;
      }
      await Bun.sleep(5);
    }
    expect(overlap).toBe(false);
    const exitCode = await new Promise<number | null>((resolve) => {
      if (child.exitCode != null || child.signalCode != null) {
        resolve(child.exitCode);
        return;
      }
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        resolve(null);
      }, 9000);
      child.once("exit", (code) => {
        clearTimeout(timer);
        resolve(code);
      });
    });
    if (descendantPid > 0) {
      expect(alive(descendantPid)).toBe(false);
    }
    if (existsSync(join(fake, "shutdown-pgid"))) {
      killGroup(Number(readFileSync(join(fake, "shutdown-pgid"), "utf8").trim()));
    }
    const state = readSlotState(lockDir, 0);
    expect(state === "unreadable" ? undefined : state?.status).toBe("reusable");
    const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["reuse-after-quiescence"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      releaseReusable(reuse.owned);
    }
    expect(exitCode).toBe(0);
  });

  test("TERM during locked recheck does not spawn shutdown and does not permanently quarantine", async () => {
    const root = tempDir("recheck-term");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/usr/bin/env bash
set -euo pipefail
dir="${fake}"
if [[ "\${1:-}" != "simctl" ]]; then exit 127; fi
shift
sub="\${1:-}"
shift || true
case "$sub" in
  list)
    list_n=0
    if [[ -f "$dir/list_count" ]]; then list_n=$(cat "$dir/list_count"); fi
    list_n=$((list_n + 1))
    printf '%s\\n' "$list_n" > "$dir/list_count"
    if [[ "$list_n" -ge 2 ]]; then
      printf 'recheck\\n' > "$dir/recheck.started"
      sleep 30
    fi
    cat "$dir/devices.json"
    ;;
  shutdown)
    printf '%s\\n' "\${1:-}" >> "$dir/shutdown.log"
    ;;
  *)
    exit 127
    ;;
esac
`,
      { mode: 0o755 },
    );
    const child = spawn("bun", [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        HOME: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
      },
      stdio: "ignore",
    });
    procs.push(child);
    await waitForFile(join(fake, "recheck.started"));
    child.kill("SIGTERM");
    const code = await new Promise<number | null>((resolve) => child.once("exit", (value) => resolve(value)));
    expect(code).not.toBe(0);
    expect(existsSync(join(fake, "shutdown.log"))).toBe(false);
    const state = readSlotState(lockDir, 0);
    expect(state === "unreadable" ? undefined : state?.pgids.length).toBeGreaterThan(0);
    const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      releaseReusable(reuse.owned);
    }
  });

  test("failed process-group query after shutdown does not publish reusable", async () => {
    const root = tempDir("pgrep-fail");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/bin/bash
set -euo pipefail
[[ "$1" == simctl ]] || exit 99
case "$2" in
list) /bin/cat "$FAKE_ROOT/devices.json" ;;
shutdown)
  echo $$ > "$FAKE_ROOT/shutdown-pgid"
  /bin/sh -c 'trap "" TERM; echo $$ > "$FAKE_ROOT/desc-pid"; /bin/sleep 30' >/dev/null 2>&1 &
  while [[ ! -s "$FAKE_ROOT/desc-pid" ]]; do /bin/sleep 0.01; done
  printf '1\n' > "$FAKE_ROOT/fail-pgrep"
  exit 0
  ;;
*) exit 98 ;;
esac
`,
      { mode: 0o755 },
    );
    writeFileSync(
      join(bin, "pgrep"),
      `#!/bin/bash
if [[ -f "${fake}/fail-pgrep" ]]; then
  exit 2
fi
exec /usr/bin/pgrep "$@"
`,
      { mode: 0o755 },
    );
    const result = spawnSync(process.execPath, [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:/usr/bin:/bin`,
        HOME: root,
        OPPI_ROOT: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
        FAKE_ROOT: fake,
        OPPI_SIM_POOL_PGREP: join(bin, "pgrep"),
      },
      encoding: "utf8",
    });
    if (existsSync(join(fake, "desc-pid"))) {
      killPid(Number(readFileSync(join(fake, "desc-pid"), "utf8").trim()));
    }
    if (existsSync(join(fake, "shutdown-pgid"))) {
      killGroup(Number(readFileSync(join(fake, "shutdown-pgid"), "utf8").trim()));
    }
    expect(result.status).not.toBe(0);
    const state = readSlotState(lockDir, 0);
    expect(state === "unreadable" ? undefined : state?.status).not.toBe("reusable");
    expect(state === "unreadable" ? undefined : state?.pgids.length).toBeGreaterThan(0);
    const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(reuse.ok).toBe(true);
    if (reuse.ok) {
      releaseReusable(reuse.owned);
    }
  });

  test("TERM during shutdown with a live descendant does not publish reusable", async () => {
    const root = tempDir("term-overlap");
    const fake = join(root, "fake");
    const bin = join(root, "bin");
    const lockDir = join(root, "locks");
    mkdirSync(fake, { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(fake, "devices.json"),
      `{
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
}`,
    );
    writeFileSync(
      join(bin, "xcrun"),
      `#!/bin/bash
set -euo pipefail
[[ "$1" == simctl ]] || exit 99
case "$2" in
list) /bin/cat "$FAKE_ROOT/devices.json" ;;
shutdown)
  echo $$ > "$FAKE_ROOT/shutdown-pgid"
  /bin/sh -c 'trap "" TERM; echo $$ > "$FAKE_ROOT/desc-pid"; /bin/sleep 30' >/dev/null 2>&1 &
  while [[ ! -s "$FAKE_ROOT/desc-pid" ]]; do /bin/sleep 0.01; done
  exit 0
  ;;
*) exit 98 ;;
esac
`,
      { mode: 0o755 },
    );
    const child = spawn(process.execPath, [cli, "shutdown-idle"], {
      env: {
        ...process.env,
        PATH: `${bin}:/usr/bin:/bin`,
        HOME: root,
        OPPI_ROOT: root,
        OPPI_SIM_POOL_LOCK_DIR: lockDir,
        OPPI_SIM_POOL_COUNT: "1",
        FAKE_ROOT: fake,
      },
      stdio: "ignore",
    });
    procs.push(child);
    const descPath = join(fake, "desc-pid");
    const descText = await waitForFile(descPath);
    const descendantPid = Number(descText.trim());
    expect(alive(descendantPid)).toBe(true);
    child.kill("SIGTERM");
    let overlap = false;
    const statePath = join(lockDir, "slot-0.state.json");
    const deadline = Date.now() + 7000;
    while (Date.now() < deadline && child.exitCode == null && child.signalCode == null) {
      if (existsSync(statePath) && alive(descendantPid)) {
        let state: { status?: string } | null = null;
        try {
          state = JSON.parse(readFileSync(statePath, "utf8")) as { status?: string };
        } catch {
          state = null;
        }
        if (state?.status === "reusable") {
          const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["private-contender"] });
          overlap = acquired.ok && alive(descendantPid);
          if (acquired.ok) {
            releaseUncertain(acquired.owned, "term-overlap fixture only");
          }
          break;
        }
      }
      await Bun.sleep(5);
    }
    expect(overlap).toBe(false);
    const exitCode = await new Promise<number | null>((resolve) => {
      if (child.exitCode != null || child.signalCode != null) {
        resolve(child.exitCode);
        return;
      }
      child.once("exit", (code) => resolve(code));
    });
    if (alive(descendantPid)) {
      const state = readSlotState(lockDir, 0);
      expect(state === "unreadable" ? undefined : state?.status).not.toBe("reusable");
      const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
      expect(reuse.ok).toBe(false);
    }
    expect(exitCode).not.toBe(0);
    if (existsSync(join(fake, "shutdown-pgid"))) {
      killGroup(Number(readFileSync(join(fake, "shutdown-pgid"), "utf8").trim()));
    }
    killPid(descendantPid);
  });
});
