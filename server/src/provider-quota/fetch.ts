import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
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

/** Registration metadata the Pi ModelRuntime already keeps; absent means assume ownership. */
export type ProviderRegistrationMetadata = Pick<
  ModelRuntime,
  "getRegisteredProviderConfig" | "getRegisteredNativeProvider"
>;

/** Keys that change neither auth, endpoint, catalog, nor media of the inherited provider. */
const COMPATIBILITY_REGISTRATION_KEYS = new Set(["api", "name", "streamSimple"]);

/**
 * True when an extension only swaps the stream implementation of a provider it inherits
 * (`registerProvider(id, { api, streamSimple })`). Any auth, endpoint, header, model or
 * media override, or a native provider, makes the extension the provider's owner.
 */
function isStreamCompatibilityRegistration(
  providerId: string,
  metadata: ProviderRegistrationMetadata,
): boolean {
  if (metadata.getRegisteredNativeProvider(providerId)) return false;
  const config = metadata.getRegisteredProviderConfig(providerId);
  if (!config || typeof config.streamSimple !== "function") return false;
  return Object.entries(config).every(
    ([key, value]) => value === undefined || COMPATIBILITY_REGISTRATION_KEYS.has(key),
  );
}

/**
 * A custom provider owns its credentials; never pass them to a built-in quota endpoint.
 * A stream-only compatibility registration inherits the built-in auth and endpoint, so it
 * does not suppress the built-in adapter. An explicit extension quota adapter always
 * replaces the built-in one for its provider id.
 */
export function quotaAdaptersForProviders(
  registeredProviderIds: readonly string[],
  extensionAdapters: readonly ProviderQuotaAdapter[],
  registrationMetadata?: ProviderRegistrationMetadata,
): readonly ProviderQuotaAdapter[] {
  const suppressed = new Set(
    registeredProviderIds.filter(
      (providerId) =>
        !registrationMetadata ||
        !isStreamCompatibilityRegistration(providerId, registrationMetadata),
    ),
  );
  for (const adapter of extensionAdapters) suppressed.add(adapter.providerId);
  return [
    ...defaultProviderQuotaAdapters.filter((adapter) => !suppressed.has(adapter.providerId)),
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
