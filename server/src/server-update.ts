/**
 * In-app and CLI update of a global `oppi-server` npm install.
 *
 * Registry lookups never run on the request path. Install is one-at-a-time
 * and only to the last-discovered latest version.
 */

import { spawn } from "node:child_process";

import { isNpmVersionNewer, isValidNpmVersion } from "./cli/npm-version.js";
import { manualUpdateCommand, resolveInstallKindAsync } from "./install-kind.js";
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
import { getPackageInfo } from "./version.js";

const log = createLogger({ base: { component: "server_update" } });

const REGISTRY_TIMEOUT_MS = 8_000;
const INSTALL_TIMEOUT_MS = 5 * 60_000;
const REGISTRY_TTL_MS = 15 * 60_000;
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
      execve(process.execPath, process.argv, env);
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
  options: { timeoutMs: number; inheritStdio?: boolean },
): Promise<{ code: number | null; output: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn("npm", args, {
      stdio: options.inheritStdio ? "inherit" : ["ignore", "pipe", "pipe"],
      timeout: options.timeoutMs,
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
  private installKindCache: Awaited<ReturnType<typeof resolveInstallKindAsync>> | null = null;
  private installKindInFlight: Promise<Awaited<ReturnType<typeof resolveInstallKindAsync>>> | null =
    null;
  private readonly onRestart?: (mode: ServerRestartMode) => void;

  constructor(options?: { onRestart?: (mode: ServerRestartMode) => void }) {
    this.onRestart = options?.onRestart;
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
    this.installInFlight = this.runInstall(packageInfo.name, version);
    return { ok: true, update: this.buildSnapshot() };
  }

  private async runInstall(packageName: string, version: string): Promise<void> {
    try {
      const result = await installGlobalPackage(packageName, version);
      if (!result.ok) {
        this.status = "failed";
        this.error = result.output.trim() || "npm install -g failed";
        log.warn("server_update.install_failed", { version, error: this.error });
        return;
      }
      const mode = resolveRestartMode();
      this.status = mode === "manual" ? "restart-needed" : "restarting";
      this.error = undefined;
      log.info("server_update.install_succeeded", { version, restartMode: mode });
      this.scheduleRestart(mode);
    } catch (err: unknown) {
      this.status = "failed";
      this.error = safeErrorMessage(err);
      log.warn("server_update.install_failed", { version, error: this.error });
    } finally {
      this.installInFlight = null;
    }
  }

  private scheduleRestart(mode: ServerRestartMode): void {
    if (!this.onRestart) return;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.onRestart?.(mode);
    }, RESTART_FLUSH_MS);
  }

  private resolveInstall(): Promise<Awaited<ReturnType<typeof resolveInstallKindAsync>>> {
    if (this.installKindCache) return Promise.resolve(this.installKindCache);
    if (!this.installKindInFlight) {
      this.installKindInFlight = resolveInstallKindAsync(getPackageInfo().name).then((value) => {
        this.installKindCache = value;
        return value;
      });
    }
    return this.installKindInFlight;
  }

  private buildSnapshot(): ServerUpdateInfo {
    const packageInfo = getPackageInfo();
    const install = this.installKindCache ?? {
      kind: "other" as const,
      updatable: false,
      manualCommand: manualUpdateCommand(packageInfo.name),
    };
    const latest = this.latestVersion;
    const available =
      install.updatable && latest !== null && isNpmVersionNewer(latest, packageInfo.version);
    const restartMode = resolveRestartMode();
    const info: ServerUpdateInfo = {
      installKind: install.kind,
      latestVersion: latest,
      available,
      manualCommand:
        latest && install.updatable
          ? manualUpdateCommand(packageInfo.name, latest)
          : install.manualCommand,
      status: this.status,
      restartMode,
    };
    if (this.targetVersion) info.targetVersion = this.targetVersion;
    if (this.error) info.error = this.error;
    return info;
  }
}
