import { randomBytes } from "node:crypto";
import {
  chmodSync,
  constants,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import { writeFileAtomic } from "./atomic-file.js";

const log = createLogger({ base: { component: "auto_title_extension_migration" } });

export const AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY = "auto_title_to_extension_v1";

/** What `autoTitle` leaves for `setUpAutoNamePackage` to apply once Pi's settings can be written. */
export interface AutoTitleCarryover {
  /** `provider/model-id`, the model auto-title ran with. */
  model: string;
  backupPath: string;
}

export type AutoTitleExtraction =
  /** config.json had no `autoTitle`. */
  | { status: "none" }
  /** `autoTitle` was off, or on without a model (which titled nothing); it is dropped. */
  | { status: "dropped"; backupPath: string }
  /** `autoTitle` was on with a model: it is dropped and its model waits in the carry-over file. */
  | { status: "carried"; backupPath: string; model: string };

/** Whether config.json still has `autoTitle`: the cheap check before taking the config lock. */
export function hasAutoTitle(dataDir: string): boolean {
  const config = readConfigObject(join(dataDir, "config.json"));
  return config !== undefined && "autoTitle" in config;
}

/**
 * The server no longer titles sessions itself: the `auto-name` Pi extension does. The config
 * store drops keys it no longer knows, so this runs before it loads config.json, wherever a
 * `ConfigStore` is built (`oppi config get` and `oppi pair` before the first `oppi serve` too):
 *
 * 1. Copy config.json to `$dataDir/backups/` (named by the migration key). A failed copy throws,
 *    and the config store does not load: `autoTitle` is never dropped without a backup.
 * 2. `autoTitle` on with a model titled sessions: keep its model in the carry-over file.
 *    Anything else titled nothing, so there is nothing to carry.
 * 3. Remove `autoTitle` from config.json.
 *
 * Callers hold the config lock (`ConfigStore` does), so a server and a CLI command starting
 * together cannot both rewrite config.json, and neither overwrites a save in flight.
 *
 * Writing Pi's settings is asynchronous, so the next `oppi serve` applies the carry-over
 * (`setUpAutoNamePackage`). Removing `autoTitle` is what marks this step done: a second call
 * finds nothing.
 */
export function extractAutoTitle(dataDir: string): AutoTitleExtraction {
  const configPath = join(dataDir, "config.json");
  const config = readConfigObject(configPath);
  if (!config || !("autoTitle" in config)) return { status: "none" };

  const backupPath = backUp(configPath, dataDir);
  const autoTitle: unknown = config.autoTitle;
  const settings = autoTitle !== null && typeof autoTitle === "object" ? autoTitle : {};
  const rawModel = (settings as { model?: unknown }).model;
  const model = typeof rawModel === "string" ? rawModel.trim() : "";
  const carried = (settings as { enabled?: unknown }).enabled === true && model.length > 0;

  // The carry-over first: a crash between the two writes repeats this step, which finds
  // `autoTitle` still there, rather than losing the model.
  if (carried) writeCarryover(dataDir, { model, backupPath });
  delete config.autoTitle;
  // Durable, as ConfigStore's own save is: the carry-over above must not outlive a config that
  // still has `autoTitle`, nor the reverse.
  writeFileAtomic(configPath, JSON.stringify(config, null, 2), { durable: true });
  log.info("auto_title_extension_migration.extracted", {
    key: AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY,
    backupPath,
    carried,
    ...(carried ? { model } : {}),
  });
  return carried ? { status: "carried", backupPath, model } : { status: "dropped", backupPath };
}

const carryoverPath = (dataDir: string): string =>
  join(dataDir, `${AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY}.pending.json`);

function writeCarryover(dataDir: string, carryover: AutoTitleCarryover): void {
  // Durable: this is the only copy of the model once the config rewrite below drops it.
  writeFileAtomic(carryoverPath(dataDir), `${JSON.stringify(carryover, null, 2)}\n`, {
    durable: true,
  });
}

/** The pending carry-over, when `autoTitle` was on with a model and no serve has applied it yet. */
export function readAutoTitleCarryover(dataDir: string): AutoTitleCarryover | undefined {
  try {
    const parsed = JSON.parse(
      readFileSync(carryoverPath(dataDir), "utf8"),
    ) as Partial<AutoTitleCarryover>;
    return typeof parsed.model === "string" && typeof parsed.backupPath === "string"
      ? { model: parsed.model, backupPath: parsed.backupPath }
      : undefined;
  } catch {
    return undefined;
  }
}

export function clearAutoTitleCarryover(dataDir: string): void {
  rmSync(carryoverPath(dataDir), { force: true });
}

function readConfigObject(configPath: string): Record<string, unknown> | undefined {
  if (!existsSync(configPath)) return undefined;
  try {
    const parsed: unknown = JSON.parse(readFileSync(configPath, "utf8"));
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : undefined;
  } catch {
    // The config store reports an unreadable config.
    return undefined;
  }
}

/** A private copy of config.json (it holds auth tokens) that no other start's backup can be replaced by. */
function backUp(configPath: string, dataDir: string): string {
  const backupDir = join(dataDir, "backups");
  const backupPath = join(
    backupDir,
    `config-pre-${AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY}-${Date.now()}-${randomBytes(4).toString("hex")}.json`,
  );
  try {
    mkdirSync(backupDir, { recursive: true, mode: 0o700 });
    copyFileSync(configPath, backupPath, constants.COPYFILE_EXCL);
    chmodSync(backupPath, 0o600);
  } catch (error) {
    throw new Error(
      `config backup before ${AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY} failed; refusing to load the config: ${
        error instanceof Error ? error.message : String(error)
      }`,
      { cause: error },
    );
  }
  return backupPath;
}
