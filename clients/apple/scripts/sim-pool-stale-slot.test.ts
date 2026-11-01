import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deadRunSurvivors, ownerGone, readSlotState, statePath, tryAcquireSlot, closeOwned, type ProcessInfo, type SlotState } from "./sim-pool-lock";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";

setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

/**
 * Slot 0's state as the pool left it from 2026-10-29 to 11-01: an E2E run's lease, `in-flight`, whose
 * owner (pid 16551) died. Its first pgid, 19599, was later handed to a simulator's NPKCompanionAgent,
 * and a `simctl io recordVideo` of the run was still alive, so every reap said "skipping slot 0".
 */
const FIXTURE = join(import.meta.dir, "sim-pool-lock.stale-slot-20261029.json");
const fixtureText = readFileSync(FIXTURE, "utf8");
const temps: string[] = [];
const spawned: number[] = [];
afterEach(() => {
  for (const pid of spawned.splice(0)) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // Gone.
    }
  }
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fixtureState(lockDir: string): SlotState {
  writeFileSync(statePath(lockDir, 0), fixtureText);
  const state = readSlotState(lockDir, 0);
  if (!state || state === "unreadable") throw new Error("fixture unreadable");
  return state;
}

const at = (iso: string) => Date.parse(iso);

describe("a dead run's slot", () => {
  test("from the 10-29 state: the reused pgid is unrelated, the run's leftover recordVideo is its orphan, and the owner is gone", () => {
    const lockDir = mkdtempSync(join(tmpdir(), "stale-slot-"));
    temps.push(lockDir);
    const state = fixtureState(lockDir);
    // The last pgid was recorded a minute into the run.
    const writtenAt = at("2026-10-29T05:39:06Z");
    const processes: ProcessInfo[] = [
      { pid: 19599, ppid: 18911, pgid: 19599, startedMs: at("2026-11-01T14:10:37Z"), command: "/Library/Developer/CoreSimulator/.../NPKCompanionAgent" },
      // The leader of group 19624 died with the run; its recordVideo child kept the group.
      { pid: 19631, ppid: 1, pgid: 19624, startedMs: at("2026-10-29T05:38:40Z"), command: "xcrun simctl io 5C0F recordVideo --codec=h264 /tmp/run.mov" },
      // Its child is the run's too.
      { pid: 19633, ppid: 19631, pgid: 19624, startedMs: at("2026-10-29T05:38:41Z"), command: "xcrun simctl io 5C0F recordVideo (helper)" },
      { pid: 16551, ppid: 1, pgid: 16551, startedMs: at("2026-11-01T09:00:00Z"), command: "/usr/libexec/some-later-daemon" },
      // Group 19634 was reused before the lease's last write by another live run's recorder (its parent is that run's pool).
      { pid: 19634, ppid: 30000, pgid: 19634, startedMs: at("2026-10-29T05:39:00Z"), command: "xcrun simctl io 9AB1 recordVideo /tmp/other-run.mov" },
      // In a recorded group but older than the lease: not the run's.
      { pid: 19650, ppid: 1, pgid: 19645, startedMs: at("2026-10-28T00:00:00Z"), command: "/usr/libexec/old-daemon" },
    ];
    const survivors = deadRunSurvivors(state, writtenAt, processes);
    expect(survivors.unrelated.map((proc) => proc.pid).sort()).toEqual([19599, 19634, 19650]);
    expect(survivors.orphans.map((proc) => proc.pid)).toEqual([19631, 19633]);
    // Pid 16551 belongs to a process that started after the lease: the owner's pid was reused too.
    expect(ownerGone(state, processes)).toBe(true);
    expect(ownerGone(state, [{ pid: 16551, ppid: 1, pgid: 16551, startedMs: at("2026-10-29T05:38:00Z"), command: "bun sim-pool.ts run" }])).toBe(false);
  });
});

/** The fixture's lease with the given pgids and a dead owner, its file dated `writtenAtMs`. */
function writeLease(lockDir: string, pgids: number[], owner: number, writtenAtMs = Date.now()): void {
  const state = { ...JSON.parse(fixtureText), pid: owner, pgids, publishedCount: pgids.length, started_at: new Date(Date.now() - 3_600_000).toISOString() };
  writeFileSync(statePath(lockDir, 0), JSON.stringify(state));
  utimesSync(statePath(lockDir, 0), writtenAtMs / 1000, writtenAtMs / 1000);
}

/** A pid that has exited. */
function deadPid(): number {
  const run = Bun.spawnSync(["/bin/sh", "-c", "echo $$"]);
  return Number(run.stdout.toString().trim());
}

/** A process named `name` in a group whose leader exited, reparented to launchd, as a dead run's orphan is; returns [pid, pgid]. */
function orphan(name: string): [number, number] {
  const run = Bun.spawnSync(["/usr/bin/perl", "-e", `use POSIX; setpgid(0,0); my $p = fork(); if ($p == 0) { open(STDOUT, ">/dev/null"); open(STDERR, ">/dev/null"); exec { "/bin/sleep" } "${name}", "30"; } print "$p ", getpgrp(), "\\n";`]);
  const [pid, pgid] = run.stdout.toString().trim().split(" ").map(Number);
  spawned.push(pid);
  return [pid, pgid];
}

const isAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

describe("taking over a dead run's slot", () => {
  test("a pgid reused by a process that started after the lease does not keep the slot", () => {
    const lockDir = mkdtempSync(join(tmpdir(), "stale-slot-"));
    temps.push(lockDir);
    const unrelated = Bun.spawn(["/usr/bin/perl", "-e", "use POSIX; setpgid(0,0); sleep 30"], { stdout: "ignore", stderr: "ignore" });
    spawned.push(unrelated.pid);
    Bun.sleepSync(200);
    // The lease was last written an hour ago; the group leader with its pgid started just now.
    writeLease(lockDir, [unrelated.pid], deadPid(), Date.now() - 3_600_000);
    const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(acquired.ok).toBe(true);
    if (acquired.ok) closeOwned(acquired.owned);
    expect(isAlive(unrelated.pid)).toBe(true);
  });

  test("a dead run's orphaned simctl io is reaped and the slot is taken", () => {
    const lockDir = mkdtempSync(join(tmpdir(), "stale-slot-"));
    temps.push(lockDir);
    const [pid, pgid] = orphan("simctl io booted recordVideo /tmp/run.mov");
    writeLease(lockDir, [pgid], deadPid());
    const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(acquired.ok).toBe(true);
    if (acquired.ok) closeOwned(acquired.owned);
    expect(isAlive(pid)).toBe(false);
  });

  test("a live run's simctl io recordVideo whose pgid a stale lease recorded is not killed", () => {
    const lockDir = mkdtempSync(join(tmpdir(), "stale-slot-"));
    temps.push(lockDir);
    // Its own group leader, a child of a live process (this test, standing in for the live run's pool).
    const recorder = Bun.spawn(["/usr/bin/perl", "-e", 'use POSIX; setpgid(0,0); exec { "/bin/sleep" } "xcrun simctl io booted recordVideo /tmp/live.mov", "30";'], { stdout: "ignore", stderr: "ignore" });
    spawned.push(recorder.pid);
    Bun.sleepSync(200);
    // The stale lease recorded the same pgid and was last written after the recorder started.
    writeLease(lockDir, [recorder.pid], deadPid());
    const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(acquired.ok).toBe(true);
    if (acquired.ok) closeOwned(acquired.owned);
    expect(isAlive(recorder.pid)).toBe(true);
  });

  test("any other orphan of a dead run (an xcodebuild may still drive the simulator) keeps the slot, and the reason names it", () => {
    const lockDir = mkdtempSync(join(tmpdir(), "stale-slot-"));
    temps.push(lockDir);
    const [pid, pgid] = orphan("xcodebuild test-without-building");
    const owner = deadPid();
    writeLease(lockDir, [pgid], owner);
    const acquired = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(acquired.ok).toBe(false);
    if (!acquired.ok) expect(acquired.reason).toContain(`owner pid ${owner} is gone but its run left pid ${pid} (xcodebuild test-without-building`);
    expect(isAlive(pid)).toBe(true);
  });
});
