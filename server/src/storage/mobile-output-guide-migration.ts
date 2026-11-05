import { existsSync, readFileSync, renameSync } from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import { isRevision } from "../settings/revision.js";
import type { ServerConfig } from "../types.js";

const log = createLogger({ base: { component: "mobile_output_guide_migration" } });

/**
 * The Mobile Output Guide used to live in its own `settings/mobile-output-guide.json`; it is now
 * `mobileOutputGuide` in config.json beside Server Metrics and Durable Sessions. `ConfigStore`
 * carries the old file's value over once, then renames it to `<name>.migrated`: a rename rather
 * than a delete, so a downgrade or a bad carry-over leaves the old value on disk to recover from.
 * The file is gone from its original path afterwards, which is what makes a second load a no-op.
 */
const legacyPath = (dataDir: string): string =>
  join(dataDir, "settings", "mobile-output-guide.json");

function hasLegacyMobileOutputGuide(dataDir: string): boolean {
  return existsSync(legacyPath(dataDir));
}

/** The old file's value. Throws when the file is unreadable or not a version 1 record. */
function readLegacyMobileOutputGuide(dataDir: string): {
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

/**
 * Moves the old file aside once its value is in config.json. An earlier `.migrated` copy is kept
 * (this one gets a timestamp suffix), and a file that is already gone counts as migrated.
 */
function retireLegacyMobileOutputGuide(dataDir: string): void {
  const from = legacyPath(dataDir);
  const kept = `${from}.migrated`;
  try {
    renameSync(from, existsSync(kept) ? `${kept}.${Date.now()}` : kept);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

/**
 * Carries the old file into config.json once; `ConfigStore` calls it after its load, passing its
 * locked `mutate`. It writes config.json, so it waits for a config whose fields all loaded:
 * rewriting one with invalid operator values would replace them with defaults. Invalid fields, an
 * unreadable old file, or a failed write never block startup: the file stays where it is, a
 * warning says why, and the guide reads as off. The next ConfigStore start retries, and retires
 * the file once config.json holds a value.
 */
export function carryOverLegacyMobileOutputGuide(
  dataDir: string,
  configHasFieldErrors: boolean,
  mutate: (mutator: (latest: ServerConfig) => Partial<ServerConfig>) => unknown,
): void {
  if (!hasLegacyMobileOutputGuide(dataDir)) return;
  if (configHasFieldErrors) {
    log.warn("mobile_output_guide_migration.skipped", {
      reason:
        "config.json has invalid fields; fix them (see config_store.field.invalid) to migrate",
    });
    return;
  }
  try {
    mutate((latest) =>
      latest.mobileOutputGuide ? {} : { mobileOutputGuide: readLegacyMobileOutputGuide(dataDir) },
    );
    retireLegacyMobileOutputGuide(dataDir);
  } catch (error) {
    log.warn("mobile_output_guide_migration.failed", {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
