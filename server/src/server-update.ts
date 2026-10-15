/**
 * In-app and CLI update of a global `oppi-server` npm install, and in-app
 * rebuild of an `npm link`ed source checkout.
 *
 * Registry lookups never run on the request path. Install is one-at-a-time
 * and only to the last-discovered latest version. A source-link rebuild is
 * offered only when the checkout changed since this process started.
 */

import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { isNpmVersionNewer, isValidNpmVersion } from "./cli/npm-version.js";
import {
  type InstallKind,
  manualUpdateCommand,
  resolveInstallKindAsync,
  SOURCE_BUILD_SCRIPT,
} from "./install-kind.js";
import { getServiceStatus } from "./launchd.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type {
  ServerRestartMode,
  ServerUpdateErrorCode,
  ServerUpdateInfo,
  ServerUpdateStatus,
} from "./types/server-update.js";
import { SERVER_UPDATE_ERROR } from "./types/server-update.js";
import { getPackageInfo, packageRootDir } from "./version.js";

const log = createLogger({ base: { component: "server_update" } });

const REGISTRY_TIMEOUT_MS = 8_000;
const INSTALL_TIMEOUT_MS = 5 * 60_000;
const REGISTRY_TTL_MS = 15 * 60_000;
/** Bounds the checkout scan while the app polls /server/info during an update. */
const SOURCE_SCAN_TTL_MS = 3_000;
/** Checkout inputs the build compiles (tsconfig `include`). */
const SOURCE_DIRS = ["src", "extensions"];
const RESTART_FLUSH_MS = 400;
const ERROR_TAIL_CHARS = 4_000;

export type ServerUpdateBeginResult =
  | { ok: true; update: ServerUpdateInfo }
  | {
      ok: false;
      status: number;
      code: ServerUpdateErrorCode;
      message: string;
      update: ServerUpdateInfo;
    };

export async function fetchLatestPublishedVersion(packageName: string): Promise<string | null> {
  const result = await runNpm(["view", packageName, "version"], {
    timeoutMs: REGISTRY_TIMEOUT_MS,
  });
  if (result.code !== 0) return null;
  const version = result.output.trim().split(/\s+/).pop() ?? "";
  return isValidNpmVersion(version) ? version : null;
}

export async function installGlobalPackage(
  packageName: string,
  version: string,
  options?: { inheritStdio?: boolean },
): Promise<{ ok: boolean; output: string }> {
  const spec = `${packageName}@${version}`;
  const result = await runNpm(["install", "-g", spec], {
    timeoutMs: INSTALL_TIMEOUT_MS,
    inheritStdio: options?.inheritStdio === true,
  });
  return { ok: result.code === 0, output: result.output };
}

/** Rebuild an `npm link`ed checkout in place for the running server to re-exec. */
export async function buildSourceCheckout(
  packageDir: string,
): Promise<{ ok: boolean; output: string }> {
  const result = await runNpm(["run", SOURCE_BUILD_SCRIPT], {
    timeoutMs: INSTALL_TIMEOUT_MS,
    cwd: packageDir,
  });
  return { ok: result.code === 0, output: result.output };
}

function readPackageVersion(packageDir: string): string | null {
  try {
    const raw = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf-8")) as {
      version?: unknown;
    };
    return typeof raw.version === "string" && isValidNpmVersion(raw.version) ? raw.version : null;
  } catch {
    return null;
  }
}

function fileModifiedAt(path: string): number {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return Infinity;
  }
}

/** True once any file under `dir` was modified after `sinceMs`; stops at the first. */
function hasFileModifiedAfter(dir: string, sinceMs: number): boolean {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (hasFileModifiedAfter(path, sinceMs)) return true;
    } else if (entry.isFile()) {
      try {
        if (statSync(path).mtimeMs > sinceMs) return true;
      } catch {
        // Deleted mid-scan.
      }
    }
  }
  return false;
}

export function resolveRestartMode(): ServerRestartMode {
  if (typeof process.execve === "function" && process.argv.length >= 2) {
    return "reexec";
  }
  if (isCurrentLaunchdJob()) return "launchd";
  return "manual";
}

export function isCurrentLaunchdJob(): boolean {
  if (process.platform !== "darwin") return false;
  try {
    const status = getServiceStatus();
    return Boolean(status.running && status.pid === process.pid);
  } catch {
    return false;
  }
}

/**
 * Replace this process with the updated `oppi` after listeners are closed.
 *
 * LaunchAgent KeepAlive uses SuccessfulExit=false, so a clean exit(0) would
 * not come back. Prefer execve (same PID, launchd keeps the job). If execve
 * is unavailable and this is the LaunchAgent, exit 1 so KeepAlive restarts
 * after ThrottleInterval (5s).
 */
export function restartUpdatedProcess(
  mode: ServerRestartMode,
  isLaunchdJob: () => boolean = isCurrentLaunchdJob,
): boolean {
  if (mode === "reexec") {
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
      if (typeof value === "string") env[key] = value;
    }
    const execve = process.execve;
    if (typeof execve !== "function") {
      if (isLaunchdJob()) process.exit(1);
      return false;
    }
    try {
      // Keep node flags (loaders, heap size): process.argv omits them.
      execve(
        process.execPath,
        [process.argv[0] ?? process.execPath, ...process.execArgv, ...process.argv.slice(1)],
        env,
      );
    } catch (err: unknown) {
      log.error("server_update.reexec_failed", { error: safeErrorMessage(err) });
      if (isLaunchdJob()) process.exit(1);
      return false;
    }
    return false;
  }
  if (mode === "launchd") process.exit(1);
  return false;
}

// Called by the CLI's actual onRestart callback. A failed foreground exec
// must bring up a fresh Server: start() on the stopped instance duplicates
// upgrade listeners and does not restore its stopped subsystems.
export async function serveUpdatedProcess(
  mode: ServerRestartMode,
  stop: () => Promise<void>,
  restore: () => Promise<void>,
  restart: (mode: ServerRestartMode) => boolean = restartUpdatedProcess,
): Promise<void> {
  if (mode === "manual") return;
  await stop();
  if (!restart(mode)) await restore();
}

function runNpm(
  args: string[],
  options: { timeoutMs: number; inheritStdio?: boolean; cwd?: string },
): Promise<{ code: number | null; output: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn("npm", args, {
      stdio: options.inheritStdio ? "inherit" : ["ignore", "pipe", "pipe"],
      timeout: options.timeoutMs,
      cwd: options.cwd,
      env: process.env,
      shell: process.platform === "win32",
    });
    const chunks: Buffer[] = [];
    child.stdout?.on("data", (chunk: Buffer | string) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    child.stderr?.on("data", (chunk: Buffer | string) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        code,
        output: Buffer.concat(chunks).toString("utf8").slice(-ERROR_TAIL_CHARS),
      });
    });
  });
}

export class ServerUpdateService {
  private status: ServerUpdateStatus = "idle";
  private targetVersion: string | undefined;
  private error: string | undefined;
  private latestVersion: string | null = null;
  private latestFetchedAt = 0;
  private latestInFlight: Promise<string | null> | null = null;
  private installInFlight: Promise<void> | null = null;
  private restartTimer: ReturnType<typeof setTimeout> | null = null;
  private installKindCache: InstallKind | null = null;
  private installKindInFlight: Promise<InstallKind> | null = null;
  private sourceCache: { version: string | null; changed: boolean; checkedAt: number } | null =
    null;
  private readonly onRestart?: (mode: ServerRestartMode, targetVersion: string) => void;
  private readonly packageDir: string | undefined;
  /**
   * Source edits after this count as not yet running: the earlier of process
   * start and the running build, so edits made before a restart that skipped
   * the build still count.
   */
  private readonly loadedSourceAt: number;

  constructor(options?: {
    onRestart?: (mode: ServerRestartMode, targetVersion: string) => void;
    restartNeededVersion?: string;
    /** This install's package directory; defaults to the running package. */
    packageDir?: string;
  }) {
    this.onRestart = options?.onRestart;
    this.packageDir = options?.packageDir ?? packageRootDir();
    this.loadedSourceAt = Math.min(
      performance.timeOrigin,
      this.packageDir ? fileModifiedAt(join(this.packageDir, "dist", "src", "cli.js")) : Infinity,
    );
    if (options?.restartNeededVersion) {
      this.status = "restart-needed";
      this.targetVersion = options.restartNeededVersion;
    }
  }

  /** Kick a non-blocking registry lookup. Safe to call from server start. */
  start(): void {
    void this.refreshLatest();
    void this.resolveInstall();
  }

  async refreshLatest(): Promise<string | null> {
    if (this.latestInFlight) return this.latestInFlight;
    const packageName = getPackageInfo().name;
    this.latestInFlight = fetchLatestPublishedVersion(packageName)
      .then((version) => {
        this.latestVersion = version;
        this.latestFetchedAt = Date.now();
        return version;
      })
      .catch((err: unknown) => {
        log.warn("server_update.registry_failed", { error: safeErrorMessage(err) });
        this.latestVersion = null;
        this.latestFetchedAt = Date.now();
        return null;
      })
      .finally(() => {
        this.latestInFlight = null;
      });
    return this.latestInFlight;
  }

  snapshot(): ServerUpdateInfo {
    if (Date.now() - this.latestFetchedAt > REGISTRY_TTL_MS) {
      void this.refreshLatest();
    }
    return this.buildSnapshot();
  }

  /** A lookup in progress is not a resolved non-updatable install. */
  infoSnapshot(): ServerUpdateInfo | undefined {
    this.snapshot();
    return this.installKindCache ? this.buildSnapshot() : undefined;
  }

  async beginUpdate(versionRaw: unknown): Promise<ServerUpdateBeginResult> {
    const update = this.snapshot();
    if (
      this.status === "installing" ||
      this.status === "restarting" ||
      this.status === "restart-needed" ||
      this.installInFlight
    ) {
      return {
        ok: false,
        status: 409,
        code: SERVER_UPDATE_ERROR.updateInProgress,
        message: "An update is already in progress",
        update,
      };
    }

    if (typeof versionRaw !== "string" || !isValidNpmVersion(versionRaw.trim())) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.invalidVersion,
        message:
          'Request body must be { version: "<semver>" } matching the last discovered latest version',
        update,
      };
    }
    const version = versionRaw.trim();

    const packageInfo = getPackageInfo();
    const install = await this.resolveInstall();
    // Two requests can wait on the same initial npm root lookup.
    if (this.installInFlight) {
      return {
        ok: false,
        status: 409,
        code: SERVER_UPDATE_ERROR.updateInProgress,
        message: "An update is already in progress",
        update: this.snapshot(),
      };
    }
    if (!install.updatable) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.installNotUpdatable,
        message: "This server is not a global npm install and cannot be updated from the app",
        update: this.snapshot(),
      };
    }

    if (install.kind === "source-link" && install.packageDir) {
      return this.beginSourceBuild(version, install.packageDir);
    }

    const latest = this.latestVersion;
    if (!latest) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.latestUnknown,
        message: "Latest npm version is unknown; try again after the server can reach the registry",
        update: this.snapshot(),
      };
    }

    if (version !== latest) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.versionNotLatest,
        message: `Version must equal the last discovered latest (${latest})`,
        update: this.snapshot(),
      };
    }

    if (!isNpmVersionNewer(version, packageInfo.version)) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.alreadyCurrent,
        message: `Already on ${packageInfo.version}`,
        update: this.snapshot(),
      };
    }

    this.status = "installing";
    this.targetVersion = version;
    this.error = undefined;
    this.installInFlight = this.runInstall(
      version,
      () => installGlobalPackage(packageInfo.name, version),
      "npm install -g failed",
    );
    return { ok: true, update: this.buildSnapshot() };
  }

  /** The app's version must be the checkout's, and the checkout must have changed. */
  private beginSourceBuild(version: string, packageDir: string): ServerUpdateBeginResult {
    const source = this.sourceState(true);
    if (!source.version) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.latestUnknown,
        message: `Cannot read a version from ${join(packageDir, "package.json")}`,
        update: this.snapshot(),
      };
    }
    if (version !== source.version) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.versionNotLatest,
        message: `Version must equal the checkout's version (${source.version})`,
        update: this.snapshot(),
      };
    }
    if (!source.changed) {
      return {
        ok: false,
        status: 400,
        code: SERVER_UPDATE_ERROR.alreadyCurrent,
        message: "The checkout has not changed since this server started",
        update: this.snapshot(),
      };
    }

    this.status = "installing";
    this.targetVersion = version;
    this.error = undefined;
    this.installInFlight = this.runInstall(
      version,
      () => buildSourceCheckout(packageDir),
      `npm run ${SOURCE_BUILD_SCRIPT} failed`,
    );
    return { ok: true, update: this.buildSnapshot() };
  }

  private async runInstall(
    version: string,
    install: () => Promise<{ ok: boolean; output: string }>,
    failureMessage: string,
  ): Promise<void> {
    try {
      const result = await install();
      if (!result.ok) {
        this.status = "failed";
        this.error = result.output.trim() || failureMessage;
        log.warn("server_update.install_failed", { version, error: this.error });
        return;
      }
      const mode = resolveRestartMode();
      this.status = mode === "manual" ? "restart-needed" : "restarting";
      this.error = undefined;
      log.info("server_update.install_succeeded", { version, restartMode: mode });
      this.scheduleRestart(mode, version);
    } catch (err: unknown) {
      this.status = "failed";
      this.error = safeErrorMessage(err);
      log.warn("server_update.install_failed", { version, error: this.error });
    } finally {
      this.installInFlight = null;
    }
  }

  private scheduleRestart(mode: ServerRestartMode, version: string): void {
    if (!this.onRestart) return;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.onRestart?.(mode, version);
    }, RESTART_FLUSH_MS);
  }

  private resolveInstall(): Promise<InstallKind> {
    if (this.installKindCache) return Promise.resolve(this.installKindCache);
    if (!this.installKindInFlight) {
      this.installKindInFlight = resolveInstallKindAsync(
        getPackageInfo().name,
        this.packageDir,
      ).then((value) => {
        this.installKindCache = value;
        return value;
      });
    }
    return this.installKindInFlight;
  }

  /**
   * The checkout's version, and whether it differs from what this process
   * loaded at start: a new package.json version or an edited source file.
   */
  private sourceState(force = false): { version: string | null; changed: boolean } {
    const packageDir = this.installKindCache?.packageDir;
    if (!packageDir) return { version: null, changed: false };
    const now = Date.now();
    if (!force && this.sourceCache && now - this.sourceCache.checkedAt < SOURCE_SCAN_TTL_MS) {
      return this.sourceCache;
    }
    const version = readPackageVersion(packageDir);
    const changed =
      (version !== null && version !== getPackageInfo().version) ||
      SOURCE_DIRS.some((dir) => hasFileModifiedAfter(join(packageDir, dir), this.loadedSourceAt));
    this.sourceCache = { version, changed, checkedAt: now };
    return this.sourceCache;
  }

  private buildSnapshot(): ServerUpdateInfo {
    const packageInfo = getPackageInfo();
    const install = this.installKindCache ?? {
      kind: "other" as const,
      updatable: false,
      manualCommand: manualUpdateCommand(packageInfo.name),
    };
    let latest = this.latestVersion;
    let available =
      install.updatable && latest !== null && isNpmVersionNewer(latest, packageInfo.version);
    let manualCommand =
      latest && install.updatable
        ? manualUpdateCommand(packageInfo.name, latest)
        : install.manualCommand;
    if (install.kind === "source-link") {
      const source = this.sourceState();
      latest = source.version;
      available = source.changed && source.version !== null;
      manualCommand = install.manualCommand;
    }
    const restartMode = resolveRestartMode();
    const info: ServerUpdateInfo = {
      installKind: install.kind,
      latestVersion: latest,
      available,
      manualCommand,
      status: this.status,
      restartMode,
    };
    if (this.targetVersion) info.targetVersion = this.targetVersion;
    if (this.error) info.error = this.error;
    return info;
  }
}
