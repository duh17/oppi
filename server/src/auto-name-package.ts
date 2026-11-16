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

/** Oppi's copy of the auto-name Pi package: the source tree in development, the build when built. */
export const AUTO_NAME_PACKAGE_DIR = fileURLToPath(
  new URL("../plugins/auto-name", import.meta.url),
);

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

/** Whether a Pi package source is a copy of the auto-name package an Oppi install ships. */
export function isShippedAutoNameSource(source: string): boolean {
  const trimmed = source.replace(/\/+$/, "");
  return SOURCE_SUFFIXES.some((suffix) => trimmed.endsWith(suffix));
}

const isShipped = (entry: PackageEntry): boolean => isShippedAutoNameSource(sourceOf(entry));

/**
 * An entry that cannot load the extension: an `extensions` filter with no pattern that includes
 * anything. Pi loads nothing from it, so it is the same as no entry. Older servers listed the
 * package this way at their first start, and Pi's own toggle leaves a `-index.ts` one.
 */
const isOff = (entry: PackageEntry): boolean =>
  typeof entry !== "string" &&
  Array.isArray(entry.extensions) &&
  entry.extensions.every((pattern) => pattern.startsWith("-") || pattern.startsWith("!"));

/** The package listed on, as the Extensions toggle writes it. */
const enabledEntry = (source: string): PackageEntry => ({ source, extensions: ["+index.ts"] });

/**
 * Pi's global `packages` with the shipped package at `source` turned on or off. On lists it with
 * its extension on; off removes the entry, because an off package is the same as an unlisted
 * one, and Oppi writes Pi's settings for this package only while the owner has it on.
 */
export function withShippedAutoNameEnabled(
  packages: Packages,
  source: string,
  enabled: boolean,
): Packages {
  const others = packages.filter((entry) => sourceOf(entry) !== source);
  return enabled ? [...others, enabledEntry(source)] : others;
}

/**
 * `settings` as the Extensions lists should resolve it: with the shipped package listed off when
 * Pi's settings do not list a copy, so it shows as a row to turn on without Oppi writing anything.
 * The view is for resolving only; writes go through `settings` itself. A user's own
 * `~/.pi/agent/extensions/auto-name` is the same extension, so nothing is offered beside it.
 */
export function offerShippedAutoName(
  settings: SettingsManager,
  agentDir: string,
  packageDir: string = AUTO_NAME_PACKAGE_DIR,
): SettingsManager {
  if (
    settings.getGlobalSettings().packages?.some(isShipped) ||
    !existsSync(join(packageDir, "package.json")) ||
    lstatSync(join(agentDir, "extensions", "auto-name"), { throwIfNoEntry: false })
  ) {
    return settings;
  }
  return new Proxy(settings, {
    get(target, property) {
      if (property === "getGlobalSettings") {
        return () => {
          const global = target.getGlobalSettings();
          return {
            ...global,
            packages: [...(global.packages ?? []), { source: packageDir, extensions: [] }],
          };
        };
      }
      const value: unknown = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

export interface AutoNamePackageOptions {
  dataDir: string;
  /** Pi's agent directory; defaults to Pi's own (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`). */
  agentDir?: string;
  /** The auto-name package of this install. */
  packageDir?: string;
}

/**
 * Keeps an auto-name package the owner turned on working across installs. `oppi serve` calls
 * this at every start, and it writes Pi's global settings only to carry an existing choice:
 *
 * - Pending `autoTitle` carry-over (see `extractAutoTitle`): its model goes to `auto-name.json`
 *   and the package is listed enabled, so a server that titled sessions keeps doing it.
 * - A listed copy of the package whose path is gone (an install that moved or was replaced,
 *   such as a Node version switch) is pointed at this install.
 * - A listed copy that is off loads nothing and is removed: older servers listed the package
 *   off at their first start, unasked. The Extensions lists show the package without an entry
 *   (`offerShippedAutoName`).
 *
 * A user's own `~/.pi/agent/extensions/auto-name` is the same extension, so an entry listed
 * before the user linked their copy is removed at the next start. A failure is logged and
 * retried at the next start, and so is a Pi settings path that refuses writes (a container's
 * read-only mount), which warns instead of failing: neither ever stops the server.
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
        : packages
            .filter((entry) => !(isShipped(entry) && isOff(entry)))
            .map((entry) => repointed(entry, packageDir));
      if (carryover && !userInstall) {
        const index = next.findIndex(isShipped);
        const enabled = enabledEntry(
          index < 0 ? packageDir : sourceOf(next[index] as PackageEntry),
        );
        if (index < 0) next.push(enabled);
        else next[index] = enabled;
      }
      return JSON.stringify(next) === JSON.stringify(packages) ? undefined : next;
    });
    // Nothing reached Pi's settings: the carried model stays pending for a start that can write
    // it, instead of being reported and cleared as if applied.
    if (!written) return;

    if (carryover) {
      clearAutoTitleCarryover(options.dataDir);
      log.info("auto_name_package.carried_over", { model: carryover.model, enabled: !userInstall });
    }
  } catch (error) {
    log.error("auto_name_package.failed", { error: safeErrorMessage(error) });
  }
}

/**
 * Removes every shipped copy of the package from Pi's global settings (`oppi uninstall`), and
 * says whether there was one. `auto-name.json` stays: it may be the user's own model choice.
 */
export async function removeShippedAutoName(agentDir: string = getAgentDir()): Promise<boolean> {
  let removed = false;
  const written = await editPackages(agentDir, (packages) => {
    const next = packages.filter((entry) => !isShipped(entry));
    removed = next.length !== packages.length;
    return removed ? next : undefined;
  });
  if (!written) throw new Error(`${join(agentDir, "settings.json")} cannot be written`);
  return removed;
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
