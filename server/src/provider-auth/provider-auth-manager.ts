import type { AuthEvent, AuthInteraction, AuthPrompt, Provider } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";

import { safeErrorMessage } from "../log-utils.js";
import { createLogger } from "../logger.js";
import { openBrowser as defaultOpenBrowser } from "./browser-launcher.js";
import { ProviderAuthFlowStore, createDeferred, type Deferred } from "./flow-store.js";
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

type ProviderAuthRuntime = Pick<
  ModelRuntime,
  "getProviders" | "getProvider" | "login" | "logout" | "listCredentials"
>;

export interface ProviderAuthManagerOptions {
  modelRuntime: ProviderAuthRuntime;
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

function redactSensitiveError(message: string): string {
  return message
    .replace(/(code|token|access_token|refresh_token)=([^&\s]+)/gi, "$1=<redacted>")
    .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, "Bearer <redacted>");
}

function flowTypeForProvider(_provider: Provider): ProviderAuthFlowType {
  return "oauth";
}

export class ProviderAuthManager {
  private readonly modelRuntime: ProviderAuthRuntime;
  private readonly onCredentialsChanged: () => Promise<void> | void;
  private readonly getKnownApiKeyProviderIds: () => string[];
  private readonly openBrowser: (url: string) => Promise<void> | void;
  private readonly flowStore: ProviderAuthFlowStore;

  constructor(options: ProviderAuthManagerOptions) {
    this.modelRuntime = options.modelRuntime;
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

    const providers = new Map<string, ProviderAuthProviderInfo>();
    for (const provider of this.modelRuntime.getProviders()) {
      providers.set(provider.id, {
        id: provider.id,
        name: provider.name || prettifyProviderName(provider.id),
        supportsApiKey: provider.auth.apiKey?.login !== undefined,
        oauth: provider.auth.oauth
          ? {
              flowType: flowTypeForProvider(provider),
              supportsServerBrowserLaunch: true,
              supportsPhoneBrowserLaunch: true,
              supportsManualCodeInput: true,
              mayPromptForInput: true,
            }
          : undefined,
      });
    }

    for (const providerId of this.getKnownApiKeyProviderIds()) {
      if (providers.has(providerId)) continue;
      providers.set(providerId, {
        id: providerId,
        name: prettifyProviderName(providerId),
        supportsApiKey: true,
      });
    }

    return [...providers.values()].sort((a, b) => a.id.localeCompare(b.id));
  }

  async getStatus(): Promise<ProviderAuthProviderStatus[]> {
    this.flowStore.prune();

    const providers = this.listProviders();
    const credentials = new Map(
      (await this.modelRuntime.listCredentials()).map((credential) => [
        credential.providerId,
        credential,
      ]),
    );
    const providerIds = new Set([
      ...providers.map((provider) => provider.id),
      ...credentials.keys(),
    ]);

    return [...providerIds]
      .map((providerId) => {
        const info = providers.find((provider) => provider.id === providerId);
        const credential = credentials.get(providerId);
        return {
          ...(info ?? {
            id: providerId,
            name: prettifyProviderName(providerId),
            supportsApiKey: true,
          }),
          authenticated: credential !== undefined,
          ...(credential ? { credentialType: credential.type } : {}),
        } satisfies ProviderAuthProviderStatus;
      })
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  startFlow(providerId: string, launchMode: ProviderAuthLaunchMode): ProviderAuthFlowSnapshot {
    const normalizedProviderId = providerId.trim();
    if (!normalizedProviderId) {
      throw new ProviderAuthError(400, "providerId is required");
    }

    this.flowStore.prune();

    const provider = this.modelRuntime.getProvider(normalizedProviderId);
    if (!provider?.auth.oauth) {
      throw new ProviderAuthError(404, `Unknown OAuth provider: ${normalizedProviderId}`);
    }

    const active = this.flowStore.findActiveByProvider(normalizedProviderId);
    if (active) {
      this.flowStore.markCancelled(active.flowId, "Superseded by a new login attempt");
    }

    const record = this.flowStore.create(
      normalizedProviderId,
      flowTypeForProvider(provider),
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

    const provider = this.modelRuntime.getProvider(normalizedProviderId);
    if (!provider?.auth.apiKey?.login) {
      throw new ProviderAuthError(404, `Unknown API-key provider: ${normalizedProviderId}`);
    }

    await this.modelRuntime.login(normalizedProviderId, "api_key", {
      prompt: async () => normalizedKey,
      notify: () => {},
    });
    await this.refreshAfterCredentialChange();
  }

  async removeCredential(providerId: string): Promise<void> {
    const normalizedProviderId = providerId.trim();
    if (!normalizedProviderId) {
      throw new ProviderAuthError(400, "providerId is required");
    }

    await this.modelRuntime.logout(normalizedProviderId);
    await this.refreshAfterCredentialChange();
  }

  private async runLogin(flowId: string, providerId: string): Promise<void> {
    const existing = this.flowStore.get(flowId);
    if (!existing) {
      return;
    }

    const interaction: AuthInteraction = {
      signal: existing.abortController.signal,
      notify: (event) => this.handleAuthEvent(flowId, providerId, event),
      prompt: (prompt) => this.requestAuthPrompt(flowId, prompt),
    };

    try {
      await this.modelRuntime.login(providerId, "oauth", interaction);

      const current = this.flowStore.get(flowId);
      if (!current || isTerminalProviderAuthStatus(current.snapshot.status)) return;

      this.flowStore.markCompleted(flowId);
      await this.refreshAfterCredentialChange();
    } catch (error) {
      const current = this.flowStore.get(flowId);
      if (!current || isTerminalProviderAuthStatus(current.snapshot.status)) return;

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

  private handleAuthEvent(flowId: string, providerId: string, event: AuthEvent): void {
    if (event.type === "auth_url") {
      const snapshot = this.flowStore.setAuthInfo(flowId, {
        url: event.url,
        ...(event.instructions ? { instructions: event.instructions } : {}),
      });
      if (!snapshot) return;

      const record = this.flowStore.get(flowId);
      if (record?.launchMode === "server_browser" && !record.browserOpened) {
        record.browserOpened = true;
        void Promise.resolve()
          .then(() => this.openBrowser(event.url))
          .catch((error: unknown) => {
            log.warn("provider_auth.open_browser.failed", {
              flowId,
              providerId,
              error: safeErrorMessage(error),
            });
            this.flowStore.setProgress(flowId, "Could not open browser on server");
          });
      }
      return;
    }

    if (event.type === "device_code") {
      this.flowStore.setAuthInfo(flowId, {
        url: event.verificationUri,
        instructions: `Enter code ${event.userCode}`,
      });
      return;
    }

    this.flowStore.setProgress(flowId, event.message);
  }

  private requestAuthPrompt(flowId: string, prompt: AuthPrompt): Promise<string> {
    if (prompt.type === "manual_code") {
      return this.waitForManualCode(flowId, prompt.signal);
    }

    const options =
      prompt.type === "select"
        ? prompt.options.map((option) => ({ id: option.id, label: option.label }))
        : undefined;
    return this.waitForPromptResponse(
      flowId,
      {
        message: prompt.message,
        ...(prompt.type !== "select" && prompt.placeholder
          ? { placeholder: prompt.placeholder }
          : {}),
        ...(prompt.type === "text" ? { allowEmpty: true } : {}),
        ...(options ? { options } : {}),
      },
      prompt.signal,
    ).then((response) => {
      if (!options) return response;
      const normalized = response.trim();
      return (
        options.find((option) => option.id === normalized || option.label === normalized)?.id ??
        normalized
      );
    });
  }

  private async waitForPromptResponse(
    flowId: string,
    promptShape: ProviderAuthPrompt,
    signal?: AbortSignal,
  ): Promise<string> {
    const record = this.flowStore.get(flowId);
    if (!record || isTerminalProviderAuthStatus(record.snapshot.status)) {
      throw new Error("Login flow is no longer active");
    }

    const waiter = createDeferred<string>();
    this.flowStore.setPromptWaiter(flowId, promptShape, waiter);
    return this.waitForAuthInput(waiter, signal, () => {
      this.flowStore.clearPromptWaiter(flowId);
    });
  }

  private async waitForManualCode(flowId: string, signal?: AbortSignal): Promise<string> {
    const record = this.flowStore.get(flowId);
    if (!record || isTerminalProviderAuthStatus(record.snapshot.status)) {
      throw new Error("Login flow is no longer active");
    }

    const waiter = createDeferred<string>();
    this.flowStore.setManualCodeWaiter(flowId, waiter);
    return this.waitForAuthInput(waiter, signal, () => {
      this.flowStore.clearManualCodeWaiter(flowId);
    });
  }

  private async waitForAuthInput(
    waiter: Deferred<string>,
    signal: AbortSignal | undefined,
    clear: () => void,
  ): Promise<string> {
    const abort = (): void => {
      waiter.reject(new Error("Authentication prompt cancelled"));
      clear();
    };
    if (signal?.aborted) {
      abort();
    } else {
      signal?.addEventListener("abort", abort, { once: true });
    }

    try {
      return await waiter.promise;
    } finally {
      signal?.removeEventListener("abort", abort);
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
