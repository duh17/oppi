import { describe, expect, it, vi } from "vitest";

import type {
  AuthInteraction,
  AuthType,
  Credential,
  CredentialInfo,
  Provider,
} from "@earendil-works/pi-ai";
import { ProviderAuthManager } from "../src/provider-auth/provider-auth-manager.js";
import { ProviderAuthError } from "../src/provider-auth/types.js";

type LoginBehavior = (type: AuthType, interaction: AuthInteraction) => Promise<Credential>;

class FakeModelRuntime {
  private readonly credentials = new Map<string, Credential>();

  constructor(
    private readonly providers: Provider[],
    private readonly loginBehaviors: Record<string, LoginBehavior> = {},
  ) {}

  getProviders(): readonly Provider[] {
    return this.providers;
  }

  getProvider(providerId: string): Provider | undefined {
    return this.providers.find((provider) => provider.id === providerId);
  }

  async login(
    providerId: string,
    type: AuthType,
    interaction: AuthInteraction,
  ): Promise<Credential> {
    const behavior = this.loginBehaviors[providerId];
    if (!behavior) {
      throw new Error(`No login behavior for ${providerId}`);
    }
    const credential = await behavior(type, interaction);
    this.credentials.set(providerId, credential);
    return credential;
  }

  async logout(providerId: string): Promise<void> {
    this.credentials.delete(providerId);
  }

  async listCredentials(): Promise<readonly CredentialInfo[]> {
    return [...this.credentials].map(([providerId, credential]) => ({
      providerId,
      type: credential.type,
    }));
  }
}

function oauthCredential(): Credential {
  return {
    type: "oauth",
    refresh: "refresh-token",
    access: "access-token",
    expires: Date.now() + 3_600_000,
  };
}

function makeProvider(
  id: string,
  name: string,
  auth: { oauth?: boolean; apiKey?: boolean } = { oauth: true },
): Provider {
  return {
    id,
    name,
    auth: {
      ...(auth.oauth ? { oauth: {} as never } : {}),
      ...(auth.apiKey ? { apiKey: { login: vi.fn() } as never } : {}),
    },
  } as Provider;
}

async function waitFor(predicate: () => boolean, attempts = 20): Promise<void> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  if (predicate()) {
    return;
  }
  throw new Error("Timed out waiting for condition");
}

describe("ProviderAuthManager", () => {
  it("lists DeepSeek as a known API-key provider", () => {
    const runtime = new FakeModelRuntime([]);
    const manager = new ProviderAuthManager({
      modelRuntime: runtime,
      getKnownApiKeyProviderIds: () => ["deepseek"],
    });

    const providers = manager.listProviders();

    expect(providers).toHaveLength(1);
    expect(providers[0]).toMatchObject({
      id: "deepseek",
      name: "DeepSeek",
      supportsApiKey: true,
    });
  });

  it("completes OAuth flow with manual code input", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)")];
    const runtime = new FakeModelRuntime(providers, {
      "openai-codex": async (_type, interaction) => {
        interaction.notify({
          type: "auth_url",
          url: "https://auth.openai.com/oauth/authorize?x=1",
          instructions: "Complete sign in",
        });

        const input = await interaction.prompt({
          type: "manual_code",
          message: "Paste the authorization code",
        });
        if (input !== "ok-code") {
          throw new Error("invalid code");
        }
        return oauthCredential();
      },
    });

    let refreshCount = 0;
    const manager = new ProviderAuthManager({
      modelRuntime: runtime,
      onCredentialsChanged: () => {
        refreshCount += 1;
      },
    });

    const started = manager.startFlow("openai-codex", "none");
    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_manual_code");

    manager.submitManualCode(started.flowId, "ok-code");
    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    expect(refreshCount).toBe(1);
    const status = (await manager.getStatus()).find((provider) => provider.id === "openai-codex");
    expect(status?.authenticated).toBe(true);
    expect(status?.credentialType).toBe("oauth");
  });

  it("allows empty responses for optional text prompts", async () => {
    const providers = [makeProvider("github-copilot", "GitHub Copilot")];
    const runtime = new FakeModelRuntime(providers, {
      "github-copilot": async (_type, interaction) => {
        const domain = await interaction.prompt({
          type: "text",
          message: "GitHub Enterprise URL/domain (blank for github.com)",
          placeholder: "company.ghe.com",
        });
        interaction.notify({
          type: "auth_url",
          url: "https://github.com/login/device",
          instructions: `Enter the displayed code (${domain || "github.com"})`,
        });
        return oauthCredential();
      },
    });

    const manager = new ProviderAuthManager({ modelRuntime: runtime });
    const started = manager.startFlow("github-copilot", "none");
    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_prompt");

    manager.submitPromptResponse(started.flowId, "");
    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    expect(manager.getFlow(started.flowId).auth?.url).toBe("https://github.com/login/device");
  });

  it("exposes device-code events as external auth instructions", async () => {
    const providers = [makeProvider("github-copilot", "GitHub Copilot")];
    const runtime = new FakeModelRuntime(providers, {
      "github-copilot": async (_type, interaction) => {
        interaction.notify({
          type: "device_code",
          verificationUri: "https://github.com/login/device",
          userCode: "ABCD-1234",
        });
        return oauthCredential();
      },
    });

    const manager = new ProviderAuthManager({ modelRuntime: runtime });
    const started = manager.startFlow("github-copilot", "none");
    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    expect(manager.getFlow(started.flowId).auth).toEqual({
      url: "https://github.com/login/device",
      instructions: "Enter code ABCD-1234",
    });
  });

  it("maps provider selection labels back to option ids", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)")];
    const runtime = new FakeModelRuntime(providers, {
      "openai-codex": async (_type, interaction) => {
        const selected = await interaction.prompt({
          type: "select",
          message: "Choose account",
          options: [
            { id: "personal", label: "Personal" },
            { id: "work", label: "Work" },
          ],
        });
        if (selected !== "work") {
          throw new Error(`unexpected selection: ${selected}`);
        }
        return oauthCredential();
      },
    });

    const manager = new ProviderAuthManager({ modelRuntime: runtime });
    const started = manager.startFlow("openai-codex", "none");
    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_prompt");

    expect(manager.getFlow(started.flowId).prompt?.options).toEqual([
      { id: "personal", label: "Personal" },
      { id: "work", label: "Work" },
    ]);

    manager.submitPromptResponse(started.flowId, "Work");
    await waitFor(() => manager.getFlow(started.flowId).status === "completed");
  });

  it("stores API keys through ModelRuntime login", async () => {
    const providers = [makeProvider("deepseek", "DeepSeek", { apiKey: true })];
    const runtime = new FakeModelRuntime(providers, {
      deepseek: async (type, interaction) => {
        expect(type).toBe("api_key");
        return {
          type: "api_key",
          key: await interaction.prompt({ type: "secret", message: "key" }),
        };
      },
    });
    const manager = new ProviderAuthManager({ modelRuntime: runtime });

    await manager.setApiKey("deepseek", "secret-key");

    expect(await manager.getStatus()).toEqual([
      expect.objectContaining({
        id: "deepseek",
        authenticated: true,
        credentialType: "api_key",
      }),
    ]);
  });

  it("records browser launch failures without failing the auth flow", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)")];
    const runtime = new FakeModelRuntime(providers, {
      "openai-codex": async (_type, interaction) => {
        interaction.notify({
          type: "auth_url",
          url: "https://auth.openai.com/oauth/authorize",
        });
        await interaction.prompt({ type: "manual_code", message: "Paste code" });
        return oauthCredential();
      },
    });

    const manager = new ProviderAuthManager({
      modelRuntime: runtime,
      openBrowser: async () => {
        throw new Error("xdg-open missing");
      },
    });
    const started = manager.startFlow("openai-codex", "server_browser");

    await waitFor(() => {
      const flow = manager.getFlow(started.flowId);
      return (
        flow.status === "awaiting_manual_code" &&
        flow.lastProgress === "Could not open browser on server"
      );
    });

    expect(manager.getFlow(started.flowId).lastProgress).toBe("Could not open browser on server");
    manager.cancelFlow(started.flowId, "done");
  });

  it("cancels active flow and rejects further manual input", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)")];
    const runtime = new FakeModelRuntime(providers, {
      "openai-codex": async (_type, interaction) => {
        interaction.notify({
          type: "auth_url",
          url: "https://auth.openai.com/oauth/authorize",
        });
        await interaction.prompt({ type: "manual_code", message: "Paste code" });
        return oauthCredential();
      },
    });

    const manager = new ProviderAuthManager({ modelRuntime: runtime });
    const started = manager.startFlow("openai-codex", "none");
    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_manual_code");

    expect(manager.cancelFlow(started.flowId, "User cancelled").status).toBe("cancelled");
    expect(() => manager.submitManualCode(started.flowId, "unused")).toThrowError(
      ProviderAuthError,
    );
  });
});
