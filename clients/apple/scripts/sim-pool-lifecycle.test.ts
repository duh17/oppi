import { afterEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claimVerdict, planIdleReap } from "./sim-pool-lifecycle";
import {
  readSlotState,
  releaseClaimed,
  releaseReusable,
  releaseUncertain,
  tryAcquireSlot,
  type SlotClaim,
} from "./sim-pool-lock";

const cli = join(import.meta.dir, "sim-pool.ts");
const temps: string[] = [];
const MINUTE = 60_000;

const IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro";
const DUO = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo";
const IOS_27_1 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1";

afterEach(() => {
  for (const dir of temps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

type FakeDevice = { name: string; state: "Booted" | "Shutdown"; type?: string };
type FakeSession = { status: string; ageMinutes: number; later?: { status: string; ageMinutes: number } };

/**
 * A stateful CoreSimulator stand-in: create/boot/shutdown/delete change the
 * device list that the next `simctl list` prints, and every call is logged.
 * The fake `oppi` answers its first call with each session's state and every
 * later call with `later` when given (a session that resumes mid-pass).
 */
function fakeSimulators(devices: FakeDevice[], sessions: Record<string, FakeSession> = {}) {
  const root = mkdtempSync(join(tmpdir(), "oppi-sim-life-"));
  temps.push(root);
  const bin = join(root, "bin");
  const lockDir = join(root, "locks");
  mkdirSync(bin, { recursive: true });
  const list: Record<string, unknown[]> = {};
  for (const device of devices) {
    (list[IOS_27_1] ??= []).push({
      udid: `UDID-${device.name}`,
      name: device.name,
      state: device.state,
      isAvailable: true,
      deviceTypeIdentifier: device.type ?? DUO,
    });
  }
  writeFileSync(join(root, "devices.json"), JSON.stringify({ devices: list }));
  writeFileSync(
    join(root, "runtimes.json"),
    JSON.stringify({
      runtimes: [
        {
          identifier: IOS_27_1,
          platform: "iOS",
          isAvailable: true,
          version: "27.1",
          buildversion: "24A94232",
          name: "iOS 27.1",
          bundlePath: "/r",
          runtimeRoot: "/r",
        },
      ],
    }),
  );
  writeFileSync(
    join(bin, "xcrun"),
    `#!/usr/bin/env bun
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
const dir = ${JSON.stringify(root)};
const [tool, sub, ...rest] = process.argv.slice(2);
appendFileSync(dir + "/calls.log", [sub, ...rest].join(" ") + "\\n");
if (tool !== "simctl") process.exit(127);
const path = dir + "/devices.json";
const data = JSON.parse(readFileSync(path, "utf8"));
const all = () => Object.values(data.devices).flat();
const save = () => writeFileSync(path, JSON.stringify(data));
const setState = (udid, state) => { for (const d of all()) if (d.udid === udid) d.state = state; save(); };
switch (sub) {
  case "list":
    process.stdout.write(rest[0] === "runtimes" ? readFileSync(dir + "/runtimes.json", "utf8") : JSON.stringify(data));
    break;
  case "create": {
    const [name, type, runtime] = rest;
    (data.devices[runtime] ??= []).push({ udid: "UDID-" + name, name, state: "Shutdown", isAvailable: true, deviceTypeIdentifier: type });
    save();
    console.log("UDID-" + name);
    break;
  }
  case "boot": setState(rest[0], "Booted"); break;
  case "shutdown": setState(rest[0], "Shutdown"); break;
  case "bootstatus": case "spawn": break;
  default: process.exit(127);
}
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "oppi"),
    `#!/usr/bin/env bun
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const counter = ${JSON.stringify(join(root, "oppi.calls"))};
const call = (existsSync(counter) ? Number(readFileSync(counter, "utf8")) : 0) + 1;
writeFileSync(counter, String(call));
const spec = ${JSON.stringify(sessions)};
const sessions = Object.fromEntries(
  Object.entries(spec).map(([id, s]) => {
    const now = call > 1 && s.later ? s.later : s;
    return [id, { id, status: now.status, last_activity: Date.now() - now.ageMinutes * ${MINUTE} }];
  }),
);
const [, verb, id] = process.argv.slice(2);
if (verb === "list") {
  console.log(JSON.stringify({ ok: true, data: { sessions: Object.values(sessions) } }));
} else if (sessions[id]) {
  const s = sessions[id];
  console.log(JSON.stringify({ ok: true, data: { session: { id, status: s.status, lastActivity: s.last_activity } } }));
} else {
  console.log(JSON.stringify({ ok: false, error: { code: "session_not_found", status: 404 } }));
}
`,
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "xcodebuild"),
    `#!/usr/bin/env bash
echo "** BUILD SUCCEEDED **"
`,
    { mode: 0o755 },
  );
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH ?? ""}`,
    HOME: root,
    OPPI_SIM_POOL_LOCK_DIR: lockDir,
    OPPI_SIM_POOL_WAIT: "0",
    OPPI_SIM_SLIM: "0",
    OPPI_SIM_POOL_BOOT_TIMEOUT: "5",
    OPPI_SIM_RUNTIME: IOS_27_1,
    DEVELOPER_DIR: root,
    // No background watcher in tests; the reap test turns the reaper on itself.
    OPPI_SIM_POOL_IDLE_MINUTES: "0",
  };
  delete env.OPPI_CALLER_SESSION_ID;
  delete env.OPPI_SIM_DEVICE_PROFILE;
  return {
    root,
    lockDir,
    env,
    pool(args: string[], extraEnv: NodeJS.ProcessEnv = {}) {
      return spawnSync("bun", [cli, ...args], { cwd: root, env: { ...env, ...extraEnv }, encoding: "utf8" });
    },
    state(name: string): string | undefined {
      const data = JSON.parse(readFileSync(join(root, "devices.json"), "utf8"));
      return Object.values(data.devices as Record<string, Array<{ name: string; state: string }>>)
        .flat()
        .find((device) => device.name === name)?.state;
    },
    shutdowns(): string[] {
      const path = join(root, "calls.log");
      return existsSync(path)
        ? readFileSync(path, "utf8")
            .split("\n")
            .filter((line) => line.startsWith("shutdown "))
            .map((line) => line.slice("shutdown UDID-".length))
        : [];
    },
  };
}

/** Writes a slot state the way the pool does, then backdates it. */
function seedSlot(lockDir: string, slot: number, ageMinutes: number, claim?: SlotClaim): void {
  const acquired = tryAcquireSlot({ lockDir, slot, argv: ["seed"] });
  if (!acquired.ok) {
    throw new Error(acquired.reason);
  }
  if (claim) {
    releaseClaimed(acquired.owned, claim);
  } else {
    releaseReusable(acquired.owned);
  }
  backdate(lockDir, slot, ageMinutes);
}

/**
 * Leaves the slot the way a shutdown that could not prove quiescence does:
 * `uncertain`, keeping any claim, with no live process group behind it.
 */
function seedUncertain(lockDir: string, slot: number, ageMinutes: number, claim?: SlotClaim): void {
  if (claim) {
    seedSlot(lockDir, slot, ageMinutes, claim);
  }
  const acquired = tryAcquireSlot({ lockDir, slot, argv: ["reap"], claimed: () => true });
  if (!acquired.ok) {
    throw new Error(acquired.reason);
  }
  releaseUncertain(acquired.owned, "shutdown did not prove quiescence");
  backdate(lockDir, slot, ageMinutes);
}

function backdate(lockDir: string, slot: number, ageMinutes: number): void {
  const path = join(lockDir, `slot-${slot}.state.json`);
  const state = JSON.parse(readFileSync(path, "utf8"));
  state.started_at = new Date(Date.now() - ageMinutes * MINUTE).toISOString();
  writeFileSync(path, JSON.stringify(state));
}

/** CLI success, with stderr in the failure diff. */
function expectOk(result: { status: number | null; stderr: string }): void {
  expect({ status: result.status, stderr: result.stderr }).toMatchObject({ status: 0 });
}

/** Each CLI call spawns bun plus fake simctl processes. */
const CLI_TIMEOUT = 60_000;

function slotStatus(lockDir: string, slot: number): string | undefined {
  const state = readSlotState(lockDir, slot);
  return state === "unreadable" ? "unreadable" : state?.status;
}

describe("idle reaping policy", () => {
  test("keeps the most recently used warm and expires the rest past the idle limit", () => {
    const now = 1_000 * MINUTE;
    const idle = [
      { slot: 0, udid: "A", lastUsedMs: now - 5 * MINUTE },
      { slot: 1, udid: "B", lastUsedMs: now - 40 * MINUTE },
      { slot: 2, udid: "C", lastUsedMs: now - 90 * MINUTE },
      { slot: 3, udid: "D", lastUsedMs: now - 20 * MINUTE },
    ];
    const warmTwo = planIdleReap(idle, now, 30 * MINUTE, 2);
    expect(warmTwo.expired.map((slot) => slot.udid).sort()).toEqual(["B", "C"]);
    expect(warmTwo.nextDueMs).toBeUndefined();

    // With one warm slot, D (20m idle) is not expired yet and sets the next pass.
    const warmOne = planIdleReap(idle, now, 30 * MINUTE, 1);
    expect(warmOne.expired.map((slot) => slot.udid).sort()).toEqual(["B", "C"]);
    expect(warmOne.nextDueMs).toBe(now + 10 * MINUTE);
  });

  test("claims follow their owner session", () => {
    const now = 1_000 * MINUTE;
    const idle = 30 * MINUTE;
    const claimedLongAgo = now - 120 * MINUTE;
    expect(claimVerdict("gone", now, idle, claimedLongAgo)).toBe("release");
    expect(claimVerdict({ status: "stopped", lastActivityMs: now }, now, idle, now)).toBe("release");
    expect(claimVerdict({ status: "busy", lastActivityMs: now - 600 * MINUTE }, now, idle, claimedLongAgo)).toBe(
      "keep",
    );
    expect(claimVerdict({ status: "ready", lastActivityMs: now - 31 * MINUTE }, now, idle, claimedLongAgo)).toBe(
      "power-down",
    );
    expect(claimVerdict({ status: "ready", lastActivityMs: now - 29 * MINUTE }, now, idle, claimedLongAgo)).toBe(
      "keep",
    );
    // A long-idle session that just claimed is about to use the simulator.
    expect(claimVerdict({ status: "ready", lastActivityMs: now - 120 * MINUTE }, now, idle, now - MINUTE)).toBe(
      "keep",
    );
    expect(claimVerdict("unknown", now, idle, claimedLongAgo)).toBe("keep");
  });
});

describe("sim-pool claim and release", () => {
  test("a session claims its own Duo simulator, keeps it across claims, and releases it", () => {
    const sim = fakeSimulators([{ name: "Oppi-Pool-30", state: "Shutdown" }]);

    const first = sim.pool(["claim", "--device-profile", "duo"], { OPPI_CALLER_SESSION_ID: "worker-a" });
    expectOk(first);
    expect(first.stdout.trim()).toBe("UDID-Oppi-Pool-30");
    expect(sim.state("Oppi-Pool-30")).toBe("Booted");
    expect(readSlotState(sim.lockDir, 30)).toMatchObject({
      status: "claimed",
      claim: { owner: "worker-a", profile: "duo" },
    });

    // The reaper powered it down while worker-a idled; claiming again boots the same device.
    spawnSync(join(sim.root, "bin", "xcrun"), ["simctl", "shutdown", "UDID-Oppi-Pool-30"], { env: sim.env });
    const again = sim.pool(["claim", "--device-profile", "duo", "--owner", "worker-a"]);
    expect(again.stdout.trim()).toBe("UDID-Oppi-Pool-30");
    expect(sim.state("Oppi-Pool-30")).toBe("Booted");

    const other = sim.pool(["claim", "--device-profile", "duo", "--owner", "worker-b"]);
    expectOk(other);
    expect(other.stdout.trim()).toBe("UDID-Oppi-Pool-31");

    const idle = sim.pool(["shutdown-idle"]);
    expectOk(idle);
    expect(sim.state("Oppi-Pool-30")).toBe("Booted");
    expect(sim.state("Oppi-Pool-31")).toBe("Booted");

    const stranger = sim.pool(["release", "UDID-Oppi-Pool-30", "--owner", "worker-b"]);
    expect(stranger.status).not.toBe(0);
    expect(sim.state("Oppi-Pool-30")).toBe("Booted");

    const released = sim.pool(["release", "--owner", "worker-a"]);
    expectOk(released);
    expect(sim.state("Oppi-Pool-30")).toBe("Shutdown");
    expect(slotStatus(sim.lockDir, 30)).toBe("reusable");
    expect(slotStatus(sim.lockDir, 31)).toBe("claimed");
  }, CLI_TIMEOUT);

  test("claim frees a stopped owner's slot when every claim slot is taken", () => {
    const sim = fakeSimulators([], { "worker-live": { status: "busy", ageMinutes: 0 } });
    for (let slot = 30; slot <= 37; slot += 1) {
      seedSlot(sim.lockDir, slot, 60, { owner: slot === 33 ? "worker-stopped" : "worker-live", profile: "duo" });
    }
    const result = sim.pool(["claim", "--device-profile", "duo", "--owner", "worker-new"]);
    expectOk(result);
    expect(result.stdout.trim()).toBe("UDID-Oppi-Pool-33");
    expect(readSlotState(sim.lockDir, 33)).toMatchObject({ claim: { owner: "worker-new" } });
    expect(readSlotState(sim.lockDir, 34)).toMatchObject({ claim: { owner: "worker-live" } });
  }, CLI_TIMEOUT);

  test("claiming again while a reaper holds the session's slot waits for that slot", async () => {
    const sim = fakeSimulators([{ name: "Oppi-Pool-30", state: "Booted" }]);
    seedSlot(sim.lockDir, 30, 5, { owner: "worker-a", profile: "duo" });
    const held = tryAcquireSlot({ lockDir: sim.lockDir, slot: 30, argv: ["reap"], claimed: () => true });
    expect(held.ok).toBe(true);
    if (!held.ok) {
      return;
    }
    const child = spawn("bun", [cli, "claim", "--device-profile", "duo", "--owner", "worker-a"], {
      cwd: sim.root,
      env: { ...sim.env, OPPI_SIM_POOL_WAIT: "30" },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    const exited = new Promise<number | null>((resolve) => child.on("close", resolve));
    await new Promise((resolve) => setTimeout(resolve, 1500));
    releaseClaimed(held.owned, { owner: "worker-a", profile: "duo" });
    expect({ status: await exited, stderr }).toMatchObject({ status: 0 });
    expect(stdout.trim()).toBe("UDID-Oppi-Pool-30");
    expect(readSlotState(sim.lockDir, 31)).toBeNull();
    expect(sim.state("Oppi-Pool-31")).toBeUndefined();
  }, CLI_TIMEOUT);
});

describe("sim-pool reap", () => {
  test("shuts down idle pool and stale claims, never warm, busy-owned, or unmanaged simulators", () => {
    const sim = fakeSimulators(
      [
        { name: "Oppi-Pool-0", state: "Booted", type: IPHONE },
        { name: "Oppi-Pool-1", state: "Booted", type: IPHONE },
        { name: "Oppi-Pool-2", state: "Booted", type: IPHONE },
        { name: "Oppi-Pool-30", state: "Booted" },
        { name: "Oppi-Pool-31", state: "Booted" },
        { name: "Oppi-Pool-32", state: "Booted" },
        { name: "Oppi-Pool-33", state: "Booted" },
        { name: "Chen iPhone", state: "Booted", type: IPHONE },
      ],
      {
        "worker-busy": { status: "busy", ageMinutes: 300 },
        "lead-idle": { status: "ready", ageMinutes: 120 },
        // Looks idle when the pass plans, starts a turn before its shutdown.
        "lead-resumes": { status: "ready", ageMinutes: 120, later: { status: "busy", ageMinutes: 0 } },
      },
    );
    // All three are past the idle limit; keep-warm 1 keeps only Pool-0.
    seedSlot(sim.lockDir, 0, 40);
    seedSlot(sim.lockDir, 1, 45);
    seedSlot(sim.lockDir, 2, 90);
    seedSlot(sim.lockDir, 30, 60, { owner: "worker-stopped", profile: "duo" });
    seedSlot(sim.lockDir, 31, 60, { owner: "worker-busy", profile: "duo" });
    seedSlot(sim.lockDir, 32, 60, { owner: "lead-idle", profile: "duo" });
    seedSlot(sim.lockDir, 33, 60, { owner: "lead-resumes", profile: "duo" });

    const result = sim.pool(["reap"], { OPPI_SIM_POOL_IDLE_MINUTES: "30", OPPI_SIM_POOL_KEEP_WARM: "1" });
    expectOk(result);
    expect(sim.shutdowns().sort()).toEqual(["Oppi-Pool-1", "Oppi-Pool-2", "Oppi-Pool-30", "Oppi-Pool-32"]);
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
    expect(sim.state("Oppi-Pool-31")).toBe("Booted");
    expect(sim.state("Oppi-Pool-33")).toBe("Booted");
    expect(sim.state("Chen iPhone")).toBe("Booted");
    expect(slotStatus(sim.lockDir, 30)).toBe("reusable");
    expect(readSlotState(sim.lockDir, 32)).toMatchObject({ status: "claimed", claim: { owner: "lead-idle" } });
    expect(readSlotState(sim.lockDir, 33)).toMatchObject({ status: "claimed", claim: { owner: "lead-resumes" } });
  }, CLI_TIMEOUT);

  test("finishes slots a failed shutdown left uncertain, and release frees its owner's", () => {
    const sim = fakeSimulators(
      [
        { name: "Oppi-Pool-2", state: "Booted", type: IPHONE },
        { name: "Oppi-Pool-34", state: "Booted" },
        { name: "Oppi-Pool-35", state: "Booted" },
      ],
      { "worker-live": { status: "busy", ageMinutes: 0 } },
    );
    seedUncertain(sim.lockDir, 2, 60);
    seedUncertain(sim.lockDir, 34, 60, { owner: "worker-stopped", profile: "duo" });
    seedUncertain(sim.lockDir, 35, 60, { owner: "worker-live", profile: "duo" });

    const reaped = sim.pool(["reap"], { OPPI_SIM_POOL_IDLE_MINUTES: "30", OPPI_SIM_POOL_KEEP_WARM: "0" });
    expectOk(reaped);
    expect(sim.shutdowns().sort()).toEqual(["Oppi-Pool-2", "Oppi-Pool-34"]);
    expect(slotStatus(sim.lockDir, 2)).toBe("reusable");
    expect(slotStatus(sim.lockDir, 34)).toBe("reusable");
    expect(sim.state("Oppi-Pool-35")).toBe("Booted");

    const released = sim.pool(["release", "--owner", "worker-live"]);
    expectOk(released);
    expect(sim.state("Oppi-Pool-35")).toBe("Shutdown");
    expect(slotStatus(sim.lockDir, 35)).toBe("reusable");
  }, CLI_TIMEOUT);
});

describe("sim-pool booted ceiling", () => {
  test("a run shuts down least recently used idle pool simulators before booting, never unmanaged ones", () => {
    const sim = fakeSimulators([
      { name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE },
      { name: "Oppi-Pool-3", state: "Booted", type: IPHONE },
      { name: "Oppi-Pool-4", state: "Booted", type: IPHONE },
      { name: "Chen iPhone", state: "Booted", type: IPHONE },
    ]);
    seedSlot(sim.lockDir, 3, 10);
    seedSlot(sim.lockDir, 4, 50);
    mkdirSync(join(sim.root, "clients", "apple", "Oppi.xcodeproj"), { recursive: true });
    writeFileSync(join(sim.root, "clients", "apple", "Oppi.xcodeproj", "project.pbxproj"), "// fixture\n");

    const result = sim.pool(["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "build"], {
      OPPI_ROOT: sim.root,
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_DEVICE_TYPE: IPHONE,
      OPPI_SIM_POOL_MAX_BOOTED: "1",
      OPPI_SIM_POOL_IDLE_MINUTES: "0",
    });
    expectOk(result);
    expect(sim.shutdowns().filter((name) => name !== "Oppi-Pool-0")).toEqual(["Oppi-Pool-4", "Oppi-Pool-3"]);
    expect(sim.state("Chen iPhone")).toBe("Booted");
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
    expect(result.stderr).toContain("booting anyway");
  }, CLI_TIMEOUT);
});
