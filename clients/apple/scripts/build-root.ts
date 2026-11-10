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
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
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

/** True when `.build` is the link this module made, so cleanup tools may follow it. */
export function isManagedBuildLink(appleDir: string, env: NodeJS.ProcessEnv): boolean {
  const root = buildRoot(env);
  if (!root) return false;
  try {
    const link = join(appleDir, ".build");
    return lstatSync(link).isSymbolicLink() && realpathSync(link).startsWith(`${root}/`);
  } catch {
    return false;
  }
}

/** Drop folders of checkouts that no longer exist; a checkout's `.build` link may be gone while the checkout lives (git clean). */
function reapOrphans(root: string): void {
  for (const name of readdirSync(root)) {
    const owner = join(root, name, OWNER_FILE);
    if (!existsSync(owner)) continue;
    const apple = readFileSync(owner, "utf8").trim();
    if (apple && !existsSync(apple)) rmSync(join(root, name), { recursive: true, force: true });
  }
}

/** Something still has files open under `dir`: a running build must not lose its folder. */
function inUse(dir: string): boolean {
  const lsof = spawnSync("lsof", ["-t", "+D", dir], { encoding: "utf8", timeout: 60_000 });
  return lsof.status !== 1 || (lsof.stdout ?? "").trim() !== "";
}

/**
 * Point `<appleDir>/.build` at its folder under OPPI_BUILD_ROOT, or leave it an ordinary folder.
 * Returns the folder when linked. Never throws: a failure leaves today's on-disk `.build`.
 */
export function ensureBuildLink(appleDir: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  try {
    const link = join(appleDir, ".build");
    const root = buildRoot(env);
    const stat = lstatOrNull(link);
    // A link into a volume that is gone (or was recreated empty) would fail every build: drop it.
    if (stat?.isSymbolicLink() && !existsSync(link)) unlinkSync(link);
    if (!root) return undefined;
    const target = folderFor(root, appleDir);
    const current = lstatOrNull(link);
    if (current?.isSymbolicLink()) return readlinkSync(link) === target ? target : undefined;
    reapOrphans(root);
    if (current) {
      // An existing real folder moves over once nothing uses it; its contents are a rebuildable cache.
      if (!current.isDirectory() || inUse(link)) return undefined;
      rmSync(link, { recursive: true, force: true });
    }
    mkdirSync(target, { recursive: true });
    writeFileSync(join(target, OWNER_FILE), `${realpathSync(appleDir)}\n`);
    symlinkSync(target, link);
    return target;
  } catch {
    return undefined;
  }
}

if (import.meta.main) {
  ensureBuildLink(resolve(process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "..")));
}
