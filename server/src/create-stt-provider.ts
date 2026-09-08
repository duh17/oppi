/**
 * Choose the STT adapter for a dictation take.
 *
 * Yuwp keeps the stateful session API. OpenAI transcriptions and xAI STT use
 * existing Pi/Oppi provider credentials (`ModelRuntime.getAuth`, same store
 * as models). The OpenAI dictation provider id is `openai-codex`.
 */

import { readStoredCredential } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_OPENAI_STT_ENDPOINT,
  DEFAULT_OPENAI_STT_MODEL,
  OpenAiSttProvider,
} from "./openai-stt-provider.js";
import { resolveAsrProvider, type DictationConfig } from "./dictation-types.js";
import { StreamingSttProvider, type SttProvider } from "./stt-provider.js";
import {
  DEFAULT_XAI_STT_ENDPOINT,
  DEFAULT_XAI_STT_MODEL,
  XaiSttProvider,
  type SttWebSocketFactory,
} from "./xai-stt-provider.js";

export type SttAuthProviderId = "openai-codex" | "xai";

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
  if (providerId === "openai-codex") {
    const openaiKey = storedBearer("openai");
    if (openaiKey) return openaiKey;
    return process.env.OPENAI_API_KEY?.trim() || undefined;
  }
  return process.env.XAI_API_KEY?.trim() || undefined;
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

export function createSttProvider(
  config: DictationConfig,
  deps: CreateSttProviderDeps = {},
): SttProvider {
  const provider = resolveAsrProvider(config);
  const resolveApiKey = (
    providerId: SttAuthProviderId,
  ): string | undefined | Promise<string | undefined> => {
    if (deps.resolveApiKey) return deps.resolveApiKey(providerId);
    return resolveSttBearerToken(providerId, { getAuth: deps.getAuth });
  };

  if (provider === "openai-codex") {
    return new OpenAiSttProvider(
      {
        endpoint: config.sttEndpoint || DEFAULT_OPENAI_STT_ENDPOINT,
        model: config.sttModel || DEFAULT_OPENAI_STT_MODEL,
        resolveApiKey: () => resolveApiKey("openai-codex"),
      },
      deps.fetchFn,
    );
  }

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
