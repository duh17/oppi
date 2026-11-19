#!/usr/bin/env bun
// Optional fast, volatile home for a checkout's `clients/apple/.build`.
//
// OPPI_BUILD_ROOT names a directory (a RAM disk, say). While it exists, `.build` is a symlink to
// `<root>/<checkout name>-<hash of its path>`, so every checkout gets its own folder and concurrent
// builds never share one. Unset, or with the directory missing (volume not mounted), a checkout
// without a link builds in the ordinary `.build` folder it always had. A checkout whose link points
// into the missing volume keeps the link: buildVolumeMissing names it, and builds stop there instead
// of silently going cold on disk. The shared compilation cache lives at `<root>/xcode-cache` then
// (sim-pool-build.ts `compilationCache`).
//
//   bun build-root.ts [<apple dir>]           link the checkout's .build; prints nothing, never fails
//   bun build-root.ts --check [<apple dir>]   link it, then print buildVolumeMissing's line and exit 1 if it
//                                             applies (for shell entry points that run xcodegen themselves)
import { createHash } from "node:crypto";
import { accessSync, constants, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const OWNER_FILE = ".checkout";

/**
 * A build root that can take builds: a writable directory. A RAM disk that jetsam detached leaves its
 * mount point behind as an empty, unwritable directory (`d--x--x--x`), which is not one.
 */
function usableRoot(root: string): boolean {
  try {
    accessSync(root, constants.W_OK | constants.X_OK);
    return statSync(root).isDirectory();
  } catch {
    return false;
  }
}

/** The build root, when it is set and mounted. */
export function buildRoot(env: NodeJS.ProcessEnv): string | undefined {
  const root = env.OPPI_BUILD_ROOT?.trim();
  if (!root || !usableRoot(root)) return undefined;
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
 * Why this checkout cannot build now, or undefined: OPPI_BUILD_ROOT is set, `.build` links into it, and
 * the volume is gone (not mounted, or an unwritable leftover mount point). A build there would fail
 * part way with ENOENT, or fall back to a cold build on disk without anyone asking for one.
 */
export function buildVolumeMissing(appleDir: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  const root = env.OPPI_BUILD_ROOT?.trim();
  const link = join(appleDir, ".build");
  if (!root || !lstatOrNull(link)?.isSymbolicLink() || existsSync(link) || usableRoot(root)) return undefined;
  return (
    `build volume missing: ${link} links to ${readlinkSync(link)}, but the build root ${root} (OPPI_BUILD_ROOT) is not mounted. ` +
    `Recreate the RAM disk (oppi-ramdisk.sh), then run again. Recreating the disk empties it under every build ` +
    `still running on it, so let those finish or stop first.`
  );
}

/** The folder `.build` resolves to and the device it lives on; undefined when it does not resolve. */
export type BuildVolume = { folder: string; dev: number };

export function buildVolumeOf(appleDir: string): BuildVolume | undefined {
  try {
    const folder = realpathSync(join(appleDir, ".build"));
    return { folder, dev: statSync(folder).dev };
  } catch {
    return undefined;
  }
}

/**
 * Why the build volume a running build started on is gone, or undefined: `.build` no longer resolves
 * (its volume was detached), it resolves to another device (the volume was recreated, empty), or one
 * of `paths` (the build's log, its DerivedData) vanished. Every build on that volume lost its output
 * at once; the failure is the machine's, not the change under test.
 */
export function buildVolumeLost(appleDir: string, start: BuildVolume, paths: string[]): string | undefined {
  const now = buildVolumeOf(appleDir);
  if (!now) return `build volume lost: ${start.folder} disappeared mid-build`;
  if (now.folder !== start.folder || now.dev !== start.dev) return `build volume lost: ${start.folder} was replaced mid-build (device ${start.dev}, now ${now.dev} at ${now.folder})`;
  const gone = paths.find((path) => !existsSync(path));
  return gone ? `build volume lost: ${gone} disappeared mid-build` : undefined;
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
    // A link into a volume that was recreated empty, or into a root no longer configured, is dropped and
    // made again. One into a configured volume that is gone stays, so buildVolumeMissing can say so.
    if (lstatOrNull(link)?.isSymbolicLink() && !existsSync(link)) {
      if (buildVolumeMissing(appleDir, env)) return undefined;
      unlinkSync(link);
    }
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
  const check = process.argv[2] === "--check";
  const appleDir = resolve(process.argv[check ? 3 : 2] ?? join(dirname(fileURLToPath(import.meta.url)), ".."));
  ensureBuildLink(appleDir);
  const missing = check ? buildVolumeMissing(appleDir) : undefined;
  if (missing) {
    console.error(missing);
    process.exit(1);
  }
}
