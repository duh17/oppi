import { safeErrorMessage } from "../log-utils.js";
import { defaultProviderQuotaAdapters } from "./adapters/registry.js";
import { withLegacyCodexPlanQuota } from "./adapters/openai.js";
import { emptyProviderQuota, finalizeProviderQuota } from "./shared.js";
import type {
  FetchProviderQuotasOptions,
  ProviderQuota,
  ProviderQuotaAdapter,
  ProviderQuotasStatus,
} from "./types.js";

function stampAdapterIdentity(adapter: ProviderQuotaAdapter, quota: ProviderQuota): ProviderQuota {
  // Registry metadata is authoritative so a mis-implemented adapter cannot drift ids.
  return {
    ...quota,
    providerId: adapter.providerId,
    displayName: adapter.displayName,
  };
}

async function fetchAdapterQuota(
  adapter: ProviderQuotaAdapter,
  options: FetchProviderQuotasOptions,
  fetchedAt: number,
): Promise<ProviderQuota> {
  try {
    const quota = await adapter.fetch(options);
    return finalizeProviderQuota(stampAdapterIdentity(adapter, quota));
  } catch (error) {
    // One bad adapter must not hide healthy providers from /server/provider-quotas.
    return finalizeProviderQuota(
      emptyProviderQuota(
        adapter.providerId,
        adapter.displayName,
        fetchedAt,
        true,
        `${adapter.displayName} quota fetch failed: ${safeErrorMessage(error)}`,
      ),
    );
  }
}

/** A custom provider owns its credentials; never pass them to a built-in quota endpoint. */
export function quotaAdaptersForProviders(
  registeredProviderIds: readonly string[],
  extensionAdapters: readonly ProviderQuotaAdapter[],
): readonly ProviderQuotaAdapter[] {
  const registered = new Set(registeredProviderIds);
  return [
    ...defaultProviderQuotaAdapters.filter((adapter) => !registered.has(adapter.providerId)),
    ...extensionAdapters,
  ];
}

export async function fetchProviderQuotas(
  options: FetchProviderQuotasOptions,
): Promise<ProviderQuotasStatus> {
  const now = options.now ?? Date.now;
  const fetchedAt = now();
  const adapters = options.adapters ?? defaultProviderQuotaAdapters;
  const providers = await Promise.all(
    adapters.map((adapter) => fetchAdapterQuota(adapter, options, fetchedAt)),
  );

  return {
    providers: options.openaiUseCodexPlan
      ? withLegacyCodexPlanQuota(providers, adapters, options)
      : providers,
    fetchedAt,
  };
}
