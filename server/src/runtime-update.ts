import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

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
}

export interface RuntimeUpdateResult {
  ok: boolean;
  message: string;
  latestVersion?: string;
  pendingVersion?: string;
  restartRequired: boolean;
  error?: string;
}

type CommandRunner = (file: string, args: string[], timeoutMs: number) => Promise<string>;

interface RuntimeUpdateManagerOptions {
  packageName?: string;
  currentVersion: string;
  npmExecutable?: string;
  checkIntervalMs?: number;
  checkTimeoutMs?: number;
  updateTimeoutMs?: number;
  commandRunner?: CommandRunner;
  now?: () => number;
}

function normalizeVersion(raw: string): string | undefined {
  const match = raw.trim().match(/(\d+\.\d+\.\d+)/);
  return match ? match[1] : undefined;
}

function parseSemver(version: string): [number, number, number] | null {
  const match = version.trim().match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!match) {
    return null;
  }

  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);

  if (!Number.isFinite(major) || !Number.isFinite(minor) || !Number.isFinite(patch)) {
    return null;
  }

  return [major, minor, patch];
}

function isVersionNewer(candidate: string, current: string): boolean {
  const candidateSemver = parseSemver(candidate);
  const currentSemver = parseSemver(current);

  if (!candidateSemver || !currentSemver) {
    return false;
  }

  for (let i = 0; i < 3; i += 1) {
    if (candidateSemver[i] > currentSemver[i]) {
      return true;
    }
    if (candidateSemver[i] < currentSemver[i]) {
      return false;
    }
  }

  return false;
}

function errorMessage(err: unknown): string {
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
}

/**
 * Manages update checks + apply flow for the server runtime package.
 *
 * Strategy:
 * - check latest version via `npm view <package> version`
 * - apply update via `npm install -g <package>@latest`
 * - mark restartRequired after successful install
 */
export class RuntimeUpdateManager {
  private readonly packageName: string;
  private readonly currentVersion: string;
  private readonly npmExecutable: string;
  private readonly checkIntervalMs: number;
  private readonly checkTimeoutMs: number;
  private readonly updateTimeoutMs: number;
  private readonly commandRunner: CommandRunner;
  private readonly now: () => number;

  private npmAvailable: boolean | undefined;

  private status: RuntimeUpdateStatus;

  constructor(options: RuntimeUpdateManagerOptions) {
    this.packageName = options.packageName || "oppi-server";
    this.currentVersion = options.currentVersion;
    this.npmExecutable = options.npmExecutable || "npm";
    this.checkIntervalMs = options.checkIntervalMs ?? 6 * 60 * 60 * 1000;
    this.checkTimeoutMs = options.checkTimeoutMs ?? 4_000;
    this.updateTimeoutMs = options.updateTimeoutMs ?? 3 * 60 * 1000;
    this.commandRunner = options.commandRunner || this.defaultCommandRunner;
    this.now = options.now || Date.now;

    this.status = {
      packageName: this.packageName,
      currentVersion: this.currentVersion,
      updateAvailable: false,
      canUpdate: false,
      checking: false,
      updateInProgress: false,
      restartRequired: false,
    };
  }

  private readonly defaultCommandRunner: CommandRunner = async (file, args, timeoutMs) => {
    const result = await execFileAsync(file, args, {
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 64 * 1024,
    });

    return result.stdout;
  };

  private snapshot(): RuntimeUpdateStatus {
    return { ...this.status };
  }

  private async ensureNpmAvailability(): Promise<void> {
    if (this.npmAvailable !== undefined) {
      this.status.canUpdate = this.npmAvailable;
      return;
    }

    try {
      await this.commandRunner(this.npmExecutable, ["--version"], this.checkTimeoutMs);
      this.npmAvailable = true;
      this.status.canUpdate = true;
      this.status.checkError = undefined;
    } catch {
      this.npmAvailable = false;
      this.status.canUpdate = false;
      this.status.checkError = `npm executable "${this.npmExecutable}" is unavailable`;
    }
  }

  async getStatus(options?: { force?: boolean }): Promise<RuntimeUpdateStatus> {
    await this.ensureNpmAvailability();

    const force = options?.force === true;
    const now = this.now();
    const stale =
      this.status.lastCheckedAt === undefined ||
      now - this.status.lastCheckedAt >= this.checkIntervalMs;

    if (!force && (!stale || this.status.checking || this.status.updateInProgress)) {
      return this.snapshot();
    }

    this.status.checking = true;
    this.status.lastCheckedAt = now;

    try {
      if (!this.status.canUpdate) {
        this.status.latestVersion = undefined;
        this.status.updateAvailable = false;
        return this.snapshot();
      }

      const output = await this.commandRunner(
        this.npmExecutable,
        ["view", this.packageName, "version"],
        this.checkTimeoutMs,
      );
      const latest = normalizeVersion(output);

      if (!latest) {
        this.status.latestVersion = undefined;
        this.status.updateAvailable = false;
        this.status.checkError = `Unable to parse version from npm registry response for ${this.packageName}`;
        return this.snapshot();
      }

      this.status.latestVersion = latest;
      this.status.checkError = undefined;
      this.status.updateAvailable =
        this.status.pendingVersion === latest ? false : isVersionNewer(latest, this.currentVersion);

      return this.snapshot();
    } catch (err: unknown) {
      this.status.latestVersion = undefined;
      this.status.updateAvailable = false;
      this.status.checkError = errorMessage(err);
      return this.snapshot();
    } finally {
      this.status.checking = false;
    }
  }

  async updateRuntime(): Promise<RuntimeUpdateResult> {
    await this.ensureNpmAvailability();

    if (!this.status.canUpdate) {
      const message = `Runtime updates require npm on the host (${this.npmExecutable} not found)`;
      this.status.lastUpdateError = message;
      return {
        ok: false,
        message,
        error: message,
        restartRequired: this.status.restartRequired,
      };
    }

    if (this.status.updateInProgress) {
      const message = "Runtime update already in progress";
      return {
        ok: false,
        message,
        error: message,
        restartRequired: this.status.restartRequired,
      };
    }

    this.status.updateInProgress = true;

    try {
      const checked = await this.getStatus({ force: true });
      const expectedVersion = checked.latestVersion;

      await this.commandRunner(
        this.npmExecutable,
        ["install", "-g", `${this.packageName}@latest`],
        this.updateTimeoutMs,
      );

      const refreshed = await this.getStatus({ force: true });
      const pendingVersion = refreshed.latestVersion || expectedVersion;

      this.status.pendingVersion = pendingVersion;
      this.status.lastUpdatedAt = this.now();
      this.status.lastUpdateError = undefined;
      this.status.restartRequired = true;
      this.status.updateAvailable = false;

      const message = pendingVersion
        ? `Installed ${this.packageName}@${pendingVersion}. Restart server to apply.`
        : `Installed latest ${this.packageName}. Restart server to apply.`;

      return {
        ok: true,
        message,
        latestVersion: refreshed.latestVersion,
        pendingVersion,
        restartRequired: true,
      };
    } catch (err: unknown) {
      const message = `Runtime update failed: ${errorMessage(err)}`;
      this.status.lastUpdateError = message;

      return {
        ok: false,
        message,
        error: message,
        latestVersion: this.status.latestVersion,
        pendingVersion: this.status.pendingVersion,
        restartRequired: this.status.restartRequired,
      };
    } finally {
      this.status.updateInProgress = false;
    }
  }
}
