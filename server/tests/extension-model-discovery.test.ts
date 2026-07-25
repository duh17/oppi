import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ModelRegistry,
  ModelRuntime,
  type LoadExtensionsResult,
  type ProviderConfig,
} from "@earendil-works/pi-coding-agent";
import type { Provider } from "@earendil-works/pi-ai";

import {
  applyPendingProviderRegistrations,
  discoverExtensionProviders,
  type ProviderRegistrationTarget,
} from "../src/extension-model-discovery.js";

// ─── applyPendingProviderRegistrations (unit) ───

function makeExtensionsResult(
  pending: Array<{ name: string; config: ProviderConfig; extensionPath: string }> = [],
  native: Array<{ provider: Provider; extensionPath: string }> = [],
): LoadExtensionsResult {
  return {
    extensions: [],
    errors: [],
    runtime: {
      pendingProviderRegistrations: pending,
      pendingNativeProviderRegistrations: native,
    },
  } as unknown as LoadExtensionsResult;
}

function makeTarget(overrides: Partial<ProviderRegistrationTarget> = {}): ProviderRegistrationTarget & {
  registerProvider: ReturnType<typeof vi.fn>;
  registerNativeProvider: ReturnType<typeof vi.fn>;
} {
  return {
    registerProvider: vi.fn(),
    registerNativeProvider: vi.fn(),
    ...overrides,
  };
}

const CONFIG = { models: [] } as unknown as ProviderConfig;

describe("applyPendingProviderRegistrations", () => {
  it("registers queued providers and clears the queue", () => {
    const target = makeTarget();
    const result = makeExtensionsResult([
      { name: "kiro", config: CONFIG, extensionPath: "kiro.ts" },
      { name: "antigravity", config: CONFIG, extensionPath: "antigravity.ts" },
    ]);

    const applied = applyPendingProviderRegistrations(target, result);

    expect(target.registerProvider).toHaveBeenCalledTimes(2);
    expect(target.registerProvider).toHaveBeenCalledWith("kiro", CONFIG);
    expect(target.registerProvider).toHaveBeenCalledWith("antigravity", CONFIG);
    expect(applied.registeredProviderIds).toEqual(["kiro", "antigravity"]);
    expect(applied.diagnostics).toEqual([]);
    // Queue cleared so a later runner bind does not re-apply.
    expect(result.runtime.pendingProviderRegistrations).toEqual([]);
  });

  it("registers native providers by their provider id", () => {
    const target = makeTarget();
    const provider = { id: "native-prov" } as unknown as Provider;
    const result = makeExtensionsResult([], [{ provider, extensionPath: "native.ts" }]);

    const applied = applyPendingProviderRegistrations(target, result);

    expect(target.registerNativeProvider).toHaveBeenCalledWith(provider);
    expect(applied.registeredProviderIds).toEqual(["native-prov"]);
    expect(result.runtime.pendingNativeProviderRegistrations).toEqual([]);
  });

  it("isolates a throwing registration and continues with the rest", () => {
    const target = makeTarget({
      registerProvider: vi
        .fn()
        .mockImplementation((name: string) => {
          if (name === "broken") throw new Error("bad provider");
        }),
    });
    const result = makeExtensionsResult([
      { name: "broken", config: CONFIG, extensionPath: "broken.ts" },
      { name: "good", config: CONFIG, extensionPath: "good.ts" },
    ]);

    const applied = applyPendingProviderRegistrations(target, result);

    expect(applied.registeredProviderIds).toEqual(["good"]);
    expect(applied.diagnostics).toEqual([
      { extensionPath: "broken.ts", message: "bad provider" },
    ]);
    // Both entries are still drained from the queue.
    expect(result.runtime.pendingProviderRegistrations).toEqual([]);
  });

  it("returns empty results when nothing is pending", () => {
    const target = makeTarget();
    const applied = applyPendingProviderRegistrations(target, makeExtensionsResult());

    expect(applied.registeredProviderIds).toEqual([]);
    expect(applied.diagnostics).toEqual([]);
    expect(target.registerProvider).not.toHaveBeenCalled();
    expect(target.registerNativeProvider).not.toHaveBeenCalled();
  });
});

// ─── discoverExtensionProviders (integration with a real fixture extension) ───

describe("discoverExtensionProviders", () => {
  const tempDirs: string[] = [];

  function makeTempDir(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function setupAgentDir(extensionSource: string): { cwd: string; agentDir: string } {
    const cwd = makeTempDir("oppi-ext-disc-cwd-");
    const agentDir = makeTempDir("oppi-ext-disc-agent-");
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}", "utf-8");
    writeFileSync(join(agentDir, "models.json"), "{}", "utf-8");
    writeFileSync(join(agentDir, "extensions", "test-provider.ts"), extensionSource, "utf-8");
    return { cwd, agentDir };
  }

  const STATIC_PROVIDER_EXTENSION = `
export default function (pi) {
  pi.registerProvider("testprov", {
    name: "Test Provider",
    api: "openai-completions",
    baseUrl: "https://api.test.local/v1",
    apiKey: "test-key",
    models: [
      {
        id: "test-model",
        name: "Test Model",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 100000,
        maxTokens: 8000,
      },
    ],
  });
}
`;

  it("registers a global extension's static provider onto the model runtime", async () => {
    const { cwd, agentDir } = setupAgentDir(STATIC_PROVIDER_EXTENSION);
    const modelRuntime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });

    const result = await discoverExtensionProviders(modelRuntime, { cwd, agentDir });

    expect(result.registeredProviderIds).toContain("testprov");
    const registry = new ModelRegistry(modelRuntime);
    const ids = registry.getAll().map((model) => `${model.provider}/${model.id}`);
    expect(ids).toContain("testprov/test-model");
    // apiKey-backed extension provider passes checkAuth, so it is also
    // surfaced to the auth-gated picker catalog.
    const available = registry.getAvailable().map((model) => `${model.provider}/${model.id}`);
    expect(available).toContain("testprov/test-model");
  });

  it("registers an OAuth-only provider but keeps it out of the auth-gated picker until credentialed", async () => {
    // Pins the known limitation both reviewers flagged: an OAuth-only extension
    // provider with no stored credential is registered (getAll) but excluded from
    // getAvailable(), so it does not reach the picker until the user authenticates.
    const oauthExtension = `
export default function (pi) {
  pi.registerProvider("oauthprov", {
    name: "OAuth Provider",
    api: "openai-completions",
    baseUrl: "https://api.test.local/v1",
    oauth: {
      name: "oauthprov",
      login: async () => ({ accessToken: "token" }),
      refreshToken: async (creds) => creds,
      getApiKey: (creds) => creds.accessToken,
    },
    models: [
      {
        id: "oauth-model",
        name: "OAuth Model",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 100000,
        maxTokens: 8000,
      },
    ],
  });
}
`;
    const { cwd, agentDir } = setupAgentDir(oauthExtension);
    const modelRuntime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });

    const result = await discoverExtensionProviders(modelRuntime, { cwd, agentDir });

    expect(result.registeredProviderIds).toContain("oauthprov");
    const registry = new ModelRegistry(modelRuntime);
    const all = registry.getAll().map((model) => `${model.provider}/${model.id}`);
    expect(all).toContain("oauthprov/oauth-model");
    // No stored credential -> not configured -> hidden from the auth-gated picker.
    const available = registry.getAvailable().map((model) => `${model.provider}/${model.id}`);
    expect(available).not.toContain("oauthprov/oauth-model");
  });

  it("survives an extension that throws during registration", async () => {
    const throwing = `
export default function (pi) {
  pi.registerProvider("broken", {
    models: "not-an-array",
  });
}
`;
    const { cwd, agentDir } = setupAgentDir(throwing);
    const modelRuntime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });

    // Must not throw; the broken extension is reported, not fatal.
    const result = await discoverExtensionProviders(modelRuntime, { cwd, agentDir });
    expect(result.registeredProviderIds).not.toContain("broken");
  });

  it("returns no providers when there are no extensions", async () => {
    const cwd = makeTempDir("oppi-ext-disc-cwd-");
    const agentDir = makeTempDir("oppi-ext-disc-agent-");
    writeFileSync(join(agentDir, "auth.json"), "{}", "utf-8");
    writeFileSync(join(agentDir, "models.json"), "{}", "utf-8");
    const modelRuntime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });

    const result = await discoverExtensionProviders(modelRuntime, { cwd, agentDir });

    expect(result.registeredProviderIds).toEqual([]);
  });
});
