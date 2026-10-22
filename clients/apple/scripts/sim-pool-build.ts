// Build outside the simulator slot.
//
// A simulator slot is only needed to run tests. `sim-pool run` therefore builds
// first, with no slot, into one DerivedData per checkout (`.build/dd`) for a
// generic arm64 simulator, so every slot and every device profile (iPhone, iPad,
// Duo) reuses the same products. A `test` run then clones the products (APFS
// clonefile, instant) into a per-run directory and leases a slot only for
// `test-without-building -xctestrun <clone>`. The clone lets another agent in
// the same checkout rebuild while these tests still run.
//
// Locks, outermost first, all flock(2) held by this process so a crash frees them:
//   1. `.build/dd.lock`: exclusive while building (and cloning), shared while a
//      caller's own `test-without-building` reads `.build/dd` directly.
//   2. a machine-wide `xcode-build` slot from scripts/heavy.sh (same slot files,
//      same counting semaphore), only around the xcodebuild build itself.
//   3. the simulator slot, taken after 1 and 2 are released.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { flockFd, LOCK_EX, LOCK_NB, LOCK_SH, LOCK_UN } from "./sim-pool-lock";

/** How `sim-pool run` executes an xcodebuild command. */
export type RunPlan =
  /** No test action: build in `.build/dd` without a slot. */
  | { kind: "build"; buildArgv: string[] }
  /** `test`: build without a slot, then `test-without-building` on a clone in a slot. */
  | { kind: "split"; buildArgv: string[]; testFlags: string[]; scheme: string }
  /** The caller's own `test-without-building` (or an -xctestrun/-testPlan run): a slot, no build. */
  | { kind: "slot"; readsDerivedData: boolean };

const ACTIONS = new Set([
  "build", "build-for-testing", "analyze", "archive", "test", "test-without-building", "clean", "docbuild",
  "install", "installsrc",
]);

// Test-execution flags that belong to `test-without-building`, not the build, with their
// value count. `-only-testing`/`-skip-testing` also come as one `-flag:ID` token.
const TEST_FLAGS: Record<string, number> = {
  "-only-testing": 1,
  "-skip-testing": 1,
  "-resultBundlePath": 1,
  "-resultStreamPath": 1,
  "-test-iterations": 1,
  "-retry-tests-on-failure": 0,
  "-run-tests-until-failure": 0,
  "-test-repetition-relaunch-enabled": 1,
  "-test-timeouts-enabled": 1,
  "-default-test-execution-time-allowance": 1,
  "-maximum-test-execution-time-allowance": 1,
  "-parallel-testing-enabled": 1,
  "-parallel-testing-worker-count": 1,
  "-maximum-parallel-testing-workers": 1,
  "-maximum-concurrent-test-simulator-destinations": 1,
  "-collect-test-diagnostics": 1,
  "-testLanguage": 1,
  "-testRegion": 1,
  "-destination-timeout": 1,
};
// Flags both phases need: coverage is compiled in and collected at test time.
const SHARED_FLAGS: Record<string, number> = { "-enableCodeCoverage": 1 };

export function isXcodebuild(command: string): boolean {
  return basename(command) === "xcodebuild";
}

export function planRun(argv: string[]): RunPlan {
  const actions = argv.filter((arg) => ACTIONS.has(arg));
  // Runs whose test products the caller owns, or whose xctestrun depends on a test plan.
  if (argv.some((arg) => /^-(?:xctestrun|testProductsPath|testPlan|workspace)(?:=|$)/.test(arg))) {
    return { kind: "slot", readsDerivedData: false };
  }
  if (actions.includes("test-without-building")) {
    return { kind: "slot", readsDerivedData: true };
  }
  const buildArgv: string[] = [];
  const testFlags: string[] = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (/^-(?:only|skip)-testing:/.test(arg)) {
      testFlags.push(arg);
      continue;
    }
    if (arg in TEST_FLAGS) {
      const count = TEST_FLAGS[arg];
      testFlags.push(...argv.slice(i, i + 1 + count));
      i += count;
      continue;
    }
    if (arg in SHARED_FLAGS) {
      const count = SHARED_FLAGS[arg];
      buildArgv.push(...argv.slice(i, i + 1 + count));
      testFlags.push(...argv.slice(i, i + 1 + count));
      i += count;
      continue;
    }
    buildArgv.push(arg === "test" ? "build-for-testing" : arg);
  }
  if (!actions.includes("test")) {
    return { kind: "build", buildArgv: argv.slice() };
  }
  const scheme = flagValue("-scheme", argv);
  if (!scheme) {
    return { kind: "slot", readsDerivedData: true };
  }
  return { kind: "split", buildArgv, testFlags, scheme };
}

/**
 * A caller's `test-without-building -xctestrun <Scheme>_*.xctestrun` (unit shards) gets the
 * same early-completion parsing as the `-scheme <Scheme> test` it stands for. Only the
 * test filters carry over; a run with repetition or parallel flags stays unparsed.
 */
export function completionArgvForXctestrun(argv: string[]): string[] | undefined {
  const xctestrun = flagValue("-xctestrun", argv);
  const scheme = xctestrun ? /^([A-Za-z0-9]+)_[^/]*\.xctestrun$/.exec(basename(xctestrun))?.[1] : undefined;
  if (!scheme || !argv.includes("test-without-building")) return undefined;
  const filters = argv.filter((arg) => /^-(?:only|skip)-testing:/.test(arg));
  // Diagnostics collection changes nothing about what a finished summary means.
  const valued = new Set(["-xctestrun", "-collect-test-diagnostics"]);
  const others = argv.filter((arg, i) => !filters.includes(arg) && arg !== "test-without-building" && !valued.has(arg) && !valued.has(argv[i - 1]));
  if (others.length > 0) return undefined;
  return ["-scheme", scheme, "test", ...filters];
}

function flagValue(flag: string, args: string[]): string | undefined {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

export const SLOTLESS_BUILD_DESTINATION = "generic/platform=iOS Simulator";

/** A generic destination has no active arch; build arm64 only, like the slot builds it replaces. */
export function slotlessBuildSettings(argv: string[]): string[] {
  const settings: string[] = [];
  if (!argv.some((arg) => arg.startsWith("ARCHS="))) settings.push("ARCHS=arm64");
  if (!argv.some((arg) => arg.startsWith("ONLY_ACTIVE_ARCH="))) settings.push("ONLY_ACTIVE_ARCH=YES");
  return settings;
}

/**
 * Shared compilation cache for slotless builds. Only pool builds get it; project.yml and
 * Xcode.app builds keep real paths for debugging.
 *
 * - One content-addressed cache (CAS) per Xcode for every checkout, with prefix mapping so
 *   a compile keyed in one worktree hits in another. Measured: a fresh worktree at an
 *   already-built commit built in 51 s instead of 109 s (153 instead of 1,249 CPU-s). A
 *   change anywhere in the Oppi module recompiles that module in full; landing-gate builds
 *   of main's tip keep the common case warm.
 * - SwiftPM checkouts shared by Package.resolved hash, resolved once under an exclusive
 *   lock, read by builds under a shared lock with resolution and updates off.
 * Prefix mapping compiles #filePath to /^src/...; the architecture rule
 * ios-test-no-source-paths keeps tests from opening files through it.
 * OPPI_SIM_POOL_COMPILATION_CACHE=0 turns it off; OPPI_XCODE_CACHE_DIR moves it.
 */
export type CompilationCache = { root: string; args: string[]; settings: string[]; packages?: string };

export function compilationCache(
  env: NodeJS.ProcessEnv,
  appleDir: string,
  derivedData: string,
  argv: string[],
): CompilationCache | undefined {
  if (env.OPPI_SIM_POOL_COMPILATION_CACHE === "0") return undefined;
  // DEVELOPER_DIR is <Xcode>.app/Contents/Developer; a new Xcode gets a fresh cache.
  const xcode = basename(dirname(dirname(env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer"))).replace(/[^\w.-]/g, "_");
  const root = env.OPPI_XCODE_CACHE_DIR ?? join(env.HOME ?? homedir(), "Library", "Caches", "oppi-xcode", xcode);
  const settings = [
    "COMPILATION_CACHE_ENABLE_CACHING=YES",
    `COMPILATION_CACHE_CAS_PATH=${join(root, "cas")}`,
    "COMPILATION_CACHE_LIMIT_SIZE=40G",
    "SWIFT_ENABLE_PREFIX_MAPPING=YES",
    "CLANG_ENABLE_PREFIX_MAPPING=YES",
    "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES",
    "CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES",
    `MODULE_CACHE_DIR=${join(root, "modulecache")}`,
  ];
  // Map a path and its real path (/tmp is /private/tmp): the compiler sees either.
  const mapped = (path: string, to: string) => [...new Set([path, realpathOrSelf(path)])].map((p) => `${p}=${to}`);
  // The checkout is the compiler's working directory for package targets too; project
  // prefix mapping covers it only for this project's own targets.
  // (Its own token: /^src is each package's own source root.)
  const mappings = [...mapped(derivedData, "/^dd"), ...mapped(appleDir, "/^checkout")];
  const args: string[] = [];
  let packages: string | undefined;
  const resolved = join(appleDir, "Oppi.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved");
  if (existsSync(resolved) && !argv.includes("-clonedSourcePackagesDirPath")) {
    const hash = createHash("sha256").update(readFileSync(resolved)).digest("hex").slice(0, 16);
    packages = join(root, "spm", hash);
    args.push("-clonedSourcePackagesDirPath", packages, "-disableAutomaticPackageResolution", "-skipPackageUpdates");
    mappings.push(...mapped(packages, "/^spm"));
  }
  settings.push(`SWIFT_OTHER_PREFIX_MAPPINGS=${mappings.join(" ")}`, `CLANG_OTHER_PREFIX_MAPPINGS=${mappings.join(" ")}`);
  return { root, args, settings, packages };
}

function realpathOrSelf(path: string): string {
  try {
    return realpathSync.native(path);
  } catch {
    return path;
  }
}

/** Marker written once the shared package directory resolved. */
export function packagesResolvedMarker(packages: string): string {
  return join(packages, ".oppi-resolved");
}

export function markPackagesResolved(packages: string): void {
  writeFileSync(packagesResolvedMarker(packages), `${new Date().toISOString()}\n`);
}

export function checkoutDerivedData(buildBase: string): string {
  return join(buildBase, "dd");
}

/** A held flock; `release` is idempotent. */
export type HeldLock = { path: string; release: () => void };

type Waiter = { canceled: boolean; waitWhileIdle: (ms: number) => Promise<void> };

/**
 * Poll a non-blocking flock so a cancel (SIGINT/SIGTERM) still ends the wait. Returns
 * undefined when canceled. `onWait` runs once, the first time the lock is busy.
 */
export async function waitForFlock(
  path: string,
  mode: "exclusive" | "shared",
  session: Waiter,
  onWait?: () => void,
  pollMs = 1000,
): Promise<HeldLock | undefined> {
  mkdirSync(join(path, ".."), { recursive: true });
  const fd = openSync(path, "a");
  let announced = false;
  while (true) {
    if (flockFd(fd, (mode === "exclusive" ? LOCK_EX : LOCK_SH) | LOCK_NB) === 0) {
      let held = true;
      return {
        path,
        release: () => {
          if (!held) return;
          held = false;
          flockFd(fd, LOCK_UN);
          closeSync(fd);
        },
      };
    }
    if (session.canceled) {
      closeSync(fd);
      return undefined;
    }
    if (!announced) {
      announced = true;
      onWait?.();
    }
    await session.waitWhileIdle(pollMs);
  }
}

/**
 * Take one of scripts/heavy.sh's machine-wide `xcode-build` slots (same slot files and
 * env knobs), or nothing when an ancestor already holds that class (OPPI_HEAVY_HELD).
 * The child environment must carry `heldEnv` so a nested heavy.sh does not wait on us.
 */
export async function acquireHeavyBuildSlot(
  env: NodeJS.ProcessEnv,
  session: Waiter,
  log: (message: string) => void,
): Promise<{ lock?: HeldLock; heldEnv: string; waitedSeconds: number } | undefined> {
  const held = env.OPPI_HEAVY_HELD ?? "";
  const heldEnv = held.includes(":xcode-build:") ? held : `${held || ":"}xcode-build:`;
  if (held.includes(":xcode-build:")) {
    return { heldEnv, waitedSeconds: 0 };
  }
  const slots = Number(env.OPPI_HEAVY_XCODE_BUILD ?? "2");
  if (!Number.isInteger(slots) || slots < 1) {
    throw new Error(`invalid OPPI_HEAVY_XCODE_BUILD '${env.OPPI_HEAVY_XCODE_BUILD}'`);
  }
  const dir = env.OPPI_HEAVY_DIR ?? join(env.HOME ?? homedir(), "Library", "Caches", "oppi-heavy");
  mkdirSync(dir, { recursive: true });
  const pollMs = Math.max(100, Number(env.OPPI_HEAVY_POLL ?? "5") * 1000);
  const started = Date.now();
  let announced = false;
  while (true) {
    for (let slot = 0; slot < slots; slot += 1) {
      const path = join(dir, `xcode-build.${slot}`);
      const fd = openSync(path, "a");
      if (flockFd(fd, LOCK_EX | LOCK_NB) === 0) {
        let isHeld = true;
        const lock: HeldLock = {
          path,
          release: () => {
            if (!isHeld) return;
            isHeld = false;
            flockFd(fd, LOCK_UN);
            closeSync(fd);
          },
        };
        return { lock, heldEnv, waitedSeconds: Math.round((Date.now() - started) / 1000) };
      }
      closeSync(fd);
    }
    if (session.canceled) return undefined;
    if (!announced) {
      announced = true;
      log(`[sim-pool] all ${slots} machine-wide xcode-build slots busy (${dir}); waiting`);
    }
    // Like heavy.sh: a waiter whose caller is gone (a killed pre-push hook) does not build later.
    if (callerGone(env)) {
      log("[sim-pool] caller is gone; not starting the queued build");
      return undefined;
    }
    await session.waitWhileIdle(pollMs);
  }
}

function callerGone(env: NodeJS.ProcessEnv): boolean {
  const parent = Number(env.OPPI_HEAVY_PARENT_PID);
  if (parent > 0) return !processAlive(parent);
  return process.ppid === 1;
}

/**
 * The test phase's DerivedData: `Build/Products` is a clone of the checkout build, and
 * `Logs/Test` gets this run's xcresult. The summary's derived_data_path names it, so
 * callers that hash the tested binaries (qa-verify) read exactly what ran.
 */
export function runDirectory(buildBase: string, stamp: string): string {
  return join(buildBase, "runs", `${stamp}-${process.pid}`);
}

/** Clone `<dd>/Build/Products` into `<runDir>/Build/Products` (APFS clonefile: no data copy). */
export function cloneProducts(derivedData: string, runDir: string): string {
  const products = join(derivedData, "Build", "Products");
  if (!existsSync(products)) {
    throw new Error(`no build products in ${products}`);
  }
  const dest = join(runDir, "Build", "Products");
  mkdirSync(join(runDir, "Build"), { recursive: true });
  const result = spawnSync("/bin/cp", ["-c", "-R", products, dest], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`cloning ${products} failed: ${result.stderr.trim() || result.error?.message || result.status}`);
  }
  return dest;
}

/** The one xctestrun the build wrote for `scheme` (no test plans in this project). */
export function findXctestrun(products: string, scheme: string): string {
  const matches = readdirSync(products).filter((name) => name.startsWith(`${scheme}_`) && name.endsWith(".xctestrun"));
  if (matches.length !== 1) {
    throw new Error(`expected one ${scheme}_*.xctestrun in ${products}, found ${matches.length ? matches.join(", ") : "none"}`);
  }
  return join(products, matches[0]);
}

/**
 * A clone costs disk only once the checkout rebuilds over it, so keep each finished run's
 * products for an hour (long enough for a caller to hash them), then drop them; drop the
 * whole run directory, xcresult included, after three days like pool logs.
 */
export function pruneRunDirectories(buildBase: string, nowMs = Date.now()): void {
  const root = join(buildBase, "runs");
  if (!existsSync(root)) return;
  const productsCutoff = nowMs - 60 * 60 * 1000;
  const cutoff = nowMs - 3 * 24 * 60 * 60 * 1000;
  for (const name of readdirSync(root)) {
    const path = join(root, name);
    const pid = Number(/-(\d+)$/.exec(name)?.[1]);
    try {
      const mtime = statSync(path).mtimeMs;
      if (mtime < cutoff) {
        rmSync(path, { recursive: true, force: true });
      } else if (mtime < productsCutoff && pid && pid !== process.pid && !processAlive(pid)) {
        rmSync(join(path, "Build", "Products"), { recursive: true, force: true });
      }
    } catch {
      // Best effort: a clone that survives costs disk only once its source changes.
    }
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}
