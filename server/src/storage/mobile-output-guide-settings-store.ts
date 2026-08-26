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
  DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
  MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION,
  boundMobileOutputGuideSettingsError,
  freezeMobileOutputGuideSettingsSnapshot,
  type MobileOutputGuideSettingsReader,
  type MobileOutputGuideSettingsSnapshot,
  validateMobileOutputGuideSettingsBaseRevision,
  validateMobileOutputGuideSettingsRecord,
  validateMobileOutputGuideSettingsReplacement,
} from "../mobile-output-guide-settings.js";

export type MobileOutputGuideSettingsReplaceResult =
  | { readonly ok: true; readonly current: MobileOutputGuideSettingsSnapshot }
  | {
      readonly ok: false;
      readonly reason: "revision_conflict";
      readonly current: MobileOutputGuideSettingsSnapshot;
    };

export class MobileOutputGuideSettingsPersistenceError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "MobileOutputGuideSettingsPersistenceError";
  }
}

export class MobileOutputGuideSettingsStore implements MobileOutputGuideSettingsReader {
  private readonly settingsDir: string;
  private readonly settingsPath: string;
  private snapshot: MobileOutputGuideSettingsSnapshot;
  private loadError: string | undefined;

  constructor(private readonly dataDir: string) {
    this.settingsDir = join(dataDir, "settings");
    this.settingsPath = join(this.settingsDir, "mobile-output-guide.json");
    const loaded = this.load();
    this.snapshot = loaded.snapshot;
    this.loadError = loaded.error;
  }

  get(): MobileOutputGuideSettingsSnapshot {
    return freezeMobileOutputGuideSettingsSnapshot(this.snapshot);
  }

  getLoadError(): string | undefined {
    return this.loadError;
  }

  replace(baseRevision: unknown, desired: unknown): MobileOutputGuideSettingsReplaceResult {
    const validatedBaseRevision = validateMobileOutputGuideSettingsBaseRevision(baseRevision);
    const replacement = validateMobileOutputGuideSettingsReplacement(desired);
    if (validatedBaseRevision !== this.snapshot.revision) {
      return Object.freeze({
        ok: false,
        reason: "revision_conflict" as const,
        current: this.get(),
      });
    }
    const next = freezeMobileOutputGuideSettingsSnapshot({
      enabled: replacement.enabled,
      revision: this.snapshot.revision + 1,
    });
    this.persist(next);
    this.snapshot = next;
    this.loadError = undefined;
    return Object.freeze({ ok: true, current: this.get() });
  }

  private load(): { snapshot: MobileOutputGuideSettingsSnapshot; error?: string } {
    if (existsSync(this.settingsPath)) {
      try {
        const parsed = JSON.parse(readFileSync(this.settingsPath, "utf8")) as unknown;
        return {
          snapshot: freezeMobileOutputGuideSettingsSnapshot(
            validateMobileOutputGuideSettingsRecord(parsed),
          ),
        };
      } catch (error) {
        return {
          snapshot: DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
          error: boundMobileOutputGuideSettingsError(error),
        };
      }
    }

    return { snapshot: DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS };
  }

  private persist(next: MobileOutputGuideSettingsSnapshot): void {
    let temporaryPath: string | undefined;
    let fd: number | undefined;
    try {
      this.ensureSettingsDirectory();
      temporaryPath = join(
        this.settingsDir,
        `.mobile-output-guide.json.${process.pid}.${randomUUID()}.tmp`,
      );
      fd = openSync(temporaryPath, "wx", 0o600);
      fchmodSync(fd, 0o600);
      writeFileSync(
        fd,
        `${JSON.stringify(
          {
            version: MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION,
            enabled: next.enabled,
            revision: next.revision,
          },
          null,
          2,
        )}\n`,
        "utf8",
      );
      fsyncSync(fd);
      closeSync(fd);
      fd = undefined;
      renameSync(temporaryPath, this.settingsPath);
      temporaryPath = undefined;
      this.fsyncDirectoryBestEffort();
    } catch (error) {
      throw new MobileOutputGuideSettingsPersistenceError(
        `Failed to persist Mobile Output Guide settings: ${boundMobileOutputGuideSettingsError(error)}`,
        { cause: error },
      );
    } finally {
      if (fd !== undefined) {
        try {
          closeSync(fd);
        } catch {}
      }
      if (temporaryPath !== undefined) {
        try {
          rmSync(temporaryPath, { force: true });
        } catch {}
      }
    }
  }

  private ensureSettingsDirectory(): void {
    if (existsSync(this.settingsDir)) {
      const stat = lstatSync(this.settingsDir);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new MobileOutputGuideSettingsPersistenceError(
          "Mobile Output Guide settings directory is not a real directory",
        );
      }
      chmodSync(this.settingsDir, 0o700);
      return;
    }
    mkdirSync(this.settingsDir, { recursive: true, mode: 0o700 });
    chmodSync(this.settingsDir, 0o700);
  }

  private fsyncDirectoryBestEffort(): void {
    let fd: number | undefined;
    try {
      fd = openSync(this.settingsDir, "r");
      fsyncSync(fd);
    } catch {
      // The file was already fsynced and atomically renamed in the same directory.
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
  }
}
