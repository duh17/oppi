#!/usr/bin/env node
/**
 * The model lane every model-backed E2E run uses: DeepSeek V4.1 Flash through
 * OpenCode Go, with the developer's existing Pi credential.
 *
 * The isolated E2E Pi agent dir gets only that one provider API key, copied out
 * of the developer's `auth.json` through `ModelRuntime`. OpenCode Go is a
 * built-in Pi provider resolved from an API key, so the lane needs no Pi
 * extension link and no OAuth refresh: nothing in the isolated dir can rotate
 * the developer's own login. enabledModels scopes new sessions to the lane
 * model without starring a Pi default.
 *
 * Anthropic Claude Haiku was the lane before. An Anthropic subscription token
 * sent through Pi's built-in provider bills as extra usage, so that lane needed
 * a Pi login plus a provider extension and failed with "You're out of extra
 * usage" whenever the extension link was missing.
 *
 * Shell callers (`clients/apple/scripts/e2e.sh`) run:
 *   node server/e2e/model-lane.ts write <pi-agent-dir>
 * which prints the model ref on success.
 */

import { chmodSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ModelRuntime } from "@earendil-works/pi-coding-agent";

export const E2E_MODEL_PROVIDER = "opencode-go";
export const E2E_MODEL_ID = "deepseek-v4.1-flash";
export const E2E_MODEL = `${E2E_MODEL_PROVIDER}/${E2E_MODEL_ID}`;

/** The developer's Pi agent dir, which owns the OpenCode Go credential. */
export function sourcePiAgentDir(env: NodeJS.ProcessEnv = process.env): string {
  return resolve(env.E2E_SOURCE_PI_AGENT_DIR || join(homedir(), ".pi", "agent"));
}

/** The lane provider's API key from the source login. Never logged. */
export async function resolveE2EModelToken(
  sourceDir: string = sourcePiAgentDir(),
): Promise<string> {
  const runtime = await ModelRuntime.create({
    authPath: join(sourceDir, "auth.json"),
    modelsPath: join(sourceDir, "models.json"),
  });
  const resolution = await runtime.getAuth(E2E_MODEL_PROVIDER);
  const token = resolution?.auth?.apiKey?.trim();
  if (!token) {
    throw new Error(
      `[e2e] No ${E2E_MODEL_PROVIDER} credential in ${join(sourceDir, "auth.json")}. Run \`pi\` and /login to OpenCode Go (or export OPENCODE_API_KEY), then retry.`,
    );
  }
  return token;
}

/** Write the isolated E2E Pi auth and settings for the DeepSeek lane. */
export async function writeE2EModelLane(
  piAgentDir: string,
  sourceDir: string = sourcePiAgentDir(),
): Promise<void> {
  const token = await resolveE2EModelToken(sourceDir);
  mkdirSync(piAgentDir, { recursive: true });

  const authPath = join(piAgentDir, "auth.json");
  writeFileSync(
    authPath,
    `${JSON.stringify({ [E2E_MODEL_PROVIDER]: { type: "api_key", key: token } }, null, 2)}\n`,
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);

  writeFileSync(
    join(piAgentDir, "settings.json"),
    `${JSON.stringify({ enabledModels: [E2E_MODEL] }, null, 2)}\n`,
  );
}

/** Real path of a path, or the resolved path when it does not exist. */
function realPathOrSelf(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

/**
 * True when this module is the script node was asked to run. Both sides go
 * through realpath: a checkout reached through a symlink (`/tmp` on macOS) has
 * `argv[1]` in the symlinked spelling and `import.meta.url` in the real one, and
 * a lexical compare would skip `main` — silently writing no auth and exiting 0.
 */
export function isEntrypoint(
  argvPath: string | undefined = process.argv[1],
  moduleLocation: string = import.meta.url,
): boolean {
  if (!argvPath) return false;
  const modulePath = moduleLocation.startsWith("file:")
    ? fileURLToPath(moduleLocation)
    : moduleLocation;
  return realPathOrSelf(argvPath) === realPathOrSelf(modulePath);
}

async function main(argv: string[]): Promise<void> {
  const [command, dir] = argv;
  if (command !== "write" || !dir) {
    throw new Error("usage: model-lane.ts write <pi-agent-dir>");
  }
  await writeE2EModelLane(resolve(dir));
  console.log(E2E_MODEL);
}

if (isEntrypoint()) {
  main(process.argv.slice(2)).catch((err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
