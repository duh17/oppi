/**
 * Detect whether this process is the globally installed `oppi-server` npm
 * package. `oppi update` and the in-app update route share this owner.
 */

import { execSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { join } from "node:path";

import type { ServerInstallKind } from "./types/server-update.js";
import { getPackageInfo, packageRootDir } from "./version.js";

export function isLikelyGlobalNpmInstall(packageName: string): boolean {
  try {
    const packageDir = packageRootDir();
    if (!packageDir) return false;
    const globalRoot = execSync("npm root -g", {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!globalRoot) return false;
    const installed = realpathSync(packageDir);
    const expected = realpathSync(join(globalRoot, packageName));
    return installed === expected;
  } catch {
    return false;
  }
}

export function manualUpdateCommand(packageName: string, version = "latest"): string {
  return `npm install -g ${packageName}@${version}`;
}

export function resolveInstallKind(packageName = getPackageInfo().name): {
  kind: ServerInstallKind;
  updatable: boolean;
  manualCommand: string;
} {
  if (isLikelyGlobalNpmInstall(packageName)) {
    return {
      kind: "npm-global",
      updatable: true,
      manualCommand: manualUpdateCommand(packageName),
    };
  }
  return {
    kind: "other",
    updatable: false,
    manualCommand: manualUpdateCommand(packageName),
  };
}
