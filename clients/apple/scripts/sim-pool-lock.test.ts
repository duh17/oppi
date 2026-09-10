import { afterEach, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  beginPublishing,
  closeOwned,
  recordOwnedPgid,
  flockFd,
  LOCK_EX,
  LOCK_NB,
  lockPath,
  readSlotState,
  releaseReusable,
  releaseUncertain,
  statePath,
  tryAcquireSlot,
} from "./sim-pool-lock";

const fixture = join(import.meta.dir, "sim-pool-lock.fixture.ts");
const temps: string[] = [];

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-sim-pool-${label}-`));
  temps.push(dir);
  return dir;
}

function waitForFile(path: string, timeoutMs = 3000): Promise<string> {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (existsSync(path)) {
        resolve(readFileSync(path, "utf8"));
        return;
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

function spawnFixture(args: string[]): ReturnType<typeof spawn> {
  return spawn("bun", [fixture, ...args], {
    stdio: ["ignore", "pipe", "pipe"],
  });
}

afterEach(() => {
  for (const dir of temps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("sim-pool-lock", () => {
  test("two processes cannot both own a slot", async () => {
    const lockDir = tempDir("two");
    const ready = join(lockDir, "ready");
    const holder = spawnFixture(["hold", lockDir, "0", ready]);
    await waitForFile(ready);
    const second = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(second.ok).toBe(false);
    if (!second.ok) {
      expect(second.reason).toContain("busy");
    }
    expect(existsSync(lockPath(lockDir, 0))).toBe(true);
    holder.kill("SIGKILL");
    await new Promise((resolve) => holder.once("exit", resolve));
  });

  test("loser does not delete the lock inode", async () => {
    const lockDir = tempDir("inode");
    const ready = join(lockDir, "ready");
    const holder = spawnFixture(["hold", lockDir, "1", ready]);
    await waitForFile(ready);
    const inoBefore = statSync(lockPath(lockDir, 1)).ino;
    const second = tryAcquireSlot({ lockDir, slot: 1, argv: ["run"] });
    expect(second.ok).toBe(false);
    expect(existsSync(lockPath(lockDir, 1))).toBe(true);
    expect(statSync(lockPath(lockDir, 1)).ino).toBe(inoBefore);
    holder.kill("SIGKILL");
    await new Promise((resolve) => holder.once("exit", resolve));
  });

  test("failed acquire after creating the inode leaves the inode", () => {
    const lockDir = tempDir("create");
    mkdirSync(lockDir, { recursive: true });
    const path = lockPath(lockDir, 2);
    writeFileSync(path, "");
    const fd = openSync(path, "r+");
    expect(flockFd(fd, LOCK_EX | LOCK_NB)).toBe(0);
    const second = tryAcquireSlot({ lockDir, slot: 2, argv: ["run"] });
    expect(second.ok).toBe(false);
    expect(existsSync(path)).toBe(true);
    closeSync(fd);
  });

  test("legacy mkdir directory is skipped and not reaped", () => {
    const lockDir = tempDir("legacy");
    mkdirSync(join(lockDir, "slot-3"), { recursive: true });
    writeFileSync(join(lockDir, "slot-3", "pid"), "1\n");
    const result = tryAcquireSlot({ lockDir, slot: 3, argv: ["run"] });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.reason).toContain("legacy");
    }
    expect(existsSync(join(lockDir, "slot-3", "pid"))).toBe(true);
  });

  test("gated empty ledger is reclaimed after flock is free", () => {
    const lockDir = tempDir("inflight");
    const first = tryAcquireSlot({ lockDir, slot: 4, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    closeOwned(first.owned);
    const again = tryAcquireSlot({ lockDir, slot: 4, argv: ["run"] });
    expect(again.ok).toBe(true);
    if (again.ok) {
      releaseReusable(again.owned);
    }
  });

  test("flock-v1 in-flight empty ledger stays fail-closed", () => {
    const lockDir = tempDir("v1-empty");
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(lockPath(lockDir, 4), "");
    writeFileSync(
      statePath(lockDir, 4),
      `${JSON.stringify({
        format: "flock-v1",
        status: "in-flight",
        pid: 1,
        nonce: "legacy",
        argv: ["run"],
        started_at: new Date().toISOString(),
        pgids: [],
      }, null, 2)}\n`,
    );
    const again = tryAcquireSlot({ lockDir, slot: 4, argv: ["run"] });
    expect(again.ok).toBe(false);
    if (!again.ok) {
      expect(again.reason).toContain("in-flight");
    }
  });

  test("gated publishing in-flight is not reclaimed", () => {
    const lockDir = tempDir("publishing");
    const first = tryAcquireSlot({ lockDir, slot: 4, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    beginPublishing(first.owned);
    closeOwned(first.owned);
    const again = tryAcquireSlot({ lockDir, slot: 4, argv: ["run"] });
    expect(again.ok).toBe(false);
    if (!again.ok) {
      expect(again.reason).toContain("in-flight");
    }
  });

  test("reusable release allows the next owner to mutate", () => {
    const lockDir = tempDir("reuse");
    const first = tryAcquireSlot({ lockDir, slot: 5, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    releaseReusable(first.owned);
    const again = tryAcquireSlot({ lockDir, slot: 5, argv: ["run"] });
    expect(again.ok).toBe(true);
    if (again.ok) {
      releaseReusable(again.owned);
    }
  });

  test("uncertain release with a live recorded group stays fail-closed", () => {
    const lockDir = tempDir("uncertain");
    const first = tryAcquireSlot({ lockDir, slot: 6, argv: ["shutdown-idle"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    const child = spawn("sleep", ["30"], { stdio: "ignore", detached: true });
    const pgid = child.pid;
    expect(pgid).toBeGreaterThan(0);
    if (pgid == null) {
      throw new Error("expected child pid");
    }
    child.unref();
    try {
      recordOwnedPgid(first.owned, pgid);
      releaseUncertain(first.owned, "descendants still running");
      const again = tryAcquireSlot({ lockDir, slot: 6, argv: ["run"] });
      expect(again.ok).toBe(false);
      if (!again.ok) {
        expect(again.reason).toContain("uncertain");
      }
    } finally {
      try {
        process.kill(-pgid, "SIGKILL");
      } catch {
        try {
          process.kill(pgid, "SIGKILL");
        } catch {
          // already gone
        }
      }
    }
  });

  test("killed wrapper with surviving child does not authorize reuse", async () => {
    const lockDir = tempDir("survive");
    const ready = join(lockDir, "ready");
    const childFile = join(lockDir, "child-pid");
    const holder = spawnFixture(["hold-with-child", lockDir, "7", ready, childFile]);
    await waitForFile(ready);
    const childPid = Number((await waitForFile(childFile)).trim());
    expect(childPid).toBeGreaterThan(0);
    holder.kill("SIGKILL");
    await new Promise((resolve) => holder.once("exit", resolve));
    expect(process.kill(childPid, 0)).toBe(true);
    const second = tryAcquireSlot({ lockDir, slot: 7, argv: ["run"] });
    expect(second.ok).toBe(false);
    if (!second.ok) {
      expect(second.reason).toContain("in-flight");
    }
    process.kill(childPid, "SIGKILL");
  });

  test("release is idempotent and does not clobber a later owner", () => {
    const lockDir = tempDir("idempotent");
    const first = tryAcquireSlot({ lockDir, slot: 9, argv: ["run"] });
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    releaseReusable(first.owned);
    const second = tryAcquireSlot({ lockDir, slot: 9, argv: ["run"] });
    if (!second.ok) {
      throw new Error("expected second acquire");
    }
    releaseUncertain(first.owned, "stale release");
    const state = readSlotState(lockDir, 9);
    expect(state === "unreadable" ? undefined : state?.status).toBe("in-flight");
    expect(state === "unreadable" ? undefined : state?.nonce).toBe(second.owned.nonce);
    releaseReusable(second.owned);
  });

  test("uncertain with idle recorded groups is claimed by the next owner", () => {
    const lockDir = tempDir("auto-idle");
    const first = tryAcquireSlot({ lockDir, slot: 10, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    recordOwnedPgid(first.owned, 1_000_000_001);
    releaseUncertain(first.owned, "unproven cleanup");
    const again = tryAcquireSlot({ lockDir, slot: 10, argv: ["run"] });
    expect(again.ok).toBe(true);
    if (again.ok) {
      releaseReusable(again.owned);
    }
  });

  test("in-flight with idle recorded groups is claimed by the next owner", () => {
    const lockDir = tempDir("inflight-idle");
    const first = tryAcquireSlot({ lockDir, slot: 12, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    recordOwnedPgid(first.owned, 1_000_000_001);
    closeOwned(first.owned);
    const again = tryAcquireSlot({ lockDir, slot: 12, argv: ["run"] });
    expect(again.ok).toBe(true);
    if (again.ok) {
      releaseReusable(again.owned);
    }
  });

  test("in-flight with a live recorded group stays fail-closed", () => {
    const lockDir = tempDir("auto-live");
    const first = tryAcquireSlot({ lockDir, slot: 11, argv: ["run"] });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    const child = spawn("sleep", ["30"], { stdio: "ignore", detached: true });
    const pgid = child.pid;
    expect(pgid).toBeGreaterThan(0);
    if (pgid == null) {
      throw new Error("expected child pid");
    }
    child.unref();
    try {
      recordOwnedPgid(first.owned, pgid);
      closeOwned(first.owned);
      const again = tryAcquireSlot({ lockDir, slot: 11, argv: ["run"] });
      expect(again.ok).toBe(false);
      if (!again.ok) {
        expect(again.reason).toContain("in-flight");
      }
    } finally {
      try {
        process.kill(-pgid, "SIGKILL");
      } catch {
        try {
          process.kill(pgid, "SIGKILL");
        } catch {
          // already gone
        }
      }
    }
  });

  test("flock-v1 in-flight with idle recorded groups stays fail-closed", () => {
    const lockDir = tempDir("v1-idle");
    mkdirSync(lockDir, { recursive: true });
    writeFileSync(lockPath(lockDir, 13), "");
    writeFileSync(
      statePath(lockDir, 13),
      `${JSON.stringify({
        format: "flock-v1",
        status: "in-flight",
        pid: 1,
        nonce: "legacy",
        argv: ["run"],
        started_at: new Date().toISOString(),
        pgids: [1_000_000_001],
      }, null, 2)}\n`,
    );
    const again = tryAcquireSlot({ lockDir, slot: 13, argv: ["run"] });
    expect(again.ok).toBe(false);
    if (!again.ok) {
      expect(again.reason).toContain("in-flight");
    }
  });

  test("status sidecar is not deleted on skip", () => {
    const lockDir = tempDir("status");
    const first = tryAcquireSlot({ lockDir, slot: 8, argv: ["run"] });
    if (!first.ok) {
      throw new Error("expected acquire");
    }
    beginPublishing(first.owned);
    closeOwned(first.owned);
    tryAcquireSlot({ lockDir, slot: 8, argv: ["run"] });
    expect(existsSync(statePath(lockDir, 8))).toBe(true);
    expect(existsSync(lockPath(lockDir, 8))).toBe(true);
  });
});
