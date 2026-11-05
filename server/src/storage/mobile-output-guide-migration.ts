import { existsSync, readFileSync, renameSync } from "node:fs";
import { join } from "node:path";

import { isRevision } from "../settings/revision.js";

/**
 * The Mobile Output Guide used to live in its own `settings/mobile-output-guide.json`; it is now
 * `mobileOutputGuide` in config.json beside Server Metrics and Durable Sessions. `ConfigStore`
 * carries the old file's value over once, then renames it to `<name>.migrated`: a rename rather
 * than a delete, so a downgrade or a bad carry-over leaves the old value on disk to recover from.
 * The file is gone from its original path afterwards, which is what makes a second load a no-op.
 */
const legacyPath = (dataDir: string): string =>
  join(dataDir, "settings", "mobile-output-guide.json");

export function hasLegacyMobileOutputGuide(dataDir: string): boolean {
  return existsSync(legacyPath(dataDir));
}

/** The old file's value. Throws when the file is unreadable or not a version 1 record. */
export function readLegacyMobileOutputGuide(dataDir: string): {
  enabled: boolean;
  revision: number;
} {
  const parsed: unknown = JSON.parse(readFileSync(legacyPath(dataDir), "utf8"));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("expected a JSON object");
  }
  const record = parsed as Record<string, unknown>;
  if (record.version !== 1 || typeof record.enabled !== "boolean" || !isRevision(record.revision)) {
    throw new Error("expected version 1 with a boolean enabled and a non-negative revision");
  }
  return { enabled: record.enabled, revision: record.revision };
}

/** Moves the old file aside once its value is in config.json. */
export function retireLegacyMobileOutputGuide(dataDir: string): void {
  renameSync(legacyPath(dataDir), `${legacyPath(dataDir)}.migrated`);
}
