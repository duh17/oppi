import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const heavy = join(import.meta.dir, "heavy.sh");
// heavy.sh is built on BSD lockf(1), which ships with macOS.
const hasLockf = existsSync("/usr/bin/lockf");

let dir: string;
const children: Array<Subprocess<"ignore" | "pipe", "pipe", "pipe">> = [];
const parents: Array<Subprocess> = [];

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "oppi-heavy-test-"));
});

afterEach(async () => {
  // Releasing every holder lets queued jobs run and every heavy.sh/lockf process exit.
  // Only then is the directory removed, so no process races the cleanup.
  writeFileSync(join(dir, "release"), "");
  for (const parent of parents.splice(0)) parent.kill();
  await Promise.all(children.splice(0).map((child) => child.exited));
  rmSync(dir, { recursive: true, force: true });
});

function env(extra: Record<string, string> = {}): Record<string, string> {
  const base: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith("OPPI_HEAVY")) base[key] = value;
  }
  return { ...base, OPPI_HEAVY_DIR: join(dir, "slots"), OPPI_HEAVY_POLL: "0.05", ...extra };
}

function run(args: string[], extra: Record<string, string> = {}) {
  const proc = Bun.spawn(["bash", heavy, ...args], { env: env(extra), stdout: "pipe", stderr: "pipe" });
  children.push(proc);
  return proc;
}

async function waitFor(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(20);
  }
}

// A command that records that it started, then blocks until `release` exists.
function holder(name: string, cls = "xcode-build", extra: Record<string, string> = {}) {
  const script = 'echo started > "$0.started"; while [ ! -e "$1" ]; do sleep 0.02; done';
  return run([cls, "--", "bash", "-c", script, join(dir, name), join(dir, "release")], extra);
}

describe.skipIf(!hasLockf)("heavy.sh", () => {
  test.each([0, 1, 3, 75])("passes through exit status %d and runs the command once", async (code) => {
    const counter = join(dir, "runs");
    const proc = run(["server-full", "--", "bash", "-c", `echo run >> "${counter}"; exit ${code}`]);
    expect(await proc.exited).toBe(code);
    expect(readFileSync(counter, "utf8")).toBe("run\n");
  });

  test("rejects an unknown class and a bad slot count", async () => {
    expect(await run(["bogus", "--", "true"]).exited).toBe(2);
    expect(await run(["xcode-build", "--", "true"], { OPPI_HEAVY_XCODE_BUILD: "0" }).exited).toBe(2);
  });

  test("makes the third job wait while two slots are busy, then runs it when one frees", async () => {
    const a = holder("a");
    const b = holder("b");
    await waitFor(() => existsSync(join(dir, "a.started")) && existsSync(join(dir, "b.started")), "two holders");

    const third = run(["xcode-build", "--", "bash", "-c", `echo ran > "${join(dir, "third")}"`]);
    const stderr = new Response(third.stderr).text();
    await Bun.sleep(300);
    expect(existsSync(join(dir, "third"))).toBe(false);
    expect(third.exitCode).toBeNull();

    writeFileSync(join(dir, "release"), "");
    expect(await third.exited).toBe(0);
    expect(existsSync(join(dir, "third"))).toBe(true);
    expect(await stderr).toContain("all 2 'xcode-build' slots busy; waiting");
    expect(await a.exited).toBe(0);
    expect(await b.exited).toBe(0);
  });

  test("a busy slot does not make a command exiting 75 look queued", async () => {
    const a = holder("a", "server-full");
    await waitFor(() => existsSync(join(dir, "a.started")), "holder");
    // Second server-full job blocks; once released it must report its own status 75.
    const second = run(["server-full", "--", "bash", "-c", "exit 75"]);
    await Bun.sleep(200);
    expect(second.exitCode).toBeNull();
    writeFileSync(join(dir, "release"), "");
    expect(await second.exited).toBe(75);
    expect(await a.exited).toBe(0);
  });

  test("a queued job gives up with 143 once its parent process is gone", async () => {
    const parent = Bun.spawn(["sleep", "600"]);
    parents.push(parent);
    const alive = { OPPI_HEAVY_PARENT_PID: String(parent.pid) };

    // A live parent does not get in the way of a free slot.
    expect(await run(["server-full", "--", "true"], alive).exited).toBe(0);

    const a = holder("a", "server-full");
    await waitFor(() => existsSync(join(dir, "a.started")), "holder");
    const waiter = run(["server-full", "--", "bash", "-c", `echo ran > "${join(dir, "ran")}"`], alive);
    const stderr = new Response(waiter.stderr).text();
    await Bun.sleep(200);
    expect(waiter.exitCode).toBeNull();

    parent.kill();
    expect(await waiter.exited).toBe(143);
    expect(existsSync(join(dir, "ran"))).toBe(false);
    expect(await stderr).toContain("caller is gone");

    writeFileSync(join(dir, "release"), "");
    expect(await a.exited).toBe(0);
  });

  test("classes are independent", async () => {
    const a = holder("a", "server-full");
    await waitFor(() => existsSync(join(dir, "a.started")), "holder");
    expect(await run(["xcode-build", "--", "true"]).exited).toBe(0);
    expect(await run(["ui-suite", "--", "true"]).exited).toBe(0);
    writeFileSync(join(dir, "release"), "");
    expect(await a.exited).toBe(0);
  });

  test("nested use of a held class runs directly instead of deadlocking", async () => {
    const proc = run(
      ["xcode-build", "--", "bash", heavy, "xcode-build", "--", "bash", heavy, "xcode-build", "--", "echo", "inner"],
      { OPPI_HEAVY_XCODE_BUILD: "1" },
    );
    expect(await proc.exited).toBe(0);
    expect((await new Response(proc.stdout).text()).trim()).toBe("inner");
  });

  test("nesting a different class still takes that class's slot", async () => {
    const a = holder("a", "server-full");
    await waitFor(() => existsSync(join(dir, "a.started")), "holder");
    const outer = run(["xcode-build", "--", "bash", heavy, "server-full", "--", "true"]);
    await Bun.sleep(200);
    expect(outer.exitCode).toBeNull();
    writeFileSync(join(dir, "release"), "");
    expect(await outer.exited).toBe(0);
    expect(await a.exited).toBe(0);
  });
});
