import { existsSync, lstatSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAgentDir, SettingsManager } from "@earendil-works/pi-coding-agent";

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  clearAutoTitleCarryover,
  readAutoTitleCarryover,
} from "./storage/auto-title-extension-migration.js";

const log = createLogger({ base: { component: "auto_name_package" } });

/** A write the file system refused: the step stays pending, and the `once` caller is not told. */
const UNWRITTEN_SETTINGS = Symbol("auto_name_package.unwritten_settings");

/** Oppi's copy of the auto-name Pi package: the source tree in development, the build when built. */
export const AUTO_NAME_PACKAGE_DIR = fileURLToPath(
  new URL("../plugins/auto-name", import.meta.url),
);

/** Ledger key (`app_state_migrations`): the shipped package was offered in Pi's settings. */
export const AUTO_NAME_PACKAGE_REGISTERED_KEY = "auto_name_package_registered_v1";

type Packages = ReturnType<SettingsManager["getPackages"]>;
type PackageEntry = Packages[number];

/**
 * Where a shipped install keeps the package, whatever the prefix of the install: in its plugins,
 * or in `extensions/pi/` before the package moved there. An entry of an older install is gone
 * once the install updates, so `repointed` moves it here with its filter.
 */
const SOURCE_SUFFIXES = ["/plugins/auto-name", "/extensions/pi/auto-name"];

const sourceOf = (entry: PackageEntry): string =>
  typeof entry === "string" ? entry : entry.source;

const isShipped = (entry: PackageEntry): boolean => {
  const source = sourceOf(entry).replace(/\/+$/, "");
  return SOURCE_SUFFIXES.some((suffix) => source.endsWith(suffix));
};

/**
 * The package as Pi's settings list it. Off is an empty `extensions` filter, which keeps the
 * package in the Extensions list as a disabled row; on names its entry, as the Extensions toggle
 * writes it.
 */
function entryFor(source: string, enabled: boolean): PackageEntry {
  return { source, extensions: enabled ? ["+index.ts"] : [] };
}

export interface AutoNamePackageOptions {
  dataDir: string;
  /** Runs `run` once per data directory under `key` and says whether it ran (`Storage.runMigrationOnce`). */
  once: (key: string, run: () => Promise<void>) => Promise<boolean>;
  /** Pi's agent directory; defaults to Pi's own (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`). */
  agentDir?: string;
  /** The auto-name package of this install. */
  packageDir?: string;
}

/**
 * Keeps the shipped auto-name package in Pi's global settings, so it shows in the Extensions
 * list and the app can turn it on. `oppi serve` calls this at every start:
 *
 * - Pending `autoTitle` carry-over (see `extractAutoTitle`): its model goes to `auto-name.json`
 *   and the package is listed enabled, so a server that titled sessions keeps doing it.
 * - A listed copy of the package whose path is gone (an install that moved or was replaced,
 *   such as a Node version switch) is pointed at this install, keeping its on or off filter.
 * - Once per data directory, a package that is not listed yet is listed off. Deleting the entry
 *   brings nothing back: the ledger remembers the offer.
 *
 * A user's own `~/.pi/agent/extensions/auto-name` is the same extension, so the package is
 * not listed beside it, and an entry listed before the user linked their copy is removed at the
 * next start. A failure is logged and retried at the next start, and so is a Pi settings path
 * that refuses writes (a container's read-only mount), which warns instead of failing: neither
 * ever stops the server.
 */
export async function setUpAutoNamePackage(options: AutoNamePackageOptions): Promise<void> {
  const agentDir = options.agentDir ?? getAgentDir();
  const packageDir = options.packageDir ?? AUTO_NAME_PACKAGE_DIR;
  try {
    if (!existsSync(join(packageDir, "package.json"))) {
      log.warn("auto_name_package.missing", { packageDir });
      return;
    }
    const userInstall = lstatSync(join(agentDir, "extensions", "auto-name"), {
      throwIfNoEntry: false,
    });
    const carryover = readAutoTitleCarryover(options.dataDir);
    if (carryover) writeModel(agentDir, carryover.model);

    const written = await editPackages(agentDir, (packages) => {
      // A user's own copy and the shipped one are the same extension: one copy, theirs.
      const next = userInstall
        ? packages.filter((entry) => !isShipped(entry))
        : packages.map((entry) => repointed(entry, packageDir));
      if (carryover && !userInstall) {
        const index = next.findIndex(isShipped);
        const enabled = entryFor(
          index < 0 ? packageDir : sourceOf(next[index] as PackageEntry),
          true,
        );
        if (index < 0) next.push(enabled);
        else next[index] = enabled;
      }
      return JSON.stringify(next) === JSON.stringify(packages) ? undefined : next;
    });
    // Nothing reached Pi's settings: the carried model and the one-time offer stay pending for a
    // start that can write them, instead of being reported and cleared as if applied.
    if (!written) return;

    if (carryover) {
      clearAutoTitleCarryover(options.dataDir);
      log.info("auto_name_package.carried_over", { model: carryover.model, enabled: !userInstall });
    }

    if (userInstall) return;
    // The ledger records this step after a `run` that did not throw, so an offer whose write never
    // landed throws to stay pending; only that failure is swallowed, and it is not logged as one.
    const offered = await options
      .once(AUTO_NAME_PACKAGE_REGISTERED_KEY, async () => {
        const wrote = await editPackages(agentDir, (packages) =>
          packages.some(isShipped) ? undefined : [...packages, entryFor(packageDir, false)],
        );
        if (!wrote) throw UNWRITTEN_SETTINGS;
      })
      .catch((error: unknown) => {
        if (error === UNWRITTEN_SETTINGS) return false;
        throw error;
      });
    if (offered) log.info("auto_name_package.offered", { packageDir });
  } catch (error) {
    log.error("auto_name_package.failed", { error: safeErrorMessage(error) });
  }
}

/** `entry` with its path replaced by `packageDir` when it is a shipped copy that no longer exists. */
function repointed(entry: PackageEntry, packageDir: string): PackageEntry {
  if (!isShipped(entry) || sourceOf(entry) === packageDir || existsSync(sourceOf(entry))) {
    return entry;
  }
  return typeof entry === "string" ? packageDir : { ...entry, source: packageDir };
}

/** The model the old setting named; a file already there is the user's choice and stays. */
function writeModel(agentDir: string, model: string): void {
  mkdirSync(agentDir, { recursive: true });
  const path = join(agentDir, "auto-name.json");
  if (existsSync(path)) return;
  writeFileSync(path, `${JSON.stringify({ model }, null, 2)}\n`, { flag: "wx" });
}

/**
 * Rewrites Pi's global `packages` through its settings manager, when `edit` returns a new list.
 * Says whether Pi's settings ended up saying what `edit` asked for.
 */
async function editPackages(
  agentDir: string,
  edit: (packages: Packages) => Packages | undefined,
): Promise<boolean> {
  const settings = SettingsManager.create(agentDir, agentDir, { projectTrusted: false });
  reportSettingsErrors(settings.drainErrors(), "read");
  const next = edit([...(settings.getGlobalSettings().packages ?? [])]);
  // Already what `edit` would write, so a file that cannot be written costs nothing.
  if (!next) return true;
  settings.setPackages(next);
  await settings.flush();
  return reportSettingsErrors(settings.drainErrors(), "write");
}

/** Codes of a write the path refused, however the server asked: the deployment's choice. */
const UNWRITABLE_CODES = new Set(["EROFS", "EACCES", "EPERM"]);

/**
 * Reports Pi settings errors and says whether the settings were written: `true` when there were
 * none, `false` for a write the file system refused, and throws for anything else.
 *
 * A write the file system refused as unwritable is not a failure: Pi's settings on a read-only or
 * unwritable path is how a deployment mounts it (the review compose stack binds `settings.json`
 * read-only), so that is one warning naming the operation and code, and the caller leaves its step
 * for a start that can write.
 */
function reportSettingsErrors(errors: Array<{ error: Error }>, operation: string): boolean {
  if (errors.length === 0) return true;
  const codes = errors.map(({ error }) => (error as NodeJS.ErrnoException).code);
  const named = codes.filter((code): code is string => code !== undefined);
  if (
    operation === "write" &&
    named.length === codes.length &&
    named.every((code) => UNWRITABLE_CODES.has(code))
  ) {
    log.warn("auto_name_package.settings_unwritable", {
      operation,
      code: [...new Set(named)].join(","),
    });
    return false;
  }
  throw new Error(
    `Pi settings ${operation} failed: ${errors.map((e) => e.error.message).join("; ")}`,
  );
}
