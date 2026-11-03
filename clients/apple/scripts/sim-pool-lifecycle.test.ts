import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireHeavySlot } from "./sim-pool-build";
import { claimVerdict, planIdleReap } from "./sim-pool-lifecycle";
import {
  readSlotState,
  releaseClaimed,
  releaseReusable,
  releaseUncertain,
  tryAcquireSlot,
  type SlotClaim,
} from "./sim-pool-lock";
import { runShard } from "./unit-shards";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";

// Every test runs the pool CLI against fake tools; see sim-pool-test-support.ts for the sizing.
setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

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
 * A stateful CoreSimulator stand-in (shell scripts, see sim-pool-lifecycle.fake-*.sh): create/boot/
 * shutdown change the device list that the next `simctl list` prints, and every call is logged.
 * The fake `oppi` answers its first call with each session's state and every
 * later call with `later` when given (a session that resumes mid-pass).
 */
function fakeSimulators(devices: FakeDevice[], sessions: Record<string, FakeSession> = {}) {
  const root = mkdtempSync(join(tmpdir(), "oppi-sim-life-"));
  temps.push(root);
  const bin = join(root, "bin");
  const lockDir = join(root, "locks");
  mkdirSync(bin, { recursive: true });
  // One tab-separated row per device: udid, name, state, device type, runtime.
  const rows = devices.map((d) => [`UDID-${d.name}`, d.name, d.state, d.type ?? DUO, IOS_27_1].join("\t"));
  writeFileSync(join(root, "devices.tsv"), rows.map((row) => `${row}\n`).join(""));
  // One row per session: id, status, idle minutes, then the status and idle minutes of later calls.
  const sessionRows = Object.entries(sessions).map(([id, session]) => {
    const later = session.later ?? session;
    return [id, session.status, session.ageMinutes, later.status, later.ageMinutes].join("\t");
  });
  writeFileSync(join(root, "sessions.tsv"), sessionRows.map((row) => `${row}\n`).join(""));
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
  for (const tool of ["xcrun", "oppi"]) {
    copyFileSync(join(import.meta.dir, `sim-pool-lifecycle.fake-${tool}.sh`), join(bin, tool));
    chmodSync(join(bin, tool), 0o755);
  }
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
    // Reaping stays off unless a test turns it on, so each test sees only its own command.
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
      return readFileSync(join(root, "devices.tsv"), "utf8")
        .split("\n")
        .map((row) => row.split("\t"))
        .find((columns) => columns[1] === name)?.[2];
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
    const udids = (slots: { udid: string }[]) => slots.map((slot) => slot.udid).sort();
    // A and D are the two most recent (and under the limit anyway).
    expect(udids(planIdleReap(idle, now, 30 * MINUTE, 2))).toEqual(["B", "C"]);
    // D (20m) is not past the limit, warm or not.
    expect(udids(planIdleReap(idle, now, 30 * MINUTE, 0))).toEqual(["B", "C"]);
    // Keep-warm protects the most recent even when they are past the limit.
    const stale = idle.filter((slot) => slot.udid === "B" || slot.udid === "C");
    expect(udids(planIdleReap(stale, now, 30 * MINUTE, 1))).toEqual(["C"]);
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
  });

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
  });

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
    // While the slot is held, release cannot free the claim and must not say there is none.
    const blocked = sim.pool(["release", "--owner", "worker-a"]);
    expect(blocked.status).not.toBe(0);
    expect(blocked.stderr).toContain("busy");
    await new Promise((resolve) => setTimeout(resolve, 1500));
    releaseClaimed(held.owned, { owner: "worker-a", profile: "duo" });
    expect({ status: await exited, stderr }).toMatchObject({ status: 0 });
    expect(stdout.trim()).toBe("UDID-Oppi-Pool-30");
    expect(readSlotState(sim.lockDir, 31)).toBeNull();
    expect(sim.state("Oppi-Pool-31")).toBeUndefined();
  });
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
        { name: "Alex iPhone", state: "Booted", type: IPHONE },
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
    expect(sim.state("Alex iPhone")).toBe("Booted");
    expect(slotStatus(sim.lockDir, 30)).toBe("reusable");
    expect(readSlotState(sim.lockDir, 32)).toMatchObject({ status: "claimed", claim: { owner: "lead-idle" } });
    expect(readSlotState(sim.lockDir, 33)).toMatchObject({ status: "claimed", claim: { owner: "lead-resumes" } });
  });

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
  });
});

function writeCheckout(root: string): void {
  mkdirSync(join(root, "clients", "apple", "Oppi.xcodeproj"), { recursive: true });
  writeFileSync(join(root, "clients", "apple", "Oppi.xcodeproj", "project.pbxproj"), "// fixture\n");
}

describe("sim-pool reap after a run", () => {
  test("a finished run shuts down idle pool simulators and keeps its own warm", () => {
    const sim = fakeSimulators([
      { name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE },
      { name: "Oppi-Pool-5", state: "Booted", type: IPHONE },
    ]);
    seedSlot(sim.lockDir, 5, 60);
    writeCheckout(sim.root);

    const result = sim.pool(["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"], {
      OPPI_ROOT: sim.root,
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_DEVICE_TYPE: IPHONE,
      OPPI_SIM_POOL_IDLE_MINUTES: "30",
      OPPI_SIM_POOL_KEEP_WARM: "1",
    });
    expectOk(result);
    // Pool-0's own shutdown is the clean boot before the build; it must end booted.
    expect(sim.shutdowns().filter((name) => name !== "Oppi-Pool-0")).toEqual(["Oppi-Pool-5"]);
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
    expect(slotStatus(sim.lockDir, 5)).toBe("reusable");
  });
});

describe("sim-pool booted ceiling", () => {
  test("a run shuts down least recently used idle pool simulators before booting, never unmanaged ones", () => {
    const sim = fakeSimulators([
      { name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE },
      { name: "Oppi-Pool-3", state: "Booted", type: IPHONE },
      { name: "Oppi-Pool-4", state: "Booted", type: IPHONE },
      { name: "Alex iPhone", state: "Booted", type: IPHONE },
    ]);
    seedSlot(sim.lockDir, 3, 10);
    seedSlot(sim.lockDir, 4, 50);
    writeCheckout(sim.root);

    const result = sim.pool(["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"], {
      OPPI_ROOT: sim.root,
      OPPI_SIM_POOL_COUNT: "1",
      OPPI_SIM_DEVICE_TYPE: IPHONE,
      OPPI_SIM_POOL_MAX_BOOTED: "1",
      OPPI_SIM_POOL_IDLE_MINUTES: "0",
    });
    // Both idle pool simulators went, least recently used first, and the user's own stayed: the ceiling
    // (1) is still full, so the run does not boot past it.
    expect(sim.shutdowns().filter((name) => name !== "Oppi-Pool-0")).toEqual(["Oppi-Pool-4", "Oppi-Pool-3"]);
    expect(sim.state("Alex iPhone")).toBe("Booted");
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("1 simulators booted (limit 1) and none is idle in the pool");
    expect(sim.state("Oppi-Pool-0")).toBe("Shutdown");
  });

  test("a run waits for capacity instead of booting past the ceiling, and boots once one frees up", async () => {
    const sim = fakeSimulators([
      { name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE },
      { name: "Alex iPhone", state: "Booted", type: IPHONE },
    ]);
    writeCheckout(sim.root);
    const child = spawn(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      {
        cwd: sim.root,
        env: {
          ...sim.env,
          OPPI_ROOT: sim.root,
          OPPI_SIM_POOL_COUNT: "1",
          OPPI_SIM_DEVICE_TYPE: IPHONE,
          OPPI_SIM_POOL_MAX_BOOTED: "1",
          OPPI_SIM_POOL_WAIT: "40",
        },
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
    let stderr = "";
    child.stderr!.on("data", (chunk) => {
      stderr += String(chunk);
    });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    const deadline = Date.now() + 30_000;
    while (!stderr.includes("waiting up to 40s for capacity") && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    // Still waiting: nothing was booted past the ceiling.
    expect(stderr).toContain("waiting up to 40s for capacity");
    expect(sim.state("Oppi-Pool-0")).toBe("Shutdown");
    spawnSync("xcrun", ["simctl", "shutdown", "UDID-Alex iPhone"], { env: sim.env });
    expect(await exited).toBe(0);
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
  });
});

describe("sim-pool first boot of a new simulator", () => {
  test("a new simulator's first boot waits for the machine-wide first-boot slot", async () => {
    const sim = fakeSimulators([]);
    writeCheckout(sim.root);
    const heavyEnv = { ...sim.env, OPPI_HEAVY_DIR: join(sim.root, "heavy"), OPPI_HEAVY_POLL: "0.2", OPPI_SIM_POOL_WAIT: "40" };
    const held = await acquireHeavySlot("sim-first-boot", heavyEnv, { canceled: false, waitWhileIdle: async () => {} }, () => {});
    expect(held?.lock).toBeDefined();
    const child = spawn(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      {
        cwd: sim.root,
        env: { ...heavyEnv, OPPI_ROOT: sim.root, OPPI_SIM_POOL_COUNT: "1", OPPI_SIM_DEVICE_TYPE: IPHONE },
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
    let stderr = "";
    child.stderr!.on("data", (chunk) => {
      stderr += String(chunk);
    });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    const deadline = Date.now() + 30_000;
    while (!stderr.includes("sim-first-boot slots busy") && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    expect(stderr).toContain("1 machine-wide sim-first-boot slots busy");
    // The device exists but is not booted while another run holds the first-boot slot.
    expect(sim.state("Oppi-Pool-0")).toBe("Shutdown");
    held!.lock!.release();
    expect(await exited).toBe(0);
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
  });

  test("a run gives up on the first-boot slot after OPPI_SIM_POOL_WAIT and never boots", async () => {
    const sim = fakeSimulators([]);
    writeCheckout(sim.root);
    const heavyEnv = { ...sim.env, OPPI_HEAVY_DIR: join(sim.root, "heavy"), OPPI_HEAVY_POLL: "0.2", OPPI_SIM_POOL_WAIT: "1" };
    const held = await acquireHeavySlot("sim-first-boot", heavyEnv, { canceled: false, waitWhileIdle: async () => {} }, () => {});
    try {
      const result = spawnSync(
        "bun",
        [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
        { cwd: sim.root, env: { ...heavyEnv, OPPI_ROOT: sim.root, OPPI_SIM_POOL_COUNT: "1", OPPI_SIM_DEVICE_TYPE: IPHONE }, encoding: "utf8" },
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("waiting for a machine-wide sim-first-boot slot");
      expect(sim.state("Oppi-Pool-0")).toBe("Shutdown");
    } finally {
      held!.lock!.release();
    }
  });

  test("the first-boot slot is not held while the run waits for booted-simulator capacity", async () => {
    const sim = fakeSimulators([{ name: "Alex iPhone", state: "Booted", type: IPHONE }]);
    writeCheckout(sim.root);
    const heavyEnv = { ...sim.env, OPPI_HEAVY_DIR: join(sim.root, "heavy"), OPPI_HEAVY_POLL: "0.2" };
    const child = spawn(
      "bun",
      [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
      {
        cwd: sim.root,
        env: { ...heavyEnv, OPPI_ROOT: sim.root, OPPI_SIM_POOL_COUNT: "1", OPPI_SIM_DEVICE_TYPE: IPHONE, OPPI_SIM_POOL_MAX_BOOTED: "1", OPPI_SIM_POOL_WAIT: "40" },
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
    let stderr = "";
    child.stderr!.on("data", (chunk) => {
      stderr += String(chunk);
    });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    const deadline = Date.now() + 30_000;
    while (!stderr.includes("waiting up to 40s for capacity") && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    expect(stderr).toContain("waiting up to 40s for capacity");
    // Another run's first boot can take the slot at once: the waiting run does not hold it.
    const free = await acquireHeavySlot("sim-first-boot", { ...heavyEnv, OPPI_HEAVY_POLL: "0.1" }, { canceled: false, waitWhileIdle: async () => {} }, () => {}, 0);
    expect(free?.lock).toBeDefined();
    free!.lock!.release();
    spawnSync("xcrun", ["simctl", "shutdown", "UDID-Alex iPhone"], { env: sim.env });
    expect(await exited).toBe(0);
    expect(sim.state("Oppi-Pool-0")).toBe("Booted");
  });

  test("a simulator that already exists boots without the first-boot slot", async () => {
    const sim = fakeSimulators([{ name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE }]);
    writeCheckout(sim.root);
    const heavyEnv = { ...sim.env, OPPI_HEAVY_DIR: join(sim.root, "heavy"), OPPI_HEAVY_POLL: "0.2" };
    const held = await acquireHeavySlot("sim-first-boot", heavyEnv, { canceled: false, waitWhileIdle: async () => {} }, () => {});
    try {
      const result = spawnSync(
        "bun",
        [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test-without-building"],
        { cwd: sim.root, env: { ...heavyEnv, OPPI_ROOT: sim.root, OPPI_SIM_POOL_COUNT: "1", OPPI_SIM_DEVICE_TYPE: IPHONE }, encoding: "utf8" },
      );
      expectOk(result);
      expect(sim.state("Oppi-Pool-0")).toBe("Booted");
    } finally {
      held!.lock!.release();
    }
  });
});

describe("sim-pool slot wait", () => {
  // A one-slot pool whose only slot another run holds. `env` replaces the suite's OPPI_SIM_POOL_WAIT=0
  // (undefined removes a variable). `shard` runs the unit-shards shard command instead of the CLI directly.
  function busyPool(env: NodeJS.ProcessEnv, shard = false) {
    const sim = fakeSimulators([{ name: "Oppi-Pool-0", state: "Shutdown", type: IPHONE }]);
    writeCheckout(sim.root);
    const held = tryAcquireSlot({ lockDir: sim.lockDir, slot: 0, argv: ["run"] });
    expect(held.ok).toBe(true);
    if (!held.ok) throw new Error("could not hold the slot");
    const runEnv: NodeJS.ProcessEnv = { ...sim.env, OPPI_ROOT: sim.root, OPPI_SIM_POOL_COUNT: "1", OPPI_SIM_DEVICE_TYPE: IPHONE, ...env };
    for (const [name, value] of Object.entries(env)) {
      if (value === undefined) delete runEnv[name];
    }
    let stderr = "";
    let exited: Promise<number | null>;
    let output = () => stderr;
    if (shard) {
      const xctestrun = join(sim.root, "OppiUnitTests.xctestrun");
      writeFileSync(xctestrun, "");
      const done = runShard(0, xctestrun, ["-only-testing:OppiTests"], sim.root, "shard-1", runEnv);
      exited = done.then((result) => result.code);
      output = () => (existsSync(join(sim.root, "shard-1.out")) ? readFileSync(join(sim.root, "shard-1.out"), "utf8") : "");
    } else {
      const child = spawn("bun", [cli, "run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test-without-building"], {
        cwd: sim.root,
        env: runEnv,
        stdio: ["ignore", "ignore", "pipe"],
      });
      child.stderr!.on("data", (chunk) => {
        stderr += String(chunk);
      });
      exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    }
    return {
      sim,
      output,
      exited,
      release: () => releaseReusable(held.owned),
      async announced(text: string) {
        const deadline = Date.now() + 30_000;
        while (!output().includes(text) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 100));
        return output().includes(text);
      },
    };
  }

  test("a gate unit shard with every slot busy waits for the gate wait, then runs when a slot frees", async () => {
    const pool = busyPool({ OPPI_SIM_POOL_GATE: "1", OPPI_SIM_POOL_WAIT: undefined }, true);
    expect(await pool.announced("busy, waiting up to 1800s")).toBe(true);
    // Still waiting: nothing booted while the slot is held.
    expect(pool.sim.state("Oppi-Pool-0")).toBe("Shutdown");
    pool.release();
    expect(await pool.exited).toBe(0);
    expect(pool.sim.state("Oppi-Pool-0")).toBe("Booted");
  });

  test("a gate run that never gets a slot fails at its deadline and says so", async () => {
    const pool = busyPool({ OPPI_SIM_POOL_GATE: "1", OPPI_SIM_POOL_WAIT: "4" });
    expect(await pool.announced("busy, waiting up to 4s")).toBe(true);
    expect(await pool.exited).not.toBe(0);
    pool.release();
    expect(pool.output()).toContain("error: all 1 simulator slots (slots 0) are busy or quarantined (waited 4s)");
    expect(pool.sim.state("Oppi-Pool-0")).toBe("Shutdown");
  });

  test("a developer's own run keeps the 60 s default", async () => {
    const pool = busyPool({ OPPI_SIM_POOL_GATE: undefined, OPPI_SIM_POOL_WAIT: undefined });
    expect(await pool.announced("busy, waiting up to 60s")).toBe(true);
    pool.release();
    expect(await pool.exited).toBe(0);
  });
});
