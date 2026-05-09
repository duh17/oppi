import type { OAuthLoginCallbacks, OAuthProviderInterface } from "@earendil-works/pi-ai";

import { safeErrorMessage } from "../log-utils.js";
import { createLogger } from "../logger.js";
import { openBrowser as defaultOpenBrowser } from "./browser-launcher.js";
import { ProviderAuthFlowStore, createDeferred } from "./flow-store.js";
import {
  ProviderAuthError,
  type ProviderAuthFlowSnapshot,
  type ProviderAuthFlowType,
  type ProviderAuthLaunchMode,
  type ProviderAuthProviderInfo,
  type ProviderAuthProviderStatus,
  type ProviderAuthPrompt,
  isTerminalProviderAuthStatus,
} from "./types.js";

const log = createLogger({ base: { component: "provider_auth" } });

const PROVIDER_NAME_OVERRIDES: Record<string, string> = {
  anthropic: "Anthropic",
  "openai-codex": "ChatGPT (Codex)",
  "github-copilot": "GitHub Copilot",
  "google-gemini-cli": "Google Gemini CLI",
  "google-antigravity": "Google Antigravity",
  openai: "OpenAI",
  google: "Google",
  deepseek: "DeepSeek",
  mistral: "Mistral",
  groq: "Groq",
  xai: "xAI",
  openrouter: "OpenRouter",
  zai: "Z.ai",
};

type ProviderCredential =
  | {
      type: "api_key";
      key: string;
    }
  | {
      type: "oauth";
      expires: number;
      [key: string]: unknown;
    };

export interface ProviderAuthStorage {
  getOAuthProviders(): OAuthProviderInterface[];
  login(providerId: string, callbacks: OAuthLoginCallbacks): Promise<void>;
  set(provider: string, credential: { type: "api_key"; key: string }): void;
  remove(provider: string): void;
  getAll(): Record<string, ProviderCredential>;
}

export interface ProviderAuthManagerOptions {
  authStorage: ProviderAuthStorage;
  onCredentialsChanged?: () => Promise<void> | void;
  getKnownApiKeyProviderIds?: () => string[];
  openBrowser?: (url: string) => Promise<void> | void;
  flowTtlMs?: number;
  terminalFlowRetentionMs?: number;
  now?: () => number;
}

function prettifyProviderName(providerId: string): string {
  const override = PROVIDER_NAME_OVERRIDES[providerId];
  if (override) return override;

  return providerId
    .split(/[-_]/g)
    .filter((part) => part.length > 0)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join(" ");
}

function maskApiKey(key: string): string {
  if (key.length <= 8) {
    return "****";
  }
  return `${key.slice(0, 5)}...${key.slice(-3)}`;
}

function redactSensitiveError(message: string): string {
  return message
    .replace(/(code|token|access_token|refresh_token)=([^&\s]+)/gi, "$1=<redacted>")
    .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, "Bearer <redacted>");
}

function flowTypeForProvider(provider: OAuthProviderInterface): ProviderAuthFlowType {
  return provider.usesCallbackServer ? "oauth_callback" : "device_code";
}

function isApiKeyCredential(
  value: ProviderCredential | undefined,
): value is { type: "api_key"; key: string } {
  return Boolean(value && value.type === "api_key" && typeof value.key === "string");
}

function isOAuthCredential(
  value: ProviderCredential | undefined,
): value is { type: "oauth"; expires: number } {
  return Boolean(value && value.type === "oauth" && typeof value.expires === "number");
}

export class ProviderAuthManager {
  private readonly authStorage: ProviderAuthStorage;
  private readonly onCredentialsChanged: () => Promise<void> | void;
  private readonly getKnownApiKeyProviderIds: () => string[];
  private readonly openBrowser: (url: string) => Promise<void> | void;
  private readonly flowStore: ProviderAuthFlowStore;

  constructor(options: ProviderAuthManagerOptions) {
    this.authStorage = options.authStorage;
    this.onCredentialsChanged = options.onCredentialsChanged ?? (() => {});
    this.getKnownApiKeyProviderIds = options.getKnownApiKeyProviderIds ?? (() => []);
    this.openBrowser = options.openBrowser ?? defaultOpenBrowser;
    this.flowStore = new ProviderAuthFlowStore({
      ttlMs: options.flowTtlMs,
      terminalRetentionMs: options.terminalFlowRetentionMs,
      now: options.now,
    });
  }

  listProviders(): ProviderAuthProviderInfo[] {
    this.flowStore.prune();

    const oauthProviders = this.authStorage.getOAuthProviders();
    const oauthById = new Map(oauthProviders.map((provider) => [provider.id, provider]));

    const providers = new Map<string, ProviderAuthProviderInfo>();
    const apiProviderIds = new Set(this.getKnownApiKeyProviderIds());

    for (const oauthProvider of oauthProviders) {
      providers.set(oauthProvider.id, {
        id: oauthProvider.id,
        name: oauthProvider.name,
        supportsApiKey: apiProviderIds.has(oauthProvider.id),
        oauth: {
          flowType: flowTypeForProvider(oauthProvider),
          supportsServerBrowserLaunch: true,
          supportsPhoneBrowserLaunch: true,
          supportsManualCodeInput: oauthProvider.usesCallbackServer === true,
          mayPromptForInput: true,
        },
      });
    }

    for (const providerId of apiProviderIds) {
      if (providers.has(providerId)) continue;

      const oauthProvider = oauthById.get(providerId);
      providers.set(providerId, {
        id: providerId,
        name: oauthProvider?.name ?? prettifyProviderName(providerId),
        supportsApiKey: true,
        oauth: oauthProvider
          ? {
              flowType: flowTypeForProvider(oauthProvider),
              supportsServerBrowserLaunch: true,
              supportsPhoneBrowserLaunch: true,
              supportsManualCodeInput: oauthProvider.usesCallbackServer === true,
              mayPromptForInput: true,
            }
          : undefined,
      });
    }

    return [...providers.values()].sort((a, b) => a.id.localeCompare(b.id));
  }

  getStatus(): ProviderAuthProviderStatus[] {
    this.flowStore.prune();

    const providerInfo = this.listProviders();
    const statusById = new Map<string, ProviderAuthProviderStatus>();

    for (const info of providerInfo) {
      statusById.set(info.id, {
        ...info,
        authenticated: false,
      });
    }

    const credentials = this.authStorage.getAll();
    for (const [providerId, credential] of Object.entries(credentials)) {
      const existing = statusById.get(providerId);
      const base: ProviderAuthProviderStatus =
        existing ??
        ({
          id: providerId,
          name: prettifyProviderName(providerId),
          supportsApiKey: true,
          authenticated: false,
        } satisfies ProviderAuthProviderStatus);

      if (isApiKeyCredential(credential)) {
        base.authenticated = true;
        base.credentialType = "api_key";
        base.maskedKey = maskApiKey(credential.key);
      } else if (isOAuthCredential(credential)) {
        base.authenticated = true;
        base.credentialType = "oauth";
        base.expiresAt = credential.expires;
      }

      statusById.set(providerId, base);
    }

    return [...statusById.values()].sort((a, b) => a.id.localeCompare(b.id));
  }

  startFlow(providerId: string, launchMode: ProviderAuthLaunchMode): ProviderAuthFlowSnapshot {
    const normalizedProviderId = providerId.trim();
    if (!normalizedProviderId) {
      throw new ProviderAuthError(400, "providerId is required");
    }

    this.flowStore.prune();

    const oauthProvider = this.authStorage
      .getOAuthProviders()
      .find((provider) => provider.id === normalizedProviderId);

    if (!oauthProvider) {
      throw new ProviderAuthError(404, `Unknown OAuth provider: ${normalizedProviderId}`);
    }

    const active = this.flowStore.findActiveByProvider(normalizedProviderId);
    if (active) {
      this.flowStore.markCancelled(active.flowId, "Superseded by a new login attempt");
    }

    const record = this.flowStore.create(
      normalizedProviderId,
      flowTypeForProvider(oauthProvider),
      launchMode,
    );

    void this.runLogin(record.flowId, normalizedProviderId);

    return this.mustGetFlow(record.flowId);
  }

  getFlow(flowId: string): ProviderAuthFlowSnapshot {
    this.flowStore.prune();
    return this.mustGetFlow(flowId);
  }

  submitPromptResponse(flowId: string, value: string): ProviderAuthFlowSnapshot {
    const record = this.flowStore.get(flowId);
    if (!record) {
      throw new ProviderAuthError(404, "Flow not found");
    }

    if (isTerminalProviderAuthStatus(record.snapshot.status)) {
      throw new ProviderAuthError(409, "Flow is already complete");
    }

    if (!record.promptWaiter || !record.snapshot.prompt) {
      throw new ProviderAuthError(409, "Flow is not waiting for a prompt response");
    }

    const prompt = record.snapshot.prompt;
    const response = value ?? "";
    if (response.length === 0 && prompt.allowEmpty !== true) {
      throw new ProviderAuthError(400, "Prompt response cannot be empty");
    }

    record.promptWaiter.resolve(response);
    this.flowStore.clearPromptWaiter(flowId);

    return this.mustGetFlow(flowId);
  }

  submitManualCode(flowId: string, input: string): ProviderAuthFlowSnapshot {
    const record = this.flowStore.get(flowId);
    if (!record) {
      throw new ProviderAuthError(404, "Flow not found");
    }

    if (isTerminalProviderAuthStatus(record.snapshot.status)) {
      throw new ProviderAuthError(409, "Flow is already complete");
    }

    if (!record.manualCodeWaiter) {
      throw new ProviderAuthError(409, "Flow is not waiting for manual code input");
    }

    const trimmed = input.trim();
    if (!trimmed) {
      throw new ProviderAuthError(400, "Manual code input cannot be empty");
    }

    record.manualCodeWaiter.resolve(trimmed);
    this.flowStore.clearManualCodeWaiter(flowId);

    return this.mustGetFlow(flowId);
  }

  cancelFlow(flowId: string, reason = "Cancelled by user"): ProviderAuthFlowSnapshot {
    const snapshot = this.flowStore.markCancelled(flowId, reason);
    if (!snapshot) {
      throw new ProviderAuthError(404, "Flow not found");
    }
    return snapshot;
  }

  async setApiKey(providerId: string, key: string): Promise<void> {
    const normalizedProviderId = providerId.trim();
    const normalizedKey = key.trim();

    if (!normalizedProviderId) {
      throw new ProviderAuthError(400, "providerId is required");
    }
    if (!normalizedKey) {
      throw new ProviderAuthError(400, "key is required");
    }

    this.authStorage.set(normalizedProviderId, {
      type: "api_key",
      key: normalizedKey,
    });

    await this.refreshAfterCredentialChange();
  }

  async removeCredential(providerId: string): Promise<void> {
    const normalizedProviderId = providerId.trim();
    if (!normalizedProviderId) {
      throw new ProviderAuthError(400, "providerId is required");
    }

    this.authStorage.remove(normalizedProviderId);
    await this.refreshAfterCredentialChange();
  }

  private async runLogin(flowId: string, providerId: string): Promise<void> {
    const existing = this.flowStore.get(flowId);
    if (!existing) {
      return;
    }

    const callbacks: OAuthLoginCallbacks = {
      onAuth: (info) => {
        const snapshot = this.flowStore.setAuthInfo(flowId, info);
        if (!snapshot) return;

        const record = this.flowStore.get(flowId);
        if (!record) return;

        if (record.launchMode === "server_browser" && !record.browserOpened) {
          record.browserOpened = true;
          void Promise.resolve()
            .then(() => this.openBrowser(info.url))
            .catch((error: unknown) => {
              log.warn("provider_auth.open_browser.failed", {
                flowId,
                providerId,
                error: safeErrorMessage(error),
              });
              this.flowStore.setProgress(flowId, "Could not open browser on server");
            });
        }
      },
      onPrompt: async (prompt) => {
        const record = this.flowStore.get(flowId);
        if (!record || isTerminalProviderAuthStatus(record.snapshot.status)) {
          throw new Error("Login flow is no longer active");
        }

        const waiter = createDeferred<string>();
        const promptShape: ProviderAuthPrompt = {
          message: prompt.message,
          placeholder: prompt.placeholder,
          allowEmpty: prompt.allowEmpty,
        };
        this.flowStore.setPromptWaiter(flowId, promptShape, waiter);

        return waiter.promise;
      },
      onManualCodeInput: async () => {
        const record = this.flowStore.get(flowId);
        if (!record || isTerminalProviderAuthStatus(record.snapshot.status)) {
          throw new Error("Login flow is no longer active");
        }

        const waiter = createDeferred<string>();
        this.flowStore.setManualCodeWaiter(flowId, waiter);

        return waiter.promise;
      },
      onProgress: (message) => {
        this.flowStore.setProgress(flowId, message);
      },
      signal: existing.abortController.signal,
    };

    try {
      await this.authStorage.login(providerId, callbacks);

      const current = this.flowStore.get(flowId);
      if (!current) return;
      if (isTerminalProviderAuthStatus(current.snapshot.status)) return;

      this.flowStore.markCompleted(flowId);
      await this.refreshAfterCredentialChange();
    } catch (error) {
      const current = this.flowStore.get(flowId);
      if (!current) return;
      if (isTerminalProviderAuthStatus(current.snapshot.status)) return;

      if (current.abortController.signal.aborted) {
        this.flowStore.markCancelled(flowId, "Login cancelled");
        return;
      }

      const message = redactSensitiveError(safeErrorMessage(error));
      this.flowStore.markFailed(flowId, message);
      log.warn("provider_auth.login.failed", {
        flowId,
        providerId,
        error: message,
      });
    }
  }

  private mustGetFlow(flowId: string): ProviderAuthFlowSnapshot {
    const snapshot = this.flowStore.getSnapshot(flowId);
    if (!snapshot) {
      throw new ProviderAuthError(404, "Flow not found");
    }
    return snapshot;
  }

  private async refreshAfterCredentialChange(): Promise<void> {
    try {
      await this.onCredentialsChanged();
    } catch (error) {
      log.warn("provider_auth.refresh_models.failed", {
        error: safeErrorMessage(error),
      });
    }
  }
}
