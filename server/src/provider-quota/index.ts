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
  FetchLike,
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotaCredits,
  ProviderQuotasStatus,
  ProviderQuotaWindow,
  ProviderQuotaWindowKey,
  QuotaModelRuntime,
} from "./types.js";

export {
  clampPercent,
  emptyProviderQuota,
  finalizeProviderQuota,
  makeProviderQuotaWindow,
  normalizeProviderQuotaWindows,
  parseIsoToUnixSeconds,
  resolveProviderAccessToken,
  UPSTREAM_TIMEOUT_MS,
} from "./shared.js";

export { fetchProviderQuotas } from "./fetch.js";
export {
  codexProviderQuotaAdapter,
  defaultProviderQuotaAdapters,
  xaiProviderQuotaAdapter,
} from "./adapters/registry.js";
export { fetchCodexProviderQuota } from "./adapters/codex.js";
export { fetchOpenCodeGoProviderQuota } from "./adapters/opencode-go.js";
export { fetchXaiProviderQuota } from "./adapters/xai.js";
