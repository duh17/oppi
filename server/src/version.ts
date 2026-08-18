import { dirname, join } from "node:path";
import { existsSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";

export interface PackageInfo {
  name: string;
  version: string;
}

/** Retired Mac/server updater cache. Live version is getPackageInfo(). */
export const RETIRED_RUNTIME_STATUS_FILENAME = "runtime-status.json";

export function removeRetiredRuntimeStatusFile(dataDir: string): boolean {
  const statusPath = join(dataDir, RETIRED_RUNTIME_STATUS_FILENAME);
  if (!existsSync(statusPath)) return false;
  if (!statSync(statusPath).isFile()) return false;
  unlinkSync(statusPath);
  return true;
}

let cachedPackageInfo: PackageInfo | undefined;

function findPackageJson(startDir: string): string | undefined {
  let dir = startDir;
  for (let i = 0; i < 5; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return undefined;
}

export function getPackageInfo(): PackageInfo {
  if (cachedPackageInfo) return cachedPackageInfo;

  const moduleDir = dirname(fileURLToPath(import.meta.url));
  const packagePath = findPackageJson(moduleDir);
  if (!packagePath) {
    cachedPackageInfo = { name: "oppi-server", version: "0.0.0-dev" };
    return cachedPackageInfo;
  }

  const raw = JSON.parse(readFileSync(packagePath, "utf-8")) as {
    name?: unknown;
    version?: unknown;
  };
  cachedPackageInfo = {
    name: typeof raw.name === "string" ? raw.name : "oppi-server",
    version: typeof raw.version === "string" ? raw.version : "0.0.0-dev",
  };
  return cachedPackageInfo;
}
