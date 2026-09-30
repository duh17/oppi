import type {
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaWindow,
} from "../types.js";
import {
  credentialType,
  emptyProviderQuota,
  finalizeProviderQuota,
  resolveQuotaFetchDeps,
} from "../shared.js";
import { codexProviderQuotaAdapter } from "./codex.js";

const OPENAI_PROVIDER_ID = "openai";
const OPENAI_CHATGPT_USAGE_URL = "https://chatgpt.com/settings/usage";

/**
 * Official "Sign in with ChatGPT" (OAuth on the `openai` provider) sends its token to
 * api.openai.com/v1 only. No supported quota API was identified for that flow, and OpenAI says
 * not to call ChatGPT `backend-api` endpoints with the token
 * (https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).
 * This adapter therefore makes no network call and never reads or forwards the access token;
 * quota stays unknown and points users at ChatGPT settings.
 *
 * An operator can opt in to plan-wide numbers from the legacy Codex connection; see
 * `withLegacyCodexPlanQuota`. That is a separate, explicit path that reuses the Codex row.
 */
const CHATGPT_QUOTA_UNAVAILABLE =
  `ChatGPT plan usage is unavailable: no supported quota API was identified for Sign in with ChatGPT. ` +
  `Check ${OPENAI_CHATGPT_USAGE_URL}.`;

export async function fetchOpenAIProviderQuota(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuota> {
  const { readCredential, fetchedAt } = resolveQuotaFetchDeps(options);
  const displayName = "OpenAI";
  const credential = readCredential(OPENAI_PROVIDER_ID);

  // Only a ChatGPT OAuth sign-in is subscription-backed. API keys bill per token and have
  // no subscription window, so they must not surface as subscription quota.
  if (credentialType(credential) !== "oauth") {
    return finalizeProviderQuota(
      emptyProviderQuota(OPENAI_PROVIDER_ID, displayName, fetchedAt, false),
    );
  }

  return finalizeProviderQuota(
    emptyProviderQuota(OPENAI_PROVIDER_ID, displayName, fetchedAt, true, CHATGPT_QUOTA_UNAVAILABLE),
  );
}

export const openAIProviderQuotaAdapter: ProviderQuotaAdapter = {
  providerId: OPENAI_PROVIDER_ID,
  displayName: "OpenAI",
  fetch: fetchOpenAIProviderQuota,
};

const PLAN_DISPLAY_NAME = "OpenAI (ChatGPT plan via legacy Codex)";
const PLAN_SOURCE_SUFFIX = "(via legacy Codex)";

function planUnavailable(official: ProviderQuota, reason: string): ProviderQuota {
  return emptyProviderQuota(
    OPENAI_PROVIDER_ID,
    PLAN_DISPLAY_NAME,
    official.fetchedAt,
    true,
    `ChatGPT plan usage via legacy Codex is unavailable: ${reason} ` +
      `Check ${OPENAI_CHATGPT_USAGE_URL}.`,
  );
}

function relabelPlanWindow(window: ProviderQuotaWindow): ProviderQuotaWindow {
  return {
    ...window,
    shortLabel: `Plan ${window.shortLabel}`,
    title: `${window.title} plan ${PLAN_SOURCE_SUFFIX}`,
  };
}

/**
 * Opt-in (`providerQuotas.openaiUseCodexPlan`): report the legacy Codex connection's plan windows
 * on the official `openai` row. The operator confirms both sign-ins are the same ChatGPT
 * account/workspace; nothing here infers or verifies that pairing.
 *
 * Reuses the Codex row the aggregator already fetched, so there is no second upstream request
 * and the official token is never sent anywhere. The numbers are plan-wide, not Pi's
 * app-specific cap, so the display name, window titles, and short labels say so. A missing,
 * unauthenticated, or failed source is surfaced as an error, never as stale or empty-success
 * quota. Rows without a stored official OAuth credential (API key, none, unreadable) pass through untouched.
 */
export function withLegacyCodexPlanQuota(
  providers: readonly ProviderQuota[],
  adapters: readonly ProviderQuotaAdapter[],
  options: FetchProviderQuotasOptions,
): ProviderQuota[] {
  // A custom `openai` provider owns its own quota; only the built-in adapter is rewritten.
  if (!adapters.includes(openAIProviderQuotaAdapter)) return [...providers];

  const codexAdapter = adapters.includes(codexProviderQuotaAdapter)
    ? codexProviderQuotaAdapter
    : undefined;
  const codex = codexAdapter
    ? providers.find((provider) => provider.providerId === codexAdapter.providerId)
    : undefined;

  // `authenticated` alone is not proof: the aggregator also marks a thrown adapter as
  // authenticated. Check the stored official credential itself, and keep the official row as
  // fetched when it cannot be read.
  const { readCredential } = resolveQuotaFetchDeps(options);
  const officialIsOAuth = (): boolean => {
    try {
      return credentialType(readCredential(OPENAI_PROVIDER_ID)) === "oauth";
    } catch {
      return false;
    }
  };

  return providers.map((provider) => {
    if (provider.providerId !== OPENAI_PROVIDER_ID || !officialIsOAuth()) return provider;

    if (!codex) return planUnavailable(provider, "the legacy Codex quota source is not available.");
    if (!codex.authenticated) {
      return planUnavailable(provider, "the legacy Codex connection is not signed in.");
    }
    if (codex.error) return planUnavailable(provider, codex.error);
    if (codex.windows.length === 0) {
      return planUnavailable(provider, "the legacy Codex source returned no usage windows.");
    }

    return finalizeProviderQuota({
      providerId: OPENAI_PROVIDER_ID,
      displayName: PLAN_DISPLAY_NAME,
      authenticated: true,
      planType: codex.planType,
      windows: codex.windows.map(relabelPlanWindow),
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt: provider.fetchedAt,
    });
  });
}
