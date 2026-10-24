import { join } from "node:path";
import { ModelRuntime, getAgentDir } from "@earendil-works/pi-coding-agent";
import { resolveHostEnv } from "../host-env.js";
import type { ServerConfig } from "../types.js";

/**
 * Providers with usable credentials, resolved the way the server resolves them
 * (Pi's `auth.json`, `models.json`, and provider API-key environment variables).
 * `runtimeEnv` entries are applied first because the server applies them to its own
 * environment. Extension-registered providers are not loaded here.
 *
 * A background service does not inherit the interactive shell: it starts with a bare
 * environment, and the server then applies `runtimeEnv`. With `serviceOnly`, the lookup
 * runs in that environment, so a key exported in `.zshrc` does not count. `process.env`
 * is swapped only for the lookup and restored afterwards.
 */
export async function listAuthenticatedModelProviders(
  config: ServerConfig,
  serviceOnly: boolean,
): Promise<string[]> {
  const shellEnv = { ...process.env };
  const runtimeEnv = resolveHostEnv(config).env;
  const lookupEnv: NodeJS.ProcessEnv = serviceOnly
    ? Object.fromEntries(
        ["HOME", "USER", "LOGNAME", "TMPDIR"].flatMap((key) =>
          shellEnv[key] === undefined ? [] : [[key, shellEnv[key]]],
        ),
      )
    : { ...shellEnv };
  for (const key of Object.keys(config.runtimeEnv ?? {})) {
    const value = runtimeEnv[key];
    if (value !== undefined) lookupEnv[key] = value;
  }

  for (const key of Object.keys(process.env)) delete process.env[key];
  Object.assign(process.env, lookupEnv);
  try {
    const agentDir = getAgentDir();
    const runtime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });
    return [...new Set(runtime.getAvailableSnapshot().map((model) => model.provider))].sort();
  } finally {
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, shellEnv);
  }
}
