import { randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  fchmodSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import {
  DEFAULT_OPPI_EXTENSION_SETTINGS,
  OPPI_EXTENSION_SETTINGS_VERSION,
  OppiExtensionSettingsValidationError,
  boundOppiExtensionSettingsError,
  freezeOppiExtensionSettingsSnapshot,
  type OppiExtensionSettingsReader,
  type OppiExtensionSettingsReplacement,
  type OppiExtensionSettingsSnapshot,
  validateOppiExtensionSettingsBaseRevision,
  validateOppiExtensionSettingsRecord,
  validateOppiExtensionSettingsReplacement,
} from "../oppi-extension-settings.js";

export interface OppiExtensionSettingsAtomicOperations {
  write(fd: number, contents: string): void;
  fsync(fd: number): void;
  rename(from: string, to: string): void;
}

export interface OppiExtensionSettingsStoreOptions {
  operations?: Partial<OppiExtensionSettingsAtomicOperations>;
}

export type OppiExtensionSettingsReplaceResult =
  | { readonly ok: true; readonly current: OppiExtensionSettingsSnapshot }
  | {
      readonly ok: false;
      readonly reason: "revision_conflict";
      readonly current: OppiExtensionSettingsSnapshot;
    };

const DEFAULT_OPERATIONS: OppiExtensionSettingsAtomicOperations = {
  write(fd, contents) {
    writeFileSync(fd, contents, { encoding: "utf8" });
  },
  fsync(fd) {
    fsyncSync(fd);
  },
  rename(from, to) {
    renameSync(from, to);
  },
};

export class OppiExtensionSettingsPersistenceError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "OppiExtensionSettingsPersistenceError";
  }
}

export class OppiExtensionSettingsStore implements OppiExtensionSettingsReader {
  private readonly extensionsDir: string;
  private readonly settingsPath: string;
  private readonly operations: OppiExtensionSettingsAtomicOperations;
  private snapshot: OppiExtensionSettingsSnapshot;
  private loadError: string | undefined;

  constructor(dataDir: string, options: OppiExtensionSettingsStoreOptions = {}) {
    this.extensionsDir = join(dataDir, "extensions");
    this.settingsPath = join(this.extensionsDir, "oppi.json");
    this.operations = { ...DEFAULT_OPERATIONS, ...options.operations };
    const loaded = this.load();
    this.snapshot = loaded.snapshot;
    this.loadError = loaded.error;
  }

  get(): OppiExtensionSettingsSnapshot {
    return freezeOppiExtensionSettingsSnapshot(this.snapshot);
  }

  getLoadError(): string | undefined {
    return this.loadError;
  }

  replace(baseRevision: unknown, desired: unknown): OppiExtensionSettingsReplaceResult {
    const validatedBaseRevision = validateOppiExtensionSettingsBaseRevision(baseRevision);
    const replacement = validateOppiExtensionSettingsReplacement(desired);
    if (validatedBaseRevision !== this.snapshot.revision) {
      return Object.freeze({
        ok: false,
        reason: "revision_conflict" as const,
        current: this.get(),
      });
    }

    const next = freezeOppiExtensionSettingsSnapshot({
      enabled: replacement.enabled,
      approvalPolicy: replacement.approvalPolicy,
      revision: this.snapshot.revision + 1,
    });
    this.persist(next);
    this.snapshot = next;
    this.loadError = undefined;
    return Object.freeze({ ok: true, current: this.get() });
  }

  private load(): { snapshot: OppiExtensionSettingsSnapshot; error?: string } {
    if (!existsSync(this.settingsPath)) {
      return { snapshot: DEFAULT_OPPI_EXTENSION_SETTINGS };
    }

    try {
      const parsed = JSON.parse(readFileSync(this.settingsPath, "utf8")) as unknown;
      const record = validateOppiExtensionSettingsRecord(parsed);
      return { snapshot: freezeOppiExtensionSettingsSnapshot(record) };
    } catch (error: unknown) {
      return {
        snapshot: DEFAULT_OPPI_EXTENSION_SETTINGS,
        error: boundOppiExtensionSettingsError(
          new Error(
            `Oppi extension settings load failed: ${boundOppiExtensionSettingsError(error)}`,
          ),
        ),
      };
    }
  }

  private ensureExtensionsDirectory(): void {
    if (existsSync(this.extensionsDir)) {
      const stat = lstatSync(this.extensionsDir);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new OppiExtensionSettingsPersistenceError(
          "Oppi extension settings directory is not a real directory",
        );
      }
      chmodSync(this.extensionsDir, 0o700);
      return;
    }
    mkdirSync(this.extensionsDir, { recursive: true, mode: 0o700 });
    chmodSync(this.extensionsDir, 0o700);
  }

  private persist(next: OppiExtensionSettingsSnapshot): void {
    let tempPath: string | undefined;
    let fd: number | undefined;
    try {
      this.ensureExtensionsDirectory();
      tempPath = join(this.extensionsDir, `.oppi.json.${process.pid}.${randomUUID()}.tmp`);
      fd = openSync(tempPath, "wx", 0o600);
      fchmodSync(fd, 0o600);
      const record = {
        version: OPPI_EXTENSION_SETTINGS_VERSION,
        revision: next.revision,
        enabled: next.enabled,
        approvalPolicy: next.approvalPolicy,
      };
      this.operations.write(fd, `${JSON.stringify(record, null, 2)}\n`);
      this.operations.fsync(fd);
      closeSync(fd);
      fd = undefined;
      this.operations.rename(tempPath, this.settingsPath);
      tempPath = undefined;
      this.fsyncDirectoryBestEffort();
    } catch (error: unknown) {
      throw new OppiExtensionSettingsPersistenceError(
        `Failed to persist Oppi extension settings: ${boundOppiExtensionSettingsError(error)}`,
        { cause: error },
      );
    } finally {
      if (fd !== undefined) {
        try {
          closeSync(fd);
        } catch {
          // The original persistence error remains authoritative.
        }
      }
      if (tempPath !== undefined) {
        try {
          rmSync(tempPath, { force: true });
        } catch {
          // Cleanup failure must not hide the persistence failure.
        }
      }
    }
  }

  private fsyncDirectoryBestEffort(): void {
    let directoryFd: number | undefined;
    try {
      directoryFd = openSync(this.extensionsDir, "r");
      fsyncSync(directoryFd);
    } catch {
      // Directory fsync is unavailable on some supported filesystems. The file
      // was already fsynced and atomically renamed in the same directory.
    } finally {
      if (directoryFd !== undefined) {
        try {
          closeSync(directoryFd);
        } catch {
          // Best effort only.
        }
      }
    }
  }
}

export { OppiExtensionSettingsValidationError };
export type { OppiExtensionSettingsReplacement };
