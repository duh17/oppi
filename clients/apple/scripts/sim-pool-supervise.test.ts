import { afterEach, describe, expect, test } from "bun:test";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CommandSession,
  completeOwned,
  processGroupPids,
  queryProcessGroup,
  combineStop,
  spawnGateWaiting,
  spawnOwned,
  stopOwned,
  waitExitStatus,
  waitOwned,
} from "./sim-pool-supervise";

const temps: string[] = [];

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-sim-sup-${label}-`));
  temps.push(dir);
  return dir;
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
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

afterEach(() => {
  for (const dir of temps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("sim-pool-supervise", () => {
  test("empty process group stays quiescent if stdout did not close", () => {
    const stop = combineStop({ quiescent: true }, false);
    expect(stop.quiescent).toBe(true);
  });

  test("nonempty process group stays unproven", () => {
    const stop = combineStop({ quiescent: false, note: "pids remain" }, true);
    expect(stop.quiescent).toBe(false);
    expect(stop.note).toContain("pids remain");
  });

  test("gate does not exec the payload before authorize", async () => {
    const dir = tempDir("gate-block");
    const marker = join(dir, "ran");
    const spawned = await spawnGateWaiting("/bin/bash", ["-c", `printf ran > "${marker}"`]);
    expect(spawned.ok).toBe(true);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    await Bun.sleep(150);
    expect(existsSync(marker)).toBe(false);
    const stop = await spawned.gated.abort();
    expect(stop.quiescent).toBe(true);
    expect(existsSync(marker)).toBe(false);
  });

  test("gate execs the payload after authorize", async () => {
    const dir = tempDir("gate-go");
    const marker = join(dir, "ran");
    const spawned = await spawnGateWaiting("/bin/bash", ["-c", `printf ran > "${marker}"`]);
    expect(spawned.ok).toBe(true);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    spawned.gated.authorize();
    await waitForFile(marker);
    expect(readFileSync(marker, "utf8")).toContain("ran");
    await stopOwned(spawned.gated.owned);
  });

  test("publication failure aborts the gate without exec", async () => {
    const dir = tempDir("gate-pubfail");
    const marker = join(dir, "ran");
    const session = new CommandSession();
    session.onSpawned = () => {
      throw new Error("persist failed");
    };
    const result = await session.spawn("/bin/bash", ["-c", `printf ran > "${marker}"`]);
    expect(result.ok).toBe(false);
    await Bun.sleep(150);
    expect(existsSync(marker)).toBe(false);
    await session.dispose();
  });

  test("second gated spawn after an idle first group still requires authorize", async () => {
    const dir = tempDir("gate-second");
    const firstMark = join(dir, "first");
    const secondMark = join(dir, "second");
    const first = await spawnGateWaiting("/bin/bash", ["-c", `printf first > "${firstMark}"`]);
    if (!first.ok) {
      throw new Error(first.reason);
    }
    first.gated.authorize();
    await waitForFile(firstMark);
    await stopOwned(first.gated.owned);
    const second = await spawnGateWaiting("/bin/bash", ["-c", `printf second > "${secondMark}"`]);
    if (!second.ok) {
      throw new Error(second.reason);
    }
    await Bun.sleep(150);
    expect(existsSync(secondMark)).toBe(false);
    second.gated.authorize();
    await waitForFile(secondMark);
    await stopOwned(second.gated.owned);
  });

  test("detached spawn uses its own process group", async () => {
    const spawned = await spawnOwned("sleep", ["30"]);
    expect(spawned.ok).toBe(true);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    expect(spawned.owned.pgid).toBe(spawned.owned.pid);
    const stop = await stopOwned(spawned.owned);
    expect(stop.quiescent).toBe(true);
  });

  test("normal completion returns the child exit code", async () => {
    const spawned = await spawnOwned("bash", ["-lc", "exit 0"]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const waited = await waitOwned(spawned.owned);
    expect(waited.code).toBe(0);
    const group = queryProcessGroup(spawned.owned.pgid);
    expect(group.ok).toBe(true);
    if (group.ok) {
      expect(group.pids).toEqual([]);
    }
  });

  test("nonzero child exit is reported", async () => {
    const spawned = await spawnOwned("bash", ["-lc", "exit 7"]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const waited = await waitOwned(spawned.owned);
    expect(waited.code).toBe(7);
  });

  test("spawn failure does not invent an owned process group", async () => {
    const spawned = await spawnOwned("/no/such/oppi-sim-pool-owned-bin", []);
    expect(spawned.ok).toBe(false);
    if (!spawned.ok) {
      expect(spawned.reason).toMatch(/spawn|ENOENT|not found/i);
    }
  });

  test("waitOwned returns after an externally signaled child already exited", async () => {
    const spawned = await spawnOwned("/bin/sleep", ["30"], { stdio: "ignore" });
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const exit = once(spawned.owned.child, "exit");
    process.kill(spawned.owned.pid, "SIGTERM");
    await exit;
    expect(spawned.owned.child.exitCode).toBeNull();
    expect(spawned.owned.child.signalCode).toBe("SIGTERM");
    const waited = await waitOwned(spawned.owned, { timeoutMs: 1000 });
    expect(waited.signal).toBe("SIGTERM");
    expect(waitExitStatus(waited)).toBe(143);
  });

  test("pgrep status other than 0/1 is not an empty group", async () => {
    const dir = tempDir("pgrep");
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    try {
      const query = queryProcessGroup(1);
      expect(query.ok).toBe(false);
      if (!query.ok) {
        expect(query.reason).toContain("status 2");
      }
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
    }
  });

  test("killing the leader leaves a descendant until the group is signaled", async () => {
    const dir = tempDir("desc");
    const started = join(dir, "started");
    const descFile = join(dir, "desc");
    const script = join(dir, "leader.sh");
    writeFileSync(
      script,
      `#!/usr/bin/env bash
set -euo pipefail
sleep 60 &
echo $! > "${descFile}"
echo started > "${started}"
wait || true
`,
      { mode: 0o755 },
    );
    const spawned = await spawnOwned("bash", [script]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    await waitForFile(started);
    const descPid = Number((await waitForFile(descFile)).trim());
    process.kill(spawned.owned.pid, "SIGKILL");
    await spawned.owned.exit;
    const afterLeader = queryProcessGroup(spawned.owned.pgid);
    expect(afterLeader.ok).toBe(true);
    if (afterLeader.ok) {
      expect(afterLeader.pids).toContain(descPid);
    }
    const stop = await stopOwned(spawned.owned);
    expect(stop.quiescent).toBe(true);
    const afterStop = queryProcessGroup(spawned.owned.pgid);
    expect(afterStop.ok).toBe(true);
    if (afterStop.ok) {
      expect(afterStop.pids).toEqual([]);
    }
  });

  test("stopOwned does not report quiescent while the group still has members", async () => {
    const spawned = await spawnOwned("sleep", ["60"]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const before = queryProcessGroup(spawned.owned.pgid);
    expect(before.ok).toBe(true);
    if (before.ok) {
      expect(before.pids.length).toBeGreaterThan(0);
    }
    const stop = await stopOwned(spawned.owned, { termMs: 2000, killMs: 2000 });
    expect(stop.quiescent).toBe(true);
  });

  test("waitOwned does not fabricate stream close while a descendant inherits stdout", async () => {
    const dir = tempDir("inherit");
    const descFile = join(dir, "desc");
    const started = join(dir, "started");
    const script = join(dir, "leader.sh");
    writeFileSync(
      script,
      `#!/usr/bin/env bash
set -euo pipefail
(trap "" HUP TERM; exec /bin/sleep 30) &
echo $! > "${descFile}"
echo started > "${started}"
wait || true
`,
      { mode: 0o755 },
    );
    const spawned = await spawnOwned("bash", [script]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    await waitForFile(started);
    const descPid = Number((await waitForFile(descFile)).trim());
    process.kill(spawned.owned.pid, "SIGKILL");
    await spawned.owned.exit;
    let timedOut = false;
    try {
      await waitOwned(spawned.owned, { timeoutMs: 400 });
    } catch {
      timedOut = true;
    }
    expect(timedOut).toBe(true);
    expect(() => process.kill(descPid, 0)).not.toThrow();
    const completed = await completeOwned(spawned.owned);
    expect(completed.stop.quiescent).toBe(true);
    const after = queryProcessGroup(spawned.owned.pgid);
    expect(after.ok).toBe(true);
    if (after.ok) {
      expect(after.pids).toEqual([]);
    }
  });

  test("processGroupPids throws when the group query is uncertain", () => {
    const dir = tempDir("pgrep-throw");
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    try {
      expect(() => processGroupPids(1)).toThrow(/status 2/);
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
    }
  });

  test("completeOwned treats a failed group query as not quiescent", async () => {
    const dir = tempDir("complete-pgrep");
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const spawned = await spawnOwned("/bin/sleep", ["30"], { stdio: "ignore" });
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    try {
      const completed = await completeOwned(spawned.owned, { timeoutMs: 200, termMs: 50, killMs: 50 });
      expect(completed.stop.quiescent).toBe(false);
      if (completed.stop.note) {
        expect(completed.stop.note).toContain("status 2");
      }
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
      await stopOwned(spawned.owned);
    }
  });

  test("canceled session does not spawn and does not signal a retired pgid", async () => {
    const session = new CommandSession();
    session.cancel("TERM");
    const denied = await session.spawn("/bin/sleep", ["30"]);
    expect(denied.ok).toBe(false);
    if (!denied.ok) {
      expect(denied.reason).toMatch(/canceled before spawn/);
    }
    const live = new CommandSession();
    const first = await live.spawn("bash", ["-lc", "exit 0"]);
    if (!first.ok) {
      throw new Error(first.reason);
    }
    await live.complete(first.owned);
    const victim = await spawnOwned("/bin/sleep", ["30"], { stdio: "ignore" });
    if (!victim.ok) {
      throw new Error(victim.reason);
    }
    first.owned.pgid = victim.owned.pgid;
    const stopped = await live.stopAll();
    expect(stopped.quiescent).toBe(true);
    expect(() => process.kill(victim.owned.pid, 0)).not.toThrow();
    const reaped = await stopOwned(victim.owned);
    expect(reaped.quiescent).toBe(true);
  });

  test("concurrent complete and stopAll keep a failed observer result", async () => {
    const dir = tempDir("join-race");
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    const session = new CommandSession();
    try {
      const spawned = await session.spawn("/bin/sleep", ["30"], { stdio: "ignore" });
      if (!spawned.ok) {
        throw new Error(spawned.reason);
      }
      const pid = spawned.owned.pid;
      const [completed, stopped] = await Promise.all([
        session.complete(spawned.owned, { timeoutMs: 400, termMs: 80, killMs: 80 }),
        session.stopAll({ firstSignal: "SIGTERM" }),
      ]);
      expect(completed.stop.quiescent).toBe(false);
      expect(stopped.quiescent).toBe(false);
      const again = await session.stopAll();
      expect(again.quiescent).toBe(false);
      const disposed = await session.dispose();
      expect(disposed.quiescent).toBe(false);
      if (alive(pid)) {
        expect(completed.stop.quiescent).toBe(false);
        expect(stopped.quiescent).toBe(false);
      }
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
      await session.dispose();
    }
  });

  test("cancel during complete keeps failed cleanup on later stopAll", async () => {
    const dir = tempDir("cancel-join");
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    const session = new CommandSession();
    try {
      const spawned = await session.spawn("/bin/sleep", ["30"], { stdio: "ignore" });
      if (!spawned.ok) {
        throw new Error(spawned.reason);
      }
      const completing = session.complete(spawned.owned, {
        timeoutMs: 5000,
        termMs: 80,
        killMs: 80,
      });
      session.cancel("TERM");
      const completed = await completing;
      const stopped = await session.stopAll();
      const disposed = await session.dispose();
      expect(completed.stop.quiescent).toBe(false);
      expect(stopped.quiescent).toBe(false);
      expect(disposed.quiescent).toBe(false);
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
      await session.dispose();
    }
  });

  test("cancel racing spawn publication does not invent a clean stop", async () => {
    const dir = tempDir("pub-race");
    const started = join(dir, "started");
    const descFile = join(dir, "desc");
    const script = join(dir, "leader.sh");
    writeFileSync(
      script,
      `#!/usr/bin/env bash
set -euo pipefail
(trap "" TERM; echo $$ > "${descFile}"; exec /bin/sleep 30) &
echo started > "${started}"
wait || true
`,
      { mode: 0o755 },
    );
    const bin = join(dir, "pgrep");
    writeFileSync(bin, "#!/bin/sh\nexit 2\n", { mode: 0o755 });
    const previous = process.env.OPPI_SIM_POOL_PGREP;
    process.env.OPPI_SIM_POOL_PGREP = bin;
    const session = new CommandSession();
    try {
      const spawnPromise = session.spawn("bash", [script]);
      session.cancel("TERM");
      const spawned = await spawnPromise;
      let stop = { quiescent: true as boolean, note: spawned.ok ? undefined : spawned.reason };
      if (spawned.ok) {
        stop = (await session.complete(spawned.owned, { stopFirst: true, termMs: 80, killMs: 80 })).stop;
      } else if ("stop" in spawned && spawned.stop) {
        stop = spawned.stop;
      }
      const disposed = await session.dispose();
      let descPid = 0;
      if (existsSync(descFile)) {
        descPid = Number(readFileSync(descFile, "utf8").trim());
      }
      if (spawned.ok || descPid > 0) {
        expect(stop.quiescent).toBe(false);
        expect(disposed.quiescent).toBe(false);
      } else {
        expect(spawned.ok).toBe(false);
      }
      if (descPid > 0 && alive(descPid)) {
        expect(stop.quiescent).toBe(false);
        expect(disposed.quiescent).toBe(false);
      }
    } finally {
      if (previous == null) {
        delete process.env.OPPI_SIM_POOL_PGREP;
      } else {
        process.env.OPPI_SIM_POOL_PGREP = previous;
      }
      await session.dispose();
      if (existsSync(descFile)) {
        const pid = Number(readFileSync(descFile, "utf8").trim());
        if (pid > 1) {
          try {
            process.kill(pid, "SIGKILL");
          } catch {
            // already gone
          }
        }
      }
    }
  });

  test("cancel wakes default complete of a TERM-resistant leader", async () => {
    const session = new CommandSession();
    const spawned = await session.spawn("/bin/bash", [
      "-c",
      'trap "" TERM; printf ready; while :; do /bin/sleep 1; done',
    ]);
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    const owned = spawned.owned;
    const readyDeadline = Date.now() + 2000;
    while (!owned.stdout.includes("ready") && Date.now() < readyDeadline) {
      await Bun.sleep(10);
    }
    expect(owned.stdout.includes("ready")).toBe(true);
    const completion = session.complete(owned);
    const started = Date.now();
    session.cancel("TERM");
    const result = await Promise.race([
      completion.then((value) => ({ settled: true as const, stop: value.stop, timedOut: value.timedOut })),
      Bun.sleep(4500).then(() => ({ settled: false as const })),
    ]);
    const elapsedMs = Date.now() - started;
    try {
      expect(result.settled).toBe(true);
      if (result.settled) {
        expect(elapsedMs).toBeLessThan(4500);
        const group = queryProcessGroup(owned.pgid);
        expect(group.ok).toBe(true);
        if (group.ok) {
          expect(group.pids).toEqual([]);
        }
      }
    } finally {
      try {
        process.kill(-owned.pgid, "SIGKILL");
      } catch {
        // already gone
      }
      await session.dispose();
    }
  }, 10000);

  test("operational timeout with proven cleanup stays timedOut and quiescent", async () => {
    const spawned = await spawnOwned("/bin/sleep", ["30"], { stdio: "ignore" });
    if (!spawned.ok) {
      throw new Error(spawned.reason);
    }
    try {
      const completed = await completeOwned(spawned.owned, {
        timeoutMs: 80,
        termMs: 200,
        killMs: 200,
        streamCloseMs: 200,
      });
      expect(completed.timedOut).toBe(true);
      expect(completed.stop.quiescent).toBe(true);
      const group = queryProcessGroup(spawned.owned.pgid);
      expect(group.ok).toBe(true);
      if (group.ok) {
        expect(group.pids).toEqual([]);
      }
    } finally {
      try {
        process.kill(-spawned.owned.pgid, "SIGKILL");
      } catch {
        // already gone
      }
    }
  });
});
