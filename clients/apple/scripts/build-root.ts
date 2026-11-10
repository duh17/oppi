#!/usr/bin/env bun
// Optional fast, volatile home for a checkout's `clients/apple/.build`.
//
// OPPI_BUILD_ROOT names a directory (a RAM disk, say). While it exists, `.build` is a symlink to
// `<root>/<checkout name>-<hash of its path>`, so every checkout gets its own folder and concurrent
// builds never share one. Unset, or with the directory missing (volume not mounted), `.build` is the
// ordinary folder it always was. The shared compilation cache lives at `<root>/xcode-cache` then
// (sim-pool-build.ts `compilationCache`).
//
//   bun build-root.ts [<apple dir>]   link the checkout's .build; prints nothing, never fails
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const OWNER_FILE = ".checkout";

/** The build root, when it is set and mounted. */
export function buildRoot(env: NodeJS.ProcessEnv): string | undefined {
  const root = env.OPPI_BUILD_ROOT?.trim();
  if (!root || !existsSync(root)) return undefined;
  try {
    return realpathSync(root);
  } catch {
    return undefined;
  }
}

function folderFor(root: string, appleDir: string): string {
  const real = realpathSync(appleDir);
  const id = createHash("sha1").update(real).digest("hex").slice(0, 8);
  const name = basename(dirname(dirname(real))).replace(/[^\w.-]/g, "_");
  return join(root, `${name}-${id}`);
}

function lstatOrNull(path: string) {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

/** The folder `.build` links to when that folder's `.checkout` names this checkout; else undefined. */
function managedFolder(appleDir: string): string | undefined {
  try {
    const link = join(appleDir, ".build");
    if (!lstatSync(link).isSymbolicLink()) return undefined;
    const folder = realpathSync(link);
    return readFileSync(join(folder, OWNER_FILE), "utf8").trim() === realpathSync(appleDir) ? folder : undefined;
  } catch {
    return undefined;
  }
}

/** True when `.build` is the link this module made for this checkout, so cleanup tools may follow it. */
export function isManagedBuildLink(appleDir: string): boolean {
  return managedFolder(appleDir) !== undefined;
}

/** The root this checkout builds under: OPPI_BUILD_ROOT while mounted, else the root its managed link lives in. */
export function buildRootFor(appleDir: string, env: NodeJS.ProcessEnv): string | undefined {
  const folder = managedFolder(appleDir);
  return buildRoot(env) ?? (folder ? dirname(folder) : undefined);
}

/**
 * Drop folders of checkouts that no longer exist. A checkout's `.build` link may be gone while the checkout lives
 * (git clean), and a checkout on an unmounted volume is absent too: only a folder whose worktree directory's parent
 * is present (the volume is mounted) is judged.
 */
function reapOrphans(root: string): void {
  for (const name of readdirSync(root)) {
    try {
      const owner = join(root, name, OWNER_FILE);
      if (!existsSync(owner)) continue;
      const apple = readFileSync(owner, "utf8").trim();
      const worktree = dirname(dirname(apple));
      if (apple && !existsSync(apple) && existsSync(dirname(worktree))) rmSync(join(root, name), { recursive: true, force: true });
    } catch {
      // A folder that cannot be judged stays.
    }
  }
}

/** Something still has files open under `dir`: a running build must not lose its folder. */
function inUse(dir: string): boolean {
  const lsof = spawnSync("lsof", ["-t", "+D", dir], { encoding: "utf8", timeout: 60_000 });
  return lsof.status !== 1 || (lsof.stdout ?? "").trim() !== "";
}

const sleepMs = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/** Exclusive for the move of a real `.build` to the root; a second caller waits for the first to finish. */
function withMigrationLock<T>(link: string, body: () => T): T | undefined {
  const lock = `${link}.migrating`;
  for (let waited = 0; ; waited += 100) {
    try {
      mkdirSync(lock);
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") return undefined;
    }
    // The holder died mid-move (several minutes is far beyond a rename and a link): take over.
    if (waited >= 300_000) rmSync(lock, { recursive: true, force: true });
    sleepMs(100);
  }
  try {
    return body();
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

/**
 * Point `<appleDir>/.build` at its folder under OPPI_BUILD_ROOT, or leave it an ordinary folder.
 * Returns the folder when linked. Never throws: a failure leaves today's on-disk `.build`.
 */
export function ensureBuildLink(appleDir: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  try {
    const link = join(appleDir, ".build");
    const root = buildRoot(env);
    // A link into a volume that is gone (or was recreated empty) would fail every build: drop it.
    if (lstatOrNull(link)?.isSymbolicLink() && !existsSync(link)) unlinkSync(link);
    if (!root) return undefined;
    const target = folderFor(root, appleDir);
    const claim = () => {
      mkdirSync(target, { recursive: true });
      writeFileSync(join(target, OWNER_FILE), `${realpathSync(appleDir)}\n`);
      symlinkSync(target, link);
    };
    let current = lstatOrNull(link);
    if (current?.isSymbolicLink()) {
      if (readlinkSync(link) === target) return target;
      // Another checkout's folder (a moved worktree): relink. A link outside the root is someone's own.
      if (!readlinkSync(link).startsWith(`${root}/`)) return undefined;
      unlinkSync(link);
      current = null;
    }
    reapOrphans(root);
    if (!current) {
      claim();
      return target;
    }
    if (!current.isDirectory()) return undefined;
    // An existing real folder moves over once nothing uses it; its contents are a rebuildable cache. The rename
    // and the link follow each other at once, so concurrent callers find a link, never a missing `.build`.
    return withMigrationLock(link, () => {
      const now = lstatOrNull(link);
      if (now?.isSymbolicLink()) return readlinkSync(link) === target ? target : undefined;
      if (!now?.isDirectory() || inUse(link)) return undefined;
      const old = `${link}.old-${process.pid}`;
      renameSync(link, old);
      claim();
      rmSync(old, { recursive: true, force: true });
      return target;
    });
  } catch {
    return undefined;
  }
}

if (import.meta.main) {
  ensureBuildLink(resolve(process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "..")));
}
