import { existsSync, mkdtempSync, mkdirSync, utimesSync, writeFileSync, rmSync } from "node:fs";
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
  ExtensionProviderCatalog,
  extensionDiscoveryFingerprint,
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

function staticProviderExtension(providerId: string, modelId: string): string {
  return `
export default function (pi) {
  pi.registerProvider(${JSON.stringify(providerId)}, {
    name: ${JSON.stringify(providerId)},
    api: "openai-completions",
    baseUrl: "https://api.test.local/v1",
    apiKey: "test-key",
    models: [
      {
        id: ${JSON.stringify(modelId)},
        name: ${JSON.stringify(modelId)},
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
}

function modelIds(runtime: ModelRuntime): string[] {
  return new ModelRegistry(runtime).getAll().map((model) => `${model.provider}/${model.id}`);
}

describe("ExtensionProviderCatalog", () => {
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

  async function setupCatalog(extensionSource?: string): Promise<{
    cwd: string;
    agentDir: string;
    runtime: ModelRuntime;
    catalog: ExtensionProviderCatalog;
    extensionsDir: string;
  }> {
    const cwd = makeTempDir("oppi-ext-cat-cwd-");
    const agentDir = makeTempDir("oppi-ext-cat-agent-");
    const extensionsDir = join(agentDir, "extensions");
    mkdirSync(extensionsDir, { recursive: true });
    writeFileSync(join(agentDir, "auth.json"), "{}", "utf-8");
    writeFileSync(join(agentDir, "models.json"), "{}", "utf-8");
    writeFileSync(join(agentDir, "settings.json"), "{}", "utf-8");
    if (extensionSource) {
      writeFileSync(join(extensionsDir, "test-provider.ts"), extensionSource, "utf-8");
    }
    const runtime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });
    return {
      cwd,
      agentDir,
      runtime,
      catalog: new ExtensionProviderCatalog(runtime, { cwd, agentDir }),
      extensionsDir,
    };
  }

  it("skips a second sync when provider sources are unchanged", async () => {
    const { catalog } = await setupCatalog(staticProviderExtension("hotprov", "hot-model"));

    const first = await catalog.sync();
    const second = await catalog.sync();

    expect(first.skipped).toBe(false);
    expect(first.registeredProviderIds).toContain("hotprov");
    expect(second.skipped).toBe(true);
    expect(second.registeredProviderIds).toContain("hotprov");
  });

  it("registers a provider extension added after the first sync", async () => {
    const { catalog, runtime, extensionsDir } = await setupCatalog();

    expect((await catalog.sync()).registeredProviderIds).toEqual([]);
    writeFileSync(
      join(extensionsDir, "late-provider.ts"),
      staticProviderExtension("lateprov", "late-model"),
      "utf-8",
    );

    const second = await catalog.sync();
    expect(second.skipped).toBe(false);
    expect(second.registeredProviderIds).toContain("lateprov");
    expect(modelIds(runtime)).toContain("lateprov/late-model");
  });

  it("unregisters a provider extension removed after the first sync", async () => {
    const { catalog, runtime, extensionsDir } = await setupCatalog(
      staticProviderExtension("goneprov", "gone-model"),
    );

    expect((await catalog.sync()).registeredProviderIds).toContain("goneprov");
    rmSync(join(extensionsDir, "test-provider.ts"));

    const second = await catalog.sync();
    expect(second.skipped).toBe(false);
    expect(second.registeredProviderIds).not.toContain("goneprov");
    expect(second.unregisteredProviderIds).toContain("goneprov");
    expect(modelIds(runtime)).not.toContain("goneprov/gone-model");
  });

  it("picks up an edited provider model list without a new ModelRuntime", async () => {
    const { catalog, runtime, extensionsDir } = await setupCatalog(
      staticProviderExtension("editprov", "model-a"),
    );

    expect(modelIds(runtime)).not.toContain("editprov/model-a");
    await catalog.sync();
    expect(modelIds(runtime)).toContain("editprov/model-a");

    const editedPath = join(extensionsDir, "test-provider.ts");
    writeFileSync(editedPath, staticProviderExtension("editprov", "model-b"), "utf-8");
    const later = new Date(Date.now() + 2_000);
    utimesSync(editedPath, later, later);
    const second = await catalog.sync();

    expect(second.skipped).toBe(false);
    expect(modelIds(runtime)).toContain("editprov/model-b");
    expect(modelIds(runtime)).not.toContain("editprov/model-a");
  });

  it("force sync reloads even when the fingerprint is unchanged", async () => {
    const { catalog } = await setupCatalog(staticProviderExtension("forceprov", "force-model"));

    await catalog.sync();
    const forced = await catalog.sync({ force: true });

    expect(forced.skipped).toBe(false);
    expect(forced.registeredProviderIds).toContain("forceprov");
  });

  it("replaces a re-registered provider instead of merging leftover fields", async () => {
    const withHeaders = `
export default function (pi) {
  pi.registerProvider("hdrprov", {
    name: "hdrprov",
    api: "openai-completions",
    baseUrl: "https://api.test.local/v1",
    apiKey: "test-key",
    headers: { "X-Test": "1" },
    models: [
      {
        id: "hdr-model",
        name: "hdr-model",
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
    const { catalog, runtime, extensionsDir } = await setupCatalog(withHeaders);
    await catalog.sync();
    expect(runtime.getRegisteredProviderConfig("hdrprov")?.headers).toEqual({ "X-Test": "1" });

    writeFileSync(
      join(extensionsDir, "test-provider.ts"),
      staticProviderExtension("hdrprov", "hdr-model"),
      "utf-8",
    );
    await catalog.sync();
    expect(runtime.getRegisteredProviderConfig("hdrprov")?.headers).toBeUndefined();
  });

  it("does not install a missing settings package during catalog sync", async () => {
    const { catalog, agentDir } = await setupCatalog();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({
        packages: [{ source: "npm:oppi-not-installed-provider@1.0.0" }],
      }),
      "utf-8",
    );

    const result = await catalog.sync();

    expect(existsSync(join(agentDir, "npm", "node_modules", "oppi-not-installed-provider"))).toBe(
      false,
    );
    expect(
      result.diagnostics.some(
        (diagnostic) =>
          diagnostic.extensionPath.includes("oppi-not-installed-provider") &&
          diagnostic.message.includes("will not install"),
      ),
    ).toBe(true);
  });

  it("does not reload on every call after a failed sync of unchanged sources", async () => {
    const { runtime, cwd, agentDir } = await setupCatalog(
      staticProviderExtension("keepprov", "keep-model"),
    );
    let failRefresh = false;
    const catalog = new ExtensionProviderCatalog(
      {
        registerProvider: runtime.registerProvider.bind(runtime),
        registerNativeProvider: runtime.registerNativeProvider.bind(runtime),
        unregisterProvider: runtime.unregisterProvider.bind(runtime),
        refresh: async (options) => {
          if (failRefresh) throw new Error("forced catalog refresh failure");
          return runtime.refresh(options);
        },
      },
      { cwd, agentDir },
    );

    expect((await catalog.sync()).registeredProviderIds).toContain("keepprov");
    failRefresh = true;
    const failed = await catalog.sync({ force: true });
    expect(failed.skipped).toBe(false);
    expect(
      failed.diagnostics.some((diagnostic) =>
        diagnostic.message.includes("forced catalog refresh failure"),
      ),
    ).toBe(true);

    const skipped = await catalog.sync();
    expect(skipped.skipped).toBe(true);
    expect(skipped.registeredProviderIds).toContain("keepprov");
  });
});

describe("extensionDiscoveryFingerprint", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("changes when settings or an extension file changes", () => {
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-ext-fp-"));
    tempDirs.push(agentDir);
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    writeFileSync(join(agentDir, "settings.json"), "{}", "utf-8");

    const initial = extensionDiscoveryFingerprint(agentDir);
    writeFileSync(join(agentDir, "settings.json"), '{"extensions":[]}', "utf-8");
    const afterSettings = extensionDiscoveryFingerprint(agentDir);
    writeFileSync(join(agentDir, "extensions", "foo.ts"), "export default () => {}", "utf-8");
    const afterFile = extensionDiscoveryFingerprint(agentDir);

    expect(afterSettings).not.toBe(initial);
    expect(afterFile).not.toBe(afterSettings);
  });

  it("changes when a nested directory extension file changes", () => {
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-ext-fp-dir-"));
    tempDirs.push(agentDir);
    const extensionDir = join(agentDir, "extensions", "dirprov");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(join(extensionDir, "index.ts"), "export default () => {}", "utf-8");

    const before = extensionDiscoveryFingerprint(agentDir);
    writeFileSync(join(extensionDir, "index.ts"), "export default function () {}", "utf-8");
    const after = extensionDiscoveryFingerprint(agentDir);

    expect(after).not.toBe(before);
  });
});
