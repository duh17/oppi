import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { listAuthenticatedModelProviders } from "../src/cli/model-providers.js";
import { ConfigStore } from "../src/storage/config-store.js";

describe("listAuthenticatedModelProviders", () => {
  let root: string;
  const saved = { ...process.env };

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "oppi-model-providers-"));
    mkdirSync(join(root, "agent"));
    process.env.HOME = root;
    process.env.PI_CODING_AGENT_DIR = join(root, "agent");
    process.env.ANTHROPIC_API_KEY = "sk-ant-shell-only";
  });

  afterEach(() => {
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, saved);
    rmSync(root, { recursive: true, force: true });
  });

  it("counts a shell API key for a foreground serve", async () => {
    const config = ConfigStore.getDefaultConfig(root);
    expect(await listAuthenticatedModelProviders(config, false)).toContain("anthropic");
  });

  it("ignores a shell API key for the background service, and restores the shell env", async () => {
    const config = ConfigStore.getDefaultConfig(root);
    expect(await listAuthenticatedModelProviders(config, true)).toEqual([]);
    expect(process.env.ANTHROPIC_API_KEY).toBe("sk-ant-shell-only");
    expect(process.env.PI_CODING_AGENT_DIR).toBe(join(root, "agent"));
  });

  it("resolves a !command credential on the PATH the service gets from runtimePathEntries", async () => {
    const binDir = join(root, "service-bin");
    mkdirSync(binDir);
    writeFileSync(join(binDir, "oppi-test-key"), "#!/bin/sh\necho sk-ant-from-command\n", {
      mode: 0o755,
    });
    // The service has no PI_CODING_AGENT_DIR, so it reads the agent dir under HOME.
    const serviceAgentDir = join(root, ".pi", "agent");
    mkdirSync(serviceAgentDir, { recursive: true });
    writeFileSync(
      join(serviceAgentDir, "auth.json"),
      JSON.stringify({ anthropic: { type: "api_key", key: "!oppi-test-key" } }),
      { mode: 0o600 },
    );
    delete process.env.ANTHROPIC_API_KEY;

    const withPath = { ...ConfigStore.getDefaultConfig(root), runtimePathEntries: [binDir] };
    expect(await listAuthenticatedModelProviders(withPath, true)).toContain("anthropic");
  });

  it("counts a key the service receives through runtimeEnv", async () => {
    const config = {
      ...ConfigStore.getDefaultConfig(root),
      runtimeEnv: { ANTHROPIC_API_KEY: "sk-ant-from-runtime-env" },
    };
    delete process.env.ANTHROPIC_API_KEY;
    expect(await listAuthenticatedModelProviders(config, true)).toContain("anthropic");
    expect(process.env.ANTHROPIC_API_KEY).toBeUndefined();
  });
});
