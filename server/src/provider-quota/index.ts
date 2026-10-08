/**
 * Provider usage quotas for Model Providers + model picker.
 *
 * Extension path (next provider):
 * - Implement `ProviderQuotaAdapter` in `adapters/<id>.ts`
 * - Append it in `adapters/registry.ts`
 * - Match `providerId` to model/provider-auth ids
 * - Apple detail shows all windows; picker shows the shortest window
 */

export type {
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaPacing,
  ProviderQuotasStatus,
  ProviderQuotaWindow,
} from "./types.js";

export { deriveProviderQuotaPacing, normalizeProviderQuotaWindows } from "./shared.js";

export { fetchProviderQuotas, quotaAdaptersForProviders } from "./fetch.js";
export { defaultProviderQuotaAdapters } from "./adapters/registry.js";
export { fetchCodexProviderQuota } from "./adapters/codex.js";
export { fetchOpenAIProviderQuota } from "./adapters/openai.js";
export { fetchOpenCodeGoProviderQuota } from "./adapters/opencode-go.js";
export { fetchXaiProviderQuota } from "./adapters/xai.js";
