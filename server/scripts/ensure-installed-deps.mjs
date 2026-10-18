#!/usr/bin/env node
// Make server/node_modules match server/package-lock.json, installing at first need.
// Fresh worktrees have no node_modules, and a worktree rebased onto a newer main
// keeps an old install whose type errors point at the code instead of the install.
//
//   node scripts/ensure-installed-deps.mjs           verify; run `npm ci` when out of sync
//   node scripts/ensure-installed-deps.mjs --check   verify only, never install
//
// Sync is judged by comparing package-lock.json with npm's hidden lockfile
// (node_modules/.package-lock.json), which covers transitive drift too.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const serverRoot = realpathSync(join(dirname(fileURLToPath(import.meta.url)), ".."));
const nodeModules = join(serverRoot, "node_modules");
const hiddenLockPath = join(nodeModules, ".package-lock.json");
const checkOnly = process.argv.includes("--check");

const LOCK_STALE_MS = 15 * 60 * 1000;

function readPackages(path) {
  return JSON.parse(readFileSync(path, "utf8")).packages ?? {};
}

function isSymlink(path) {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

/** Returns human-readable reasons node_modules is out of sync; empty when in sync. */
function findMismatches() {
  // A symlinked node_modules (old agent workaround) points at someone else's
  // install; `npm ci` would delete that install through the link.
  if (isSymlink(nodeModules)) return ["server/node_modules is a symlink"];
  if (!existsSync(hiddenLockPath)) return ["no dependencies installed in server/"];

  const lock = readPackages(join(serverRoot, "package-lock.json"));
  const installed = readPackages(hiddenLockPath);
  const mismatches = [];

  for (const [key, locked] of Object.entries(lock)) {
    if (key === "") continue;
    const actual = installed[key];
    if (!actual) {
      if (!locked.optional) mismatches.push(`${key}: not installed, lock ${locked.version}`);
      continue;
    }
    if (actual.version !== locked.version) {
      mismatches.push(`${key}: installed ${actual.version}, lock ${locked.version}`);
    } else if (actual.integrity && locked.integrity && actual.integrity !== locked.integrity) {
      mismatches.push(`${key}: installed integrity differs from lock (${locked.version})`);
    }
  }
  for (const key of Object.keys(installed)) {
    if (!(key in lock)) mismatches.push(`${key}: installed but not in lock`);
  }
  return mismatches;
}

function report(mismatches) {
  const shown = mismatches.slice(0, 10);
  for (const line of shown) console.error(`  ${line}`);
  if (mismatches.length > shown.length) {
    console.error(`  ... and ${mismatches.length - shown.length} more`);
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function lockIsStale(lockDir) {
  try {
    const pid = Number.parseInt(readFileSync(join(lockDir, "pid"), "utf8"), 10);
    if (Number.isInteger(pid)) return !pidAlive(pid);
  } catch {
    // No readable pid file: fall through to the age check.
  }
  try {
    // The owner died between mkdir and writing its pid, or is about to write it.
    return Date.now() - lstatSync(lockDir).mtimeMs > LOCK_STALE_MS;
  } catch {
    return false; // lock vanished
  }
}

/** Exclusive per-worktree lock outside the repo tree, so nothing shows in `git status`. */
async function acquireLock() {
  const key = createHash("sha256").update(serverRoot).digest("hex").slice(0, 16);
  const lockDir = join(tmpdir(), `oppi-server-deps-${key}.lock`);
  const pidFile = join(lockDir, "pid");
  let announced = false;
  for (;;) {
    try {
      mkdirSync(lockDir);
      writeFileSync(pidFile, String(process.pid));
      return () => {
        // Remove the lock only if it is still ours.
        try {
          if (readFileSync(pidFile, "utf8") === String(process.pid)) {
            rmSync(lockDir, { recursive: true, force: true });
          }
        } catch {
          // already gone
        }
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    if (lockIsStale(lockDir)) {
      // Rename first so only one waiter wins the takeover and a lock a faster
      // waiter just created at the shared path is never removed.
      const stale = `${lockDir}.stale-${process.pid}-${Date.now()}`;
      try {
        renameSync(lockDir, stale);
      } catch {
        continue; // someone else took it over
      }
      rmSync(stale, { recursive: true, force: true });
      continue;
    }
    if (!announced) {
      let holder = "unknown pid";
      try {
        holder = `pid ${readFileSync(pidFile, "utf8").trim()}`;
      } catch {
        // owner has not written its pid yet
      }
      console.error(
        `Another process (${holder}) is installing server dependencies; waiting for it. Remove ${lockDir} if no install is running.`,
      );
      announced = true;
    }
    await sleep(500);
  }
}

function install(reason) {
  console.error(`Installing server dependencies (${reason}): npm ci in server/`);
  if (isSymlink(nodeModules)) unlinkSync(nodeModules); // the link only, never its target
  const result = spawnSync("npm", ["ci", "--prefer-offline", "--no-audit", "--no-fund"], {
    cwd: serverRoot,
    stdio: ["ignore", 2, 2],
  });
  if (result.error) console.error(`Could not run npm: ${result.error.message}`);
}

const initial = findMismatches();
if (initial.length === 0) process.exit(0);

if (checkOnly) {
  console.error("Installed dependencies do not match server/package-lock.json:");
  report(initial);
  console.error(
    "Run `node scripts/ensure-installed-deps.mjs` in server/ (or `npm test` / `npm run check`) and retry.",
  );
  process.exit(1);
}

const release = await acquireLock();
try {
  // Another process may have finished the install while we waited for the lock.
  const current = findMismatches();
  if (current.length > 0) {
    install(current[0]);
    const remaining = findMismatches();
    if (remaining.length > 0) {
      console.error(
        "Dependencies are still out of sync with server/package-lock.json after npm ci:",
      );
      report(remaining);
      process.exitCode = 1;
    }
  }
} finally {
  release();
}
