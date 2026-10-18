#!/usr/bin/env node
/**
 * The model lane every model-backed E2E run uses: Anthropic Claude Haiku 5.5
 * through the developer's existing Pi login.
 *
 * The isolated E2E Pi agent dir gets only a short-lived Anthropic access token
 * stored as an API key. The refresh token stays in the developer's own
 * auth.json, so an E2E server can never rotate it out from under the real
 * install; Pi refreshes the source login under its own lock when needed.
 * enabledModels scopes new sessions to Haiku without starring a Pi default.
 *
 * Anthropic bills a subscription token sent through Pi's built-in provider as
 * extra usage. Set E2E_ANTHROPIC_EXTENSION to the Pi extension that owns
 * subscription requests on this machine; the lane links it into the isolated
 * agent dir. Native mode only: Docker cannot follow the host link.
 *
 * Shell callers (the Apple e2e/sim-lab wrappers) run:
 *   node server/e2e/model-lane.ts write <pi-agent-dir>
 * which prints the model ref on success.
 */

import { chmodSync, existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ModelRuntime } from "@earendil-works/pi-coding-agent";

export const E2E_MODEL_PROVIDER = "anthropic";
export const E2E_MODEL_ID = "claude-haiku-5-5";
export const E2E_MODEL = `${E2E_MODEL_PROVIDER}/${E2E_MODEL_ID}`;

/** The developer's Pi agent dir, which owns the Anthropic login. */
export function sourcePiAgentDir(env: NodeJS.ProcessEnv = process.env): string {
  return resolve(env.E2E_SOURCE_PI_AGENT_DIR || join(homedir(), ".pi", "agent"));
}

/** A current Anthropic access token from the source login, refreshed by Pi if expired. */
export async function resolveE2EAnthropicToken(
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
      `[e2e] No Anthropic login in ${join(sourceDir, "auth.json")}. Run \`pi\` and /login to Anthropic, then retry.`,
    );
  }
  return token;
}

/** Write the isolated E2E Pi auth, settings, and Anthropic extension link for the Haiku lane. */
export async function writeE2EModelLane(
  piAgentDir: string,
  sourceDir: string = sourcePiAgentDir(),
  anthropicExtension: string | undefined = process.env.E2E_ANTHROPIC_EXTENSION,
): Promise<void> {
  const token = await resolveE2EAnthropicToken(sourceDir);
  mkdirSync(piAgentDir, { recursive: true });

  const extensionPath = anthropicExtension?.trim() ? resolve(anthropicExtension.trim()) : undefined;
  if (extensionPath) {
    if (!existsSync(extensionPath)) {
      throw new Error(`[e2e] E2E_ANTHROPIC_EXTENSION does not exist: ${extensionPath}`);
    }
    const extensionsDir = join(piAgentDir, "extensions");
    mkdirSync(extensionsDir, { recursive: true });
    const link = join(extensionsDir, basename(extensionPath));
    rmSync(link, { force: true });
    symlinkSync(extensionPath, link);
  }

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

async function main(argv: string[]): Promise<void> {
  const [command, dir] = argv;
  if (command !== "write" || !dir) {
    throw new Error("usage: model-lane.ts write <pi-agent-dir>");
  }
  await writeE2EModelLane(resolve(dir));
  console.log(E2E_MODEL);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((err: unknown) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
