/* Detect whether this process is the globally installed npm package. */
import { execFile, execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import type { ServerInstallKind } from "./types/server-update.js";
import { getPackageInfo, packageRootDir } from "./version.js";

const execFileAsync = promisify(execFile);

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
): Promise<InstallKind> {
  try {
    const { stdout } = await execFileAsync("npm", ["root", "-g"], {
      encoding: "utf-8",
      timeout: 8_000,
      maxBuffer: 64 * 1024,
    });
    return installKind(
      packageName,
      classifyGlobalEntry(packageName, stdout.trim(), packageDir),
      packageDir,
    );
  } catch {
    return installKind(packageName, "other", packageDir);
  }
}
