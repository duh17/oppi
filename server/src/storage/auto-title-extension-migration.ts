import { randomBytes } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAgentDir } from "@earendil-works/pi-coding-agent";

import { createLogger } from "../logger.js";

const log = createLogger({ base: { component: "auto_title_extension_migration" } });

export const AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY = "auto_title_to_extension_v1";

/** Oppi's copy of the auto-name Pi package: the source tree in development, the build when built. */
const AUTO_NAME_PACKAGE_DIR = fileURLToPath(
  new URL("../../extensions/pi/auto-name", import.meta.url),
);

export interface AutoTitleMigrationOptions {
  dataDir: string;
  /** Pi's agent directory; defaults to Pi's own (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`). */
  agentDir?: string;
  /** The auto-name package to link; defaults to the one in this install. */
  packageDir?: string;
}

export type AutoTitleMigrationResult =
  /** config.json had no `autoTitle`. */
  | { status: "none" }
  /** `autoTitle` was off, or on without a model (which titled nothing); it is dropped. */
  | { status: "dropped"; backupPath: string }
  /** `autoTitle` was on with a model: the extension is installed with that model, and it is dropped. */
  | { status: "enabled"; backupPath: string; model: string }
  /** The migration changed nothing but the backup; the config store then drops the unknown key. */
  | { status: "failed"; error: string; backupPath?: string };

/**
 * The server no longer titles sessions itself: the `auto-name` Pi extension does. Before the
 * config loads, turn a server's `autoTitle` into that extension's setup, then remove it:
 *
 * - `enabled: true` with a `model`: write `<agentDir>/auto-name.json` (unless one exists) and link
 *   this install's package into `<agentDir>/extensions/auto-name` (unless something is there), so
 *   Pi loads it for every session, durable ones included. Pi's settings are not edited.
 * - Anything else titled nothing, so there is nothing to carry over.
 *
 * Keyed by `autoTitle` itself (the migration ends by removing it, so a second start finds
 * nothing) and named by `AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY` in its backup and log. The
 * backup copy of config.json comes first; if any step fails the migration leaves the config as it
 * was and the server starts without naming, with the backup path in the log.
 */
export function runAutoTitleToExtensionMigration(
  options: AutoTitleMigrationOptions,
): AutoTitleMigrationResult {
  const configPath = join(options.dataDir, "config.json");
  const config = readConfigObject(configPath);
  if (!config || !("autoTitle" in config)) return { status: "none" };

  let backupPath: string | undefined;
  try {
    backupPath = backUp(configPath, options.dataDir);
    const autoTitle: unknown = config.autoTitle;
    const settings = autoTitle !== null && typeof autoTitle === "object" ? autoTitle : {};
    const rawModel = (settings as { model?: unknown }).model;
    const model = typeof rawModel === "string" ? rawModel.trim() : "";
    const enabled = (settings as { enabled?: unknown }).enabled === true && model.length > 0;
    if (enabled) {
      installExtension({
        agentDir: options.agentDir ?? getAgentDir(),
        packageDir: options.packageDir ?? AUTO_NAME_PACKAGE_DIR,
        model,
      });
    }
    delete config.autoTitle;
    writeConfig(configPath, options.dataDir, config);
    log.info("auto_title_extension_migration.completed", {
      key: AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY,
      backupPath,
      enabled,
      ...(enabled ? { model } : {}),
    });
    return enabled ? { status: "enabled", backupPath, model } : { status: "dropped", backupPath };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log.error("auto_title_extension_migration.failed", {
      key: AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY,
      error: message,
      ...(backupPath ? { backupPath } : {}),
    });
    return { status: "failed", error: message, ...(backupPath ? { backupPath } : {}) };
  }
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
      `config backup before ${AUTO_TITLE_TO_EXTENSION_MIGRATION_KEY} failed; refusing to migrate: ${
        error instanceof Error ? error.message : String(error)
      }`,
      { cause: error },
    );
  }
  return backupPath;
}

function installExtension(options: { agentDir: string; packageDir: string; model: string }): void {
  if (!existsSync(join(options.packageDir, "package.json"))) {
    throw new Error(`the auto-name package is missing from this install: ${options.packageDir}`);
  }
  const extensionsDir = join(options.agentDir, "extensions");
  const link = join(extensionsDir, "auto-name");
  // A name or link already there is the user's own install of it: keep it, and its settings.
  const linked = lstatSync(link, { throwIfNoEntry: false }) !== undefined;
  const configFile = join(options.agentDir, "auto-name.json");
  const configured = existsSync(configFile);

  mkdirSync(extensionsDir, { recursive: true });
  if (!configured) {
    writeFileSync(configFile, `${JSON.stringify({ model: options.model }, null, 2)}\n`, {
      flag: "wx",
    });
  }
  if (!linked) symlinkSync(options.packageDir, link, "dir");
}

function writeConfig(configPath: string, dataDir: string, config: Record<string, unknown>): void {
  const temporaryPath = join(
    dataDir,
    `.config.${process.pid}.${randomBytes(4).toString("hex")}.tmp`,
  );
  writeFileSync(temporaryPath, JSON.stringify(config, null, 2), { flag: "wx", mode: 0o600 });
  renameSync(temporaryPath, configPath);
}
