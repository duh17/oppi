/* Detect whether this process is the globally installed npm package. */
import { execFile, execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import type { ServerInstallKind } from "./types/server-update.js";
import { getPackageInfo, packageRootDir } from "./version.js";

const execFileAsync = promisify(execFile);

function matchesGlobalRoot(packageName: string, globalRoot: string): boolean {
  try {
    const packageDir = packageRootDir();
    return Boolean(
      packageDir && realpathSync(packageDir) === realpathSync(join(globalRoot, packageName)),
    );
  } catch {
    return false;
  }
}

/** CLI-only synchronous lookup; server requests use resolveInstallKindAsync. */
export function isLikelyGlobalNpmInstall(packageName: string): boolean {
  try {
    const globalRoot = execFileSync("npm", ["root", "-g"], {
      encoding: "utf-8",
      timeout: 8_000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return matchesGlobalRoot(packageName, globalRoot);
  } catch {
    return false;
  }
}

export function manualUpdateCommand(packageName: string, version = "latest"): string {
  return `npm install -g ${packageName}@${version}`;
}

type InstallKind = { kind: ServerInstallKind; updatable: boolean; manualCommand: string };

function installKind(packageName: string, updatable: boolean): InstallKind {
  return {
    kind: updatable ? "npm-global" : "other",
    updatable,
    manualCommand: manualUpdateCommand(packageName),
  };
}

export function resolveInstallKind(packageName = getPackageInfo().name): InstallKind {
  return installKind(packageName, isLikelyGlobalNpmInstall(packageName));
}

export async function resolveInstallKindAsync(
  packageName = getPackageInfo().name,
): Promise<InstallKind> {
  try {
    const { stdout } = await execFileAsync("npm", ["root", "-g"], {
      encoding: "utf-8",
      timeout: 8_000,
      maxBuffer: 64 * 1024,
    });
    return installKind(packageName, matchesGlobalRoot(packageName, stdout.trim()));
  } catch {
    return installKind(packageName, false);
  }
}
