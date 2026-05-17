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
 * Updates run `npm install` in the runtime dir using the existing
 * package.json. When a newer pi runtime package is available,
 * Oppi pins the runtime manifest to that version before installing.
 * The server must be restarted after updates to pick up new code.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
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

interface PackageManagerCommand {
  bin: string;
  installArgs: string[];
  name: string;
}

const DEFAULT_PI_CODING_AGENT_PACKAGE = "@earendil-works/pi-coding-agent";
const LEGACY_PI_CODING_AGENT_PACKAGE = "@mariozechner/pi-coding-agent";

function packageNameCandidates(packageName: string): string[] {
  if (packageName === DEFAULT_PI_CODING_AGENT_PACKAGE) {
    return [DEFAULT_PI_CODING_AGENT_PACKAGE, LEGACY_PI_CODING_AGENT_PACKAGE];
  }
  return [packageName];
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
  const cliPath = process.argv[1];
  if (cliPath) {
    const candidate = dirname(dirname(dirname(cliPath)));
    if (
      existsSync(join(candidate, "package.json")) &&
      existsSync(join(candidate, "node_modules"))
    ) {
      return candidate;
    }
  }

  const home = process.env.HOME || process.env.USERPROFILE || "";
  const conventional = join(home, ".config", "oppi", "server-runtime");
  if (existsSync(join(conventional, "package.json"))) {
    return conventional;
  }

  return undefined;
}

/**
 * Resolves the npm binary used for runtime dependency installs.
 *
 * Priority: sibling npm next to OPPI_RUNTIME_BIN (set by Mac app) → system npm.
 */
function resolvePackageManager(): PackageManagerCommand | undefined {
  const ignoreScripts = "--ignore-scripts";
  const installArgs = ["install", "--omit=dev", ignoreScripts];

  const runtimeBin = process.env.OPPI_RUNTIME_BIN;
  if (runtimeBin && existsSync(runtimeBin)) {
    const siblingNpm = join(dirname(runtimeBin), "npm");
    if (existsSync(siblingNpm)) {
      return { bin: siblingNpm, installArgs, name: "npm" };
    }
  }

  const npmCandidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"];
  for (const p of npmCandidates) {
    if (existsSync(p)) {
      return { bin: p, installArgs, name: "npm" };
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

function parseSemver(version: string): [number, number, number] | undefined {
  const match = version.trim().match(/^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/);
  if (!match) return undefined;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

function isVersionNewer(candidate: string | undefined, current: string | undefined): boolean {
  if (!candidate || !current) return false;
  const a = parseSemver(candidate);
  const b = parseSemver(current);
  if (!a || !b) return false;
  if (a[0] !== b[0]) return a[0] > b[0];
  if (a[1] !== b[1]) return a[1] > b[1];
  return a[2] > b[2];
}

function readManifestDependencyVersion(
  runtimeDir: string,
  packageName: string,
): string | undefined {
  try {
    const pkgJson = JSON.parse(readFileSync(join(runtimeDir, "package.json"), "utf-8"));
    return pkgJson.dependencies?.[packageName] ?? pkgJson.optionalDependencies?.[packageName];
  } catch {
    return undefined;
  }
}

function findManifestDependencyName(
  runtimeDir: string,
  packageNames: string[],
): string | undefined {
  try {
    const pkgJson = JSON.parse(readFileSync(join(runtimeDir, "package.json"), "utf-8"));
    for (const packageName of packageNames) {
      if (pkgJson.dependencies?.[packageName] || pkgJson.optionalDependencies?.[packageName]) {
        return packageName;
      }
    }
  } catch {
    // Ignore and fall back to the default package name.
  }
  return undefined;
}

function pinManifestDependencyVersion(
  runtimeDir: string,
  packageName: string,
  version: string,
): void {
  const pkgPath = join(runtimeDir, "package.json");
  const pkgJson = JSON.parse(readFileSync(pkgPath, "utf-8"));

  if (pkgJson.dependencies && packageName in pkgJson.dependencies) {
    pkgJson.dependencies[packageName] = version;
  } else if (pkgJson.optionalDependencies && packageName in pkgJson.optionalDependencies) {
    pkgJson.optionalDependencies[packageName] = version;
  } else {
    pkgJson.dependencies = { ...(pkgJson.dependencies ?? {}), [packageName]: version };
  }

  writeFileSync(pkgPath, JSON.stringify(pkgJson, null, 2) + "\n");
}

function replaceManifestDependencyName(
  runtimeDir: string,
  fromPackageName: string,
  toPackageName: string,
  version: string,
): void {
  const pkgPath = join(runtimeDir, "package.json");
  const pkgJson = JSON.parse(readFileSync(pkgPath, "utf-8"));

  for (const field of ["dependencies", "optionalDependencies"] as const) {
    const deps = pkgJson[field];
    if (!deps || typeof deps !== "object" || !(fromPackageName in deps)) {
      continue;
    }

    delete deps[fromPackageName];
    deps[toPackageName] = version;
    writeFileSync(pkgPath, JSON.stringify(pkgJson, null, 2) + "\n");
    return;
  }

  pinManifestDependencyVersion(runtimeDir, toPackageName, version);
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

async function fetchLatestPackageVersion(packageName: string): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);

  try {
    const encoded = encodeURIComponent(packageName);
    const res = await fetch(`https://registry.npmjs.org/${encoded}/latest`, {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    if (!res.ok) {
      throw new Error(`npm registry returned ${res.status}`);
    }

    const data = (await res.json()) as { version?: unknown };
    if (typeof data.version !== "string" || data.version.trim().length === 0) {
      throw new Error("npm registry response missing version");
    }

    return data.version.trim();
  } finally {
    clearTimeout(timeout);
  }
}

export class RuntimeUpdateManager {
  private readonly packageName: string;
  private readonly currentVersion: string;
  private updateInProgress = false;
  private lastCheckedAt?: number;
  private latestVersion?: string;
  private checkError?: string;
  private lastUpdatedAt?: number;
  private lastUpdateError?: string;
  private restartRequired = false;

  constructor(options: RuntimeUpdateManagerOptions) {
    this.packageName = options.packageName || DEFAULT_PI_CODING_AGENT_PACKAGE;
    this.currentVersion = options.currentVersion;
  }

  async getStatus(options?: { force?: boolean }): Promise<RuntimeUpdateStatus> {
    const runtimeDir = resolveRuntimeDir();
    const canUpdate = runtimeDir !== undefined && resolvePackageManager() !== undefined;

    if (options?.force || this.lastCheckedAt === undefined) {
      this.lastCheckedAt = Date.now();
      try {
        this.latestVersion = await fetchLatestPackageVersion(this.packageName);
        this.checkError = undefined;
      } catch (err: unknown) {
        this.checkError = err instanceof Error ? err.message : String(err);
      }
    }

    const updateAvailable = isVersionNewer(this.latestVersion, this.currentVersion);

    return {
      packageName: this.packageName,
      currentVersion: this.currentVersion,
      latestVersion: this.latestVersion,
      pendingVersion: updateAvailable ? this.latestVersion : undefined,
      updateAvailable,
      canUpdate,
      checking: false,
      updateInProgress: this.updateInProgress,
      restartRequired: this.restartRequired,
      lastCheckedAt: this.lastCheckedAt,
      checkError: this.checkError,
      lastUpdatedAt: this.lastUpdatedAt,
      lastUpdateError: this.lastUpdateError,
      runtimeDir,
      seedVersion: runtimeDir ? readSeedVersion(runtimeDir) : undefined,
    };
  }

  /**
   * Run package manager install in the runtime directory.
   *
   * If a newer pi runtime package is published, the runtime manifest is first
   * pinned to that exact version so Oppi can truly upgrade the embedded runtime
   * instead of only reinstalling already-pinned dependencies.
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
        message: "No npm executable found. Install Node.js and try again.",
        restartRequired: false,
        error: "no_package_manager",
      };
    }

    this.updateInProgress = true;
    this.lastUpdateError = undefined;

    try {
      const status = await this.getStatus({ force: true });
      const before = snapshotVersions(runtimeDir);
      const manifestPackageName =
        findManifestDependencyName(runtimeDir, packageNameCandidates(this.packageName)) ??
        this.packageName;
      const migrationRequired = manifestPackageName !== this.packageName;
      const migrationVersion =
        status.latestVersion ??
        readManifestDependencyVersion(runtimeDir, manifestPackageName) ??
        (parseSemver(this.currentVersion) ? this.currentVersion : undefined);
      const targetVersion = status.updateAvailable
        ? status.latestVersion
        : migrationRequired
          ? migrationVersion
          : undefined;

      if (targetVersion) {
        if (migrationRequired) {
          replaceManifestDependencyName(
            runtimeDir,
            manifestPackageName,
            this.packageName,
            targetVersion,
          );
        } else {
          const pinned = readManifestDependencyVersion(runtimeDir, this.packageName);
          if (pinned !== targetVersion) {
            pinManifestDependencyVersion(runtimeDir, this.packageName, targetVersion);
          }
        }
      }

      await execAsync(pm.bin, pm.installArgs, {
        cwd: runtimeDir,
        timeout: 120_000,
      });

      const after = snapshotVersions(runtimeDir);
      const updatedPackages: UpdatedPackage[] = [];
      for (const [name, newVersion] of after) {
        const oldVersion = before.get(name);
        if (oldVersion && oldVersion !== newVersion) {
          updatedPackages.push({ name, from: oldVersion, to: newVersion });
        }
      }

      this.lastUpdatedAt = Date.now();
      this.restartRequired = updatedPackages.length > 0 || migrationRequired;

      const message =
        updatedPackages.length > 0
          ? `Updated ${updatedPackages.length} package(s). Restart required to apply changes.`
          : migrationRequired
            ? targetVersion
              ? `Migrated runtime dependency to ${this.packageName}@${targetVersion}. Restart required to apply changes.`
              : `Migrated runtime dependency to ${this.packageName}. Restart required to apply changes.`
            : targetVersion
              ? `Pinned ${this.packageName} to ${targetVersion}. Restart may still be required after install.`
              : "All dependencies are up to date.";

      return {
        ok: true,
        message,
        latestVersion: status.latestVersion,
        pendingVersion: targetVersion,
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
