/**
 * Choose the STT adapter for a dictation take.
 *
 * Yuwp keeps the stateful session API. xAI STT uses existing Pi/Oppi provider
 * credentials (`ModelRuntime.getAuth`, same store as models).
 */

import { readStoredCredential } from "@earendil-works/pi-coding-agent";
import { resolveAsrProvider, type DictationConfig } from "./dictation-types.js";
import { StreamingSttProvider, type SttProvider } from "./stt-provider.js";
import {
  DEFAULT_XAI_STT_ENDPOINT,
  DEFAULT_XAI_STT_MODEL,
  XaiSttProvider,
  type SttWebSocketFactory,
} from "./xai-stt-provider.js";

/** Voice providers that authenticate with the server's model-provider credentials. */
export type SttAuthProviderId = "xai" | "openrouter";

/** Each provider's environment-variable key, as Pi reads it for models. */
const ENV_API_KEYS: Record<SttAuthProviderId, string> = {
  xai: "XAI_API_KEY",
  openrouter: "OPENROUTER_API_KEY",
};

export type SttGetAuth = (
  providerId: SttAuthProviderId,
) => Promise<{ auth?: { apiKey?: string } } | undefined>;

export interface CreateSttProviderDeps {
  fetchFn?: typeof globalThis.fetch;
  resolveApiKey?: (
    providerId: SttAuthProviderId,
  ) => string | undefined | Promise<string | undefined>;
  getAuth?: SttGetAuth;
  createWebSocket?: SttWebSocketFactory;
}

function storedBearer(providerId: string): string | undefined {
  const stored = readStoredCredential(providerId);
  if (!stored) return undefined;
  if (stored.type === "api_key") {
    const key = stored.key?.trim();
    return key || undefined;
  }
  if (stored.type === "oauth") {
    const access = stored.access?.trim();
    return access || undefined;
  }
  return undefined;
}

export function resolveSttProviderApiKey(providerId: SttAuthProviderId): string | undefined {
  const primary = storedBearer(providerId);
  if (primary) return primary;
  return process.env[ENV_API_KEYS[providerId]]?.trim() || undefined;
}

/** Pi/Oppi provider auth first (API key or refreshed OAuth access token), then stored/env fallback. */
export async function resolveSttBearerToken(
  providerId: SttAuthProviderId,
  deps: {
    getAuth?: SttGetAuth;
    fallback?: (providerId: SttAuthProviderId) => string | undefined;
  } = {},
): Promise<string | undefined> {
  if (deps.getAuth) {
    try {
      const auth = await deps.getAuth(providerId);
      const key = auth?.auth?.apiKey?.trim();
      if (key) return key;
    } catch {
      // Fall through to stored API key / env.
    }
  }
  return (deps.fallback ?? resolveSttProviderApiKey)(providerId);
}

/**
 * Whether a configured voice provider has its credentials: xAI needs a sign-in,
 * stored key, or XAI_API_KEY; OpenRouter a stored key or OPENROUTER_API_KEY; an HTTP backend
 * needs only its endpoint. `VoiceBackendHealth` reports a cloud backend without one as
 * `needs_credentials`, so the app never shows a voice control that would fail for a missing
 * login.
 */
export async function hasVoiceProviderCredential(
  provider: "http" | SttAuthProviderId,
  getAuth?: SttGetAuth,
): Promise<boolean> {
  if (provider === "http") return true;
  return (await resolveSttBearerToken(provider, { getAuth })) !== undefined;
}

export function createSttProvider(
  config: DictationConfig,
  deps: CreateSttProviderDeps = {},
): SttProvider {
  const provider = resolveAsrProvider(config);
  if (!provider) throw new Error("STT provider must be http or xai");
  const resolveApiKey = (
    providerId: SttAuthProviderId,
  ): string | undefined | Promise<string | undefined> => {
    if (deps.resolveApiKey) return deps.resolveApiKey(providerId);
    return resolveSttBearerToken(providerId, { getAuth: deps.getAuth });
  };

  if (provider === "xai") {
    return new XaiSttProvider({
      endpoint: config.sttEndpoint || DEFAULT_XAI_STT_ENDPOINT,
      model: config.sttModel || DEFAULT_XAI_STT_MODEL,
      resolveApiKey: () => resolveApiKey("xai"),
      createWebSocket: deps.createWebSocket,
    });
  }

  const endpoint = config.sttEndpoint?.trim();
  if (!endpoint) {
    throw new Error("STT http provider requires asr.sttEndpoint");
  }
  return new StreamingSttProvider({ endpoint, model: config.sttModel }, deps.fetchFn);
}
