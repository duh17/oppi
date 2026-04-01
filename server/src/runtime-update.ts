/**
 * Runtime dependency manager.
 *
 * The server runtime lives at `~/.config/oppi/server-runtime/` (mutable).
 * It is seeded from the Mac app bundle on first launch or version bump.
 * After seeding, users can update deps independently via:
 *
 *   CLI:     `oppi update`
 *   Mac app: Settings → Update Server Dependencies
 *   API:     POST /server/runtime/update
 *
 * Updates run `bun install` (or `npm install`) in the runtime dir using
 * the existing package.json. The server must be restarted after updates
 * to pick up new code.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";

export interface RuntimeUpdateStatus {
  packageName: string;
  currentVersion: string;
  latestVersion?: string;
  pendingVersion?: string;
  updateAvailable: boolean;
  canUpdate: boolean;
  checking: boolean;
  updateInProgress: boolean;
  restartRequired: boolean;
  lastCheckedAt?: number;
  checkError?: string;
  lastUpdatedAt?: number;
  lastUpdateError?: string;
  runtimeDir?: string;
  seedVersion?: string;
}

export interface RuntimeUpdateResult {
  ok: boolean;
  message: string;
  latestVersion?: string;
  pendingVersion?: string;
  restartRequired: boolean;
  error?: string;
  updatedPackages?: UpdatedPackage[];
}

export interface UpdatedPackage {
  name: string;
  from: string;
  to: string;
}

interface RuntimeUpdateManagerOptions {
  packageName?: string;
  currentVersion: string;
}

/**
 * Resolves the mutable runtime directory.
 *
 * The server's own location tells us where the runtime dir is:
 * if we're running from `~/.config/oppi/server-runtime/dist/src/cli.js`,
 * the runtime dir is `~/.config/oppi/server-runtime/`.
 *
 * Falls back to the OPPI_DATA_DIR-relative conventional path.
 */
function resolveRuntimeDir(): string | undefined {
  // The CLI entrypoint is at <runtimeDir>/dist/src/cli.js
  // __dirname in ESM is not available, but we can use import.meta.url or process.argv
  const cliPath = process.argv[1];
  if (cliPath) {
    // Walk up from dist/src/cli.js → runtime dir
    const candidate = dirname(dirname(dirname(cliPath)));
    if (
      existsSync(join(candidate, "package.json")) &&
      existsSync(join(candidate, "node_modules"))
    ) {
      return candidate;
    }
  }

  // Fallback: conventional path
  const home = process.env.HOME || process.env.USERPROFILE || "";
  const conventional = join(home, ".config", "oppi", "server-runtime");
  if (existsSync(join(conventional, "package.json"))) {
    return conventional;
  }

  return undefined;
}

/**
 * Resolves a package manager binary for running install.
 *
 * Priority: OPPI_RUNTIME_BIN env (set by Mac app) → bun → npm → node (with npx).
 */
function resolvePackageManager(): { bin: string; args: string[]; name: string } | undefined {
  // The runtime dir only has dist/ (no source) so we must skip prepare/build scripts.
  // Also skip postinstall scripts for supply-chain safety (consistent with .npmrc).
  const ignoreScripts = "--ignore-scripts";

  // Mac app injects the exact bun path it launched us with
  const runtimeBin = process.env.OPPI_RUNTIME_BIN;
  if (runtimeBin && existsSync(runtimeBin) && runtimeBin.includes("bun")) {
    return { bin: runtimeBin, args: ["install", "--no-save", ignoreScripts], name: "bun" };
  }

  // Check common bun locations
  const bunCandidates = [
    "/opt/homebrew/bin/bun",
    "/usr/local/bin/bun",
    join(process.env.HOME || "", ".bun", "bin", "bun"),
  ];
  for (const p of bunCandidates) {
    if (existsSync(p)) {
      return { bin: p, args: ["install", "--no-save", ignoreScripts], name: "bun" };
    }
  }

  // Check npm
  const npmCandidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"];
  for (const p of npmCandidates) {
    if (existsSync(p)) {
      return { bin: p, args: ["install", "--omit=dev", ignoreScripts], name: "npm" };
    }
  }

  return undefined;
}

function readPackageVersion(dir: string, pkg: string): string | undefined {
  try {
    const pkgJson = join(dir, "node_modules", pkg, "package.json");
    const raw = JSON.parse(readFileSync(pkgJson, "utf-8"));
    return raw.version;
  } catch {
    return undefined;
  }
}

function readSeedVersion(dir: string): string | undefined {
  try {
    return readFileSync(join(dir, ".seed-version"), "utf-8").trim();
  } catch {
    return undefined;
  }
}

/**
 * Snapshot installed versions of key packages for before/after comparison.
 */
function snapshotVersions(runtimeDir: string): Map<string, string> {
  const versions = new Map<string, string>();
  try {
    const pkgJson = JSON.parse(readFileSync(join(runtimeDir, "package.json"), "utf-8"));
    const deps = { ...pkgJson.dependencies, ...pkgJson.optionalDependencies };
    for (const name of Object.keys(deps)) {
      const v = readPackageVersion(runtimeDir, name);
      if (v) versions.set(name, v);
    }
  } catch {
    // Ignore — we'll just skip the diff
  }
  return versions;
}

export class RuntimeUpdateManager {
  private readonly packageName: string;
  private readonly currentVersion: string;
  private updateInProgress = false;
  private lastCheckedAt?: number;
  private lastUpdatedAt?: number;
  private lastUpdateError?: string;
  private restartRequired = false;

  constructor(options: RuntimeUpdateManagerOptions) {
    this.packageName = options.packageName || "@mariozechner/pi-coding-agent";
    this.currentVersion = options.currentVersion;
  }

  async getStatus(_options?: { force?: boolean }): Promise<RuntimeUpdateStatus> {
    const runtimeDir = resolveRuntimeDir();
    const canUpdate = runtimeDir !== undefined && resolvePackageManager() !== undefined;

    return {
      packageName: this.packageName,
      currentVersion: this.currentVersion,
      updateAvailable: false, // We don't check npm registry — user decides
      canUpdate,
      checking: false,
      updateInProgress: this.updateInProgress,
      restartRequired: this.restartRequired,
      lastCheckedAt: this.lastCheckedAt,
      lastUpdatedAt: this.lastUpdatedAt,
      lastUpdateError: this.lastUpdateError,
      runtimeDir,
      seedVersion: runtimeDir ? readSeedVersion(runtimeDir) : undefined,
    };
  }

  /**
   * Run package manager install in the runtime directory.
   *
   * This updates all deps to their latest semver-compatible versions
   * according to the ranges in package.json.
   */
  async updateRuntime(): Promise<RuntimeUpdateResult> {
    if (this.updateInProgress) {
      return {
        ok: false,
        message: "Update already in progress",
        restartRequired: false,
      };
    }

    const runtimeDir = resolveRuntimeDir();
    if (!runtimeDir) {
      return {
        ok: false,
        message: "Runtime directory not found. The server may be running from source.",
        restartRequired: false,
        error: "runtime_dir_not_found",
      };
    }

    const pm = resolvePackageManager();
    if (!pm) {
      return {
        ok: false,
        message: "No package manager found (bun or npm required)",
        restartRequired: false,
        error: "no_package_manager",
      };
    }

    this.updateInProgress = true;
    this.lastUpdateError = undefined;

    try {
      // Snapshot before
      const before = snapshotVersions(runtimeDir);

      // Run install
      await execAsync(pm.bin, pm.args, {
        cwd: runtimeDir,
        timeout: 120_000,
      });

      // Snapshot after
      const after = snapshotVersions(runtimeDir);

      // Compute diff
      const updatedPackages: UpdatedPackage[] = [];
      for (const [name, newVersion] of after) {
        const oldVersion = before.get(name);
        if (oldVersion && oldVersion !== newVersion) {
          updatedPackages.push({ name, from: oldVersion, to: newVersion });
        }
      }

      this.lastUpdatedAt = Date.now();
      this.restartRequired = updatedPackages.length > 0;

      const message =
        updatedPackages.length > 0
          ? `Updated ${updatedPackages.length} package(s). Restart required to apply changes.`
          : "All dependencies are up to date.";

      return {
        ok: true,
        message,
        restartRequired: this.restartRequired,
        updatedPackages,
      };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      this.lastUpdateError = message;
      return {
        ok: false,
        message: `Update failed: ${message}`,
        restartRequired: false,
        error: "install_failed",
      };
    } finally {
      this.updateInProgress = false;
    }
  }
}

function execAsync(
  bin: string,
  args: string[],
  options: { cwd: string; timeout: number },
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { cwd: options.cwd, timeout: options.timeout }, (err, stdout, stderr) => {
      if (err) {
        const msg = stderr?.trim() || stdout?.trim() || err.message;
        reject(new Error(msg));
      } else {
        resolve({ stdout: stdout || "", stderr: stderr || "" });
      }
    });
  });
}
