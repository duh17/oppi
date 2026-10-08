import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Xcode toolchain every Oppi dev build lane uses. The default app lives in
 * xcode-toolchain.txt so the shell lanes (xcode-toolchain.sh) and the Bun lanes
 * share one literal. An explicit DEVELOPER_DIR wins; this never touches
 * xcode-select.
 */
const scriptDir = dirname(fileURLToPath(import.meta.url));

export function defaultXcodeApp(): string {
  return readFileSync(join(scriptDir, "xcode-toolchain.txt"), "utf8").trim();
}

export function resolveDeveloperDir(
  env: NodeJS.ProcessEnv,
  defaultApp: string = defaultXcodeApp(),
): string {
  const explicit = env.DEVELOPER_DIR;
  if (explicit) {
    if (!existsSync(explicit)) {
      throw new Error(`DEVELOPER_DIR points at a missing directory: ${explicit}`);
    }
    return explicit;
  }
  const developerDir = join(defaultApp, "Contents", "Developer");
  if (!existsSync(developerDir)) {
    throw new Error(
      `Xcode toolchain not found: ${defaultApp}. Install it there or export DEVELOPER_DIR=<Xcode.app>/Contents/Developer (never xcode-select).`,
    );
  }
  return developerDir;
}

export function applyXcodeToolchain(
  env: NodeJS.ProcessEnv,
  defaultApp: string = defaultXcodeApp(),
): string {
  const developerDir = resolveDeveloperDir(env, defaultApp);
  env.DEVELOPER_DIR = developerDir;
  return developerDir;
}
