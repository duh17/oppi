import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { releaseReusable, tryAcquireSlot } from "./sim-pool-lock";

const cli = join(import.meta.dir, "sim-pool.ts");
const temps: string[] = [];

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-sim-prune-${label}-`));
  temps.push(dir);
  return dir;
}

function initCheckout(root: string): string {
  spawnSync("git", ["init", "-q", root]);
  const build = join(root, "clients", "apple", ".build");
  mkdirSync(build, { recursive: true });
  return build;
}

function prune(root: string, lockDir: string, args: string[]): ReturnType<typeof spawnSync> {
  const env: NodeJS.ProcessEnv = { ...process.env, OPPI_SIM_POOL_LOCK_DIR: lockDir };
  delete env.OPPI_ROOT;
  delete env.PIOS_ROOT;
  return spawnSync("bun", [cli, "prune-cache", ...args], {
    cwd: root,
    env,
    encoding: "utf8",
  });
}

afterEach(() => {
  for (const dir of temps.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("sim-pool prune-cache", () => {
  test("dry-run does not delete", () => {
    const root = tempDir("dry");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0", "DerivedData"), { recursive: true });
    mkdirSync(join(build, "logs"), { recursive: true });
    writeFileSync(join(build, "pool-0", "DerivedData", "x"), "cache");
    writeFileSync(join(build, "logs", "summary.json"), "keep");
    const result = prune(root, lockDir, []);
    expect(result.status).toBe(0);
    expect(existsSync(join(build, "pool-0", "DerivedData", "x"))).toBe(true);
    expect(existsSync(join(build, "logs", "summary.json"))).toBe(true);
  });

  test("apply deletes leased pool dirs and skips non-pool kinds without a lease", () => {
    const root = tempDir("apply");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0"), { recursive: true });
    mkdirSync(join(build, "pool-12"), { recursive: true });
    mkdirSync(join(build, "derived-data-foo"), { recursive: true });
    mkdirSync(join(build, "mac-vocab-optin"), { recursive: true });
    mkdirSync(join(build, "logs"), { recursive: true });
    mkdirSync(join(build, "mac-tests"), { recursive: true });
    writeFileSync(join(build, "pool-0", "x"), "0");
    writeFileSync(join(build, "pool-12", "x"), "12");
    writeFileSync(join(build, "derived-data-foo", "x"), "d");
    writeFileSync(join(build, "mac-vocab-optin", "x"), "m");
    writeFileSync(join(build, "logs", "summary.json"), "keep");
    writeFileSync(join(build, "mac-tests", "x"), "keep");
    const result = prune(root, lockDir, ["--apply"]);
    expect(result.status).toBe(0);
    expect(existsSync(join(build, "pool-0"))).toBe(false);
    expect(existsSync(join(build, "pool-12"))).toBe(false);
    expect(existsSync(join(build, "derived-data-foo", "x"))).toBe(true);
    expect(existsSync(join(build, "mac-vocab-optin", "x"))).toBe(true);
    expect(existsSync(join(build, "logs", "summary.json"))).toBe(true);
    expect(existsSync(join(build, "mac-tests", "x"))).toBe(true);
    expect(result.stderr).toContain("no exclusive lease");
  });

  test("keep-slots retains in-range pool caches", () => {
    const root = tempDir("keep");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0"), { recursive: true });
    mkdirSync(join(build, "pool-11"), { recursive: true });
    writeFileSync(join(build, "pool-0", "x"), "keep");
    writeFileSync(join(build, "pool-11", "x"), "gone");
    const result = prune(root, lockDir, ["--apply", "--keep-slots", "0-5"]);
    expect(result.status).toBe(0);
    expect(existsSync(join(build, "pool-0", "x"))).toBe(true);
    expect(existsSync(join(build, "pool-11"))).toBe(false);
  });

  test("live in-flight lock skips pool delete", () => {
    const root = tempDir("live");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0"), { recursive: true });
    mkdirSync(join(build, "pool-1"), { recursive: true });
    writeFileSync(join(build, "pool-0", "x"), "live");
    writeFileSync(join(build, "pool-1", "x"), "idle");
    const held = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
    expect(held.ok).toBe(true);
    const result = prune(root, lockDir, ["--apply"]);
    expect(result.status).toBe(0);
    expect(existsSync(join(build, "pool-0", "x"))).toBe(true);
    expect(existsSync(join(build, "pool-1"))).toBe(false);
  });

  test("legacy directory is skipped not reaped", () => {
    const root = tempDir("legacy");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0"), { recursive: true });
    writeFileSync(join(build, "pool-0", "x"), "a");
    mkdirSync(join(lockDir, "slot-0"), { recursive: true });
    writeFileSync(join(lockDir, "slot-0", "pid"), "1\n");
    const result = prune(root, lockDir, ["--apply"]);
    expect(existsSync(join(build, "pool-0", "x"))).toBe(true);
    expect(existsSync(join(lockDir, "slot-0", "pid"))).toBe(true);
    expect(result.stderr).toContain("legacy");
  });

  test("sibling worktree is not deleted", () => {
    const parent = tempDir("sib");
    const a = join(parent, "tree-a");
    const b = join(parent, "tree-b");
    mkdirSync(a, { recursive: true });
    mkdirSync(b, { recursive: true });
    const buildA = initCheckout(a);
    const buildB = initCheckout(b);
    mkdirSync(join(buildA, "pool-0"), { recursive: true });
    mkdirSync(join(buildB, "pool-0"), { recursive: true });
    writeFileSync(join(buildA, "pool-0", "x"), "a");
    writeFileSync(join(buildB, "pool-0", "x"), "b");
    prune(a, join(parent, "locks"), ["--apply"]);
    expect(existsSync(join(buildA, "pool-0"))).toBe(false);
    expect(existsSync(join(buildB, "pool-0", "x"))).toBe(true);
  });

  test("conflicting OPPI_ROOT is refused", () => {
    const root = tempDir("oppi-root");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    mkdirSync(join(build, "pool-0"), { recursive: true });
    writeFileSync(join(build, "pool-0", "x"), "cache");
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      OPPI_ROOT: "/tmp/oppi-prune-cache-other",
      OPPI_SIM_POOL_LOCK_DIR: lockDir,
    };
    delete env.PIOS_ROOT;
    const result = spawnSync("bun", [cli, "prune-cache", "--apply"], {
      cwd: root,
      env,
      encoding: "utf8",
    });
    expect(result.status).not.toBe(0);
    expect(existsSync(join(build, "pool-0", "x"))).toBe(true);
  });

  test("failed delete does not permanently quarantine the slot", () => {
    const root = tempDir("fail-del");
    const lockDir = join(root, "locks");
    const build = initCheckout(root);
    const pool = join(build, "pool-0");
    mkdirSync(pool, { recursive: true });
    writeFileSync(join(pool, "x"), "cache");
    chmodSync(pool, 0o555);
    try {
      const result = prune(root, lockDir, ["--apply"]);
      expect(result.status).not.toBe(0);
      expect(existsSync(join(pool, "x"))).toBe(true);
      const reuse = tryAcquireSlot({ lockDir, slot: 0, argv: ["run"] });
      expect(reuse.ok).toBe(true);
      if (reuse.ok) {
        releaseReusable(reuse.owned);
      }
    } finally {
      chmodSync(pool, 0o755);
    }
  });

  test("symlinked cleanup root is refused", () => {
    const root = tempDir("symlink");
    spawnSync("git", ["init", "-q", root]);
    mkdirSync(join(root, "clients", "apple"), { recursive: true });
    const real = join(root, "real-build");
    mkdirSync(join(real, "pool-0"), { recursive: true });
    writeFileSync(join(real, "pool-0", "x"), "cache");
    symlinkSync(real, join(root, "clients", "apple", ".build"));
    const result = prune(root, join(root, "locks"), ["--apply"]);
    expect(result.status).not.toBe(0);
    expect(existsSync(join(real, "pool-0", "x"))).toBe(true);
  });
});
