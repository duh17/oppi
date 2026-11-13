/* Detect how this process was installed: npm global, source link, install.sh, or other. */
import { execFile, execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join, sep } from "node:path";

import type { ServerInstallKind } from "./types/server-update.js";
import { getPackageInfo, packageRootDir } from "./version.js";

/** Script the app's source-link update runs; it keeps dist on a failed compile. */
export const SOURCE_BUILD_SCRIPT = "build:in-place";

/** A git checkout the app can rebuild: sources plus the in-place build script. */
function isBuildableCheckout(packageDir: string): boolean {
  try {
    const raw = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf-8")) as {
      scripts?: Record<string, unknown>;
    };
    return (
      typeof raw.scripts?.[SOURCE_BUILD_SCRIPT] === "string" && existsSync(join(packageDir, "src"))
    );
  } catch {
    return false;
  }
}

/**
 * `npm install -g` from the registry writes a directory into the global root;
 * `npm link` writes a symlink to the checkout, and updating from npm would
 * replace it. Other symlinks (a folder install of a packed package, a store
 * link) cannot be rebuilt or safely replaced, so they are `other`.
 */
function classifyGlobalEntry(
  packageName: string,
  globalRoot: string,
  packageDir: string | undefined,
): ServerInstallKind {
  try {
    const entry = join(globalRoot, packageName);
    if (!packageDir || realpathSync(packageDir) !== realpathSync(entry)) return "other";
    if (!lstatSync(entry).isSymbolicLink()) return "npm-global";
    return isBuildableCheckout(packageDir) ? "source-link" : "other";
  } catch {
    return "other";
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function manualUpdateCommand(packageName: string, version = "latest"): string {
  return `npm install -g ${packageName}@${version}`;
}

/** Rerunning install.sh upgrades a managed install in place and restarts its service. */
export const MANAGED_UPDATE_COMMAND =
  "curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | sh";

/**
 * install.sh puts each version in its own npm prefix under
 * ~/.oppi/install/releases/<version>. `npm install -g` would add a second copy
 * the service never runs, so these installs get their own kind.
 */
export function isManagedInstall(
  packageDir: string | undefined,
  home: string = homedir(),
): boolean {
  if (!packageDir) return false;
  try {
    const releases = realpathSync(join(home, ".oppi", "install", "releases"));
    return realpathSync(packageDir).startsWith(releases + sep);
  } catch {
    return false;
  }
}

export type InstallKind = {
  kind: ServerInstallKind;
  /** The app can update this install: npm-global installs, source-link rebuilds. */
  updatable: boolean;
  manualCommand: string;
  /** Install directory; source-link updates build here. */
  packageDir?: string;
};

function installKind(
  packageName: string,
  kind: ServerInstallKind,
  packageDir: string | undefined,
): InstallKind {
  if (kind === "source-link" && packageDir) {
    return {
      kind,
      updatable: true,
      manualCommand: `cd ${shellQuote(packageDir)} && npm run ${SOURCE_BUILD_SCRIPT}`,
      packageDir,
    };
  }
  if (kind === "managed") {
    return { kind, updatable: false, manualCommand: MANAGED_UPDATE_COMMAND, packageDir };
  }
  return {
    kind: kind === "npm-global" ? kind : "other",
    updatable: kind === "npm-global",
    manualCommand: manualUpdateCommand(packageName),
    packageDir,
  };
}

/** CLI-only synchronous lookup; server requests use resolveInstallKindAsync. */
export function resolveInstallKind(packageName = getPackageInfo().name): InstallKind {
  const packageDir = packageRootDir();
  if (isManagedInstall(packageDir)) return installKind(packageName, "managed", packageDir);
  try {
    const globalRoot = execFileSync("npm", ["root", "-g"], {
      encoding: "utf-8",
      timeout: 8_000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return installKind(
      packageName,
      classifyGlobalEntry(packageName, globalRoot, packageDir),
      packageDir,
    );
  } catch {
    return installKind(packageName, "other", packageDir);
  }
}

export async function resolveInstallKindAsync(
  packageName = getPackageInfo().name,
  packageDir = packageRootDir(),
  signal?: AbortSignal,
): Promise<InstallKind> {
  if (isManagedInstall(packageDir)) return installKind(packageName, "managed", packageDir);
  try {
    const stdout = await npmRootGlobal(signal);
    return installKind(
      packageName,
      classifyGlobalEntry(packageName, stdout.trim(), packageDir),
      packageDir,
    );
  } catch {
    return installKind(packageName, "other", packageDir);
  }
}

/**
 * `npm root -g`, killed when `signal` aborts. Settles after the process exits
 * (execFile's callback runs on close), so an aborted caller knows npm is gone.
 */
function npmRootGlobal(signal?: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const child = execFile(
      "npm",
      ["root", "-g"],
      { encoding: "utf-8", timeout: 8_000, maxBuffer: 64 * 1024 },
      (error, stdout) => (error ? reject(error) : resolve(stdout)),
    );
    signal?.addEventListener("abort", () => child.kill(), { once: true });
  });
}
