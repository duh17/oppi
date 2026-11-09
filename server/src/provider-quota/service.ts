import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { createLogger } from "../logger.js";
import { ProviderQuotaCache } from "./cache.js";
import { fetchProviderQuotas, quotaAdaptersForProviders } from "./fetch.js";
import type { ProviderQuotaAdapter, ProviderQuotasStatus } from "./types.js";
import type { ProviderRegistrationMetadata } from "./fetch.js";

/** The server's ModelRuntime serves both: auth for the adapters, registration metadata for ownership. */
type QuotaRuntime = Pick<ModelRuntime, "getAuth" | "hasConfiguredAuth"> &
  ProviderRegistrationMetadata;

const log = createLogger({ base: { component: "provider_quota" } });

/** What the service reads from the extension provider catalog (which the server builds later). */
interface QuotaProviderCatalog {
  sync(): Promise<unknown>;
  getRegisteredProviderIds(): readonly string[];
  getQuotaAdapters(modelRuntime: QuotaRuntime): ProviderQuotaAdapter[];
}

/**
 * Owns GET /server/provider-quotas: the per-provider snapshot cache and the upstream fetch.
 * Dependencies are read per call because the server creates the catalog and runtime after
 * this service. `invalidate()` is for credential and extension-provider changes.
 */
export class ProviderQuotaService {
  private readonly cache = new ProviderQuotaCache();

  constructor(
    private readonly deps: {
      catalog: () => QuotaProviderCatalog;
      modelRuntime: () => QuotaRuntime;
      openaiUseCodexPlan: () => boolean;
    },
  ) {}

  invalidate(): void {
    this.cache.invalidate();
  }

  async status(): Promise<ProviderQuotasStatus> {
    const catalog = this.deps.catalog();
    const modelRuntime = this.deps.modelRuntime();
    await catalog.sync();
    return fetchProviderQuotas({
      modelRuntime,
      openaiUseCodexPlan: this.deps.openaiUseCodexPlan(),
      cache: this.cache,
      // Names the slow upstream when the page is slow; cache hits never reach here.
      onAdapterFetched: (fetch) => log.info("provider_quota.fetched", fetch),
      adapters: quotaAdaptersForProviders(
        catalog.getRegisteredProviderIds(),
        catalog.getQuotaAdapters(modelRuntime),
        modelRuntime,
      ),
    });
  }
}
