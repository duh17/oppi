import { describe, expect, it } from "vitest";

import type {
  OAuthCredentials,
  OAuthLoginCallbacks,
  OAuthProviderInterface,
} from "@earendil-works/pi-ai";
import {
  ProviderAuthManager,
  type ProviderAuthStorage,
} from "../src/provider-auth/provider-auth-manager.js";
import { ProviderAuthError } from "../src/provider-auth/types.js";

type StoredCredential =
  | {
      type: "api_key";
      key: string;
    }
  | ({
      type: "oauth";
    } & OAuthCredentials);

class FakeAuthStorage implements ProviderAuthStorage {
  private readonly credentials: Record<string, StoredCredential> = {};

  constructor(
    private readonly providers: OAuthProviderInterface[],
    private readonly loginBehaviors: Record<
      string,
      (callbacks: OAuthLoginCallbacks) => Promise<void>
    >,
  ) {}

  getOAuthProviders(): OAuthProviderInterface[] {
    return this.providers;
  }

  async login(providerId: string, callbacks: OAuthLoginCallbacks): Promise<void> {
    const behavior = this.loginBehaviors[providerId];
    if (!behavior) {
      throw new Error(`No login behavior for ${providerId}`);
    }
    await behavior(callbacks);
  }

  set(provider: string, credential: { type: "api_key"; key: string }): void {
    this.credentials[provider] = credential;
  }

  remove(provider: string): void {
    delete this.credentials[provider];
  }

  getAll(): Record<string, StoredCredential> {
    return { ...this.credentials };
  }

  seedOAuth(provider: string): void {
    this.credentials[provider] = {
      type: "oauth",
      refresh: "refresh-token",
      access: "access-token",
      expires: Date.now() + 3_600_000,
    };
  }
}

function makeProvider(
  id: string,
  name: string,
  usesCallbackServer: boolean,
): OAuthProviderInterface {
  return {
    id,
    name,
    usesCallbackServer,
    async login(): Promise<OAuthCredentials> {
      throw new Error("unused in tests");
    },
    async refreshToken(credentials: OAuthCredentials): Promise<OAuthCredentials> {
      return credentials;
    },
    getApiKey(credentials: OAuthCredentials): string {
      return credentials.access;
    },
  };
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
    const storage = new FakeAuthStorage([], {});
    const manager = new ProviderAuthManager({
      authStorage: storage,
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

  it("completes callback flow with manual code input", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)", true)];
    const storage = new FakeAuthStorage(providers, {
      "openai-codex": async (callbacks) => {
        callbacks.onAuth({
          url: "https://auth.openai.com/oauth/authorize?x=1",
          instructions: "Complete sign in",
        });

        const input = await callbacks.onManualCodeInput?.();
        if (input !== "ok-code") {
          throw new Error("invalid code");
        }

        storage.seedOAuth("openai-codex");
      },
    });

    let refreshCount = 0;
    const manager = new ProviderAuthManager({
      authStorage: storage,
      onCredentialsChanged: () => {
        refreshCount += 1;
      },
    });

    const started = manager.startFlow("openai-codex", "none");

    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_manual_code");

    manager.submitManualCode(started.flowId, "ok-code");

    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    expect(refreshCount).toBe(1);

    const status = manager.getStatus().find((provider) => provider.id === "openai-codex");
    expect(status?.authenticated).toBe(true);
    expect(status?.credentialType).toBe("oauth");
  });

  it("handles prompt-driven flow and allows empty prompt responses when allowed", async () => {
    const providers = [makeProvider("github-copilot", "GitHub Copilot", false)];
    const storage = new FakeAuthStorage(providers, {
      "github-copilot": async (callbacks) => {
        const domain = await callbacks.onPrompt({
          message: "GitHub Enterprise domain",
          allowEmpty: true,
        });

        callbacks.onAuth({
          url: "https://github.com/login/device",
          instructions: `Enter the displayed code (${domain || "github.com"})`,
        });

        storage.seedOAuth("github-copilot");
      },
    });

    const manager = new ProviderAuthManager({ authStorage: storage });
    const started = manager.startFlow("github-copilot", "none");

    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_prompt");

    manager.submitPromptResponse(started.flowId, "");

    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    const flow = manager.getFlow(started.flowId);
    expect(flow.auth?.url).toBe("https://github.com/login/device");
  });

  it("exposes device-code flows as external auth instructions", async () => {
    const providers = [makeProvider("github-copilot", "GitHub Copilot", false)];
    const storage = new FakeAuthStorage(providers, {
      "github-copilot": async (callbacks) => {
        callbacks.onDeviceCode({
          verificationUri: "https://github.com/login/device",
          userCode: "ABCD-1234",
        });
        storage.seedOAuth("github-copilot");
      },
    });

    const manager = new ProviderAuthManager({ authStorage: storage });
    const started = manager.startFlow("github-copilot", "none");

    await waitFor(() => manager.getFlow(started.flowId).status === "completed");

    const flow = manager.getFlow(started.flowId);
    expect(flow.auth).toEqual({
      url: "https://github.com/login/device",
      instructions: "Enter code ABCD-1234",
    });
  });

  it("maps provider selection prompts to prompt responses", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)", false)];
    const storage = new FakeAuthStorage(providers, {
      "openai-codex": async (callbacks) => {
        const selected = await callbacks.onSelect({
          message: "Choose account",
          options: [
            { id: "personal", label: "Personal" },
            { id: "work", label: "Work" },
          ],
        });
        if (selected !== "work") {
          throw new Error(`unexpected selection: ${selected}`);
        }
        storage.seedOAuth("openai-codex");
      },
    });

    const manager = new ProviderAuthManager({ authStorage: storage });
    const started = manager.startFlow("openai-codex", "none");

    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_prompt");

    const prompt = manager.getFlow(started.flowId).prompt;
    expect(prompt?.options).toEqual([
      { id: "personal", label: "Personal" },
      { id: "work", label: "Work" },
    ]);

    manager.submitPromptResponse(started.flowId, "Work");

    await waitFor(() => manager.getFlow(started.flowId).status === "completed");
  });

  it("records browser launch failures without failing the auth flow", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)", true)];
    const storage = new FakeAuthStorage(providers, {
      "openai-codex": async (callbacks) => {
        callbacks.onAuth({ url: "https://auth.openai.com/oauth/authorize" });
        await callbacks.onManualCodeInput?.();
      },
    });

    const manager = new ProviderAuthManager({
      authStorage: storage,
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

    const flow = manager.getFlow(started.flowId);
    expect(flow.status).toBe("awaiting_manual_code");
    expect(flow.lastProgress).toBe("Could not open browser on server");

    manager.cancelFlow(started.flowId, "done");
  });

  it("cancels active flow and rejects further manual input", async () => {
    const providers = [makeProvider("openai-codex", "ChatGPT (Codex)", true)];
    const storage = new FakeAuthStorage(providers, {
      "openai-codex": async (callbacks) => {
        callbacks.onAuth({ url: "https://auth.openai.com/oauth/authorize" });
        await callbacks.onManualCodeInput?.();
      },
    });

    const manager = new ProviderAuthManager({ authStorage: storage });
    const started = manager.startFlow("openai-codex", "none");

    await waitFor(() => manager.getFlow(started.flowId).status === "awaiting_manual_code");

    const cancelled = manager.cancelFlow(started.flowId, "User cancelled");
    expect(cancelled.status).toBe("cancelled");

    expect(() => manager.submitManualCode(started.flowId, "unused")).toThrowError(
      ProviderAuthError,
    );
  });
});
