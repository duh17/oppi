import type { ProviderQuota } from "./types.js";

/** A snapshot younger than this is served without touching the upstream. */
export const QUOTA_CACHE_TTL_MS = 60_000;

/** The page's request waits at most this long for a provider that has never answered. */
export const QUOTA_DEADLINE_MS = 4_000;

interface Entry {
  quota: ProviderQuota;
  storedAt: number;
}

/**
 * Per-provider quota snapshots with stale-while-revalidate and single-flight refresh.
 *
 * - Fresh entry: returned as is.
 * - Stale entry: returned at once while one background refresh runs.
 * - No entry: wait for the (shared) fetch, up to the deadline; `undefined` means it is
 *   still running and will populate the cache when it lands.
 *
 * Only successful snapshots are kept; a failed refresh leaves the last good one in place,
 * and its own `fetchedAt` tells the client how old it is. `invalidate()` drops everything,
 * including results of fetches already in flight, so a credential or provider change is
 * never answered with data fetched under the old one.
 */
export class ProviderQuotaCache {
  private readonly entries = new Map<string, Entry>();
  private readonly inflight = new Map<string, Promise<ProviderQuota>>();
  private generation = 0;

  constructor(
    private readonly now: () => number = Date.now,
    private readonly ttlMs: number = QUOTA_CACHE_TTL_MS,
  ) {}

  invalidate(): void {
    this.generation += 1;
    this.entries.clear();
    this.inflight.clear();
  }

  /** `load` must not reject; the aggregator turns adapter errors into error quotas. */
  async get(
    providerId: string,
    load: () => Promise<ProviderQuota>,
    deadlineMs: number,
  ): Promise<ProviderQuota | undefined> {
    const entry = this.entries.get(providerId);
    if (entry) {
      if (this.now() - entry.storedAt >= this.ttlMs) void this.refresh(providerId, load);
      return entry.quota;
    }
    return raceDeadline(this.refresh(providerId, load), deadlineMs);
  }

  private refresh(providerId: string, load: () => Promise<ProviderQuota>): Promise<ProviderQuota> {
    const running = this.inflight.get(providerId);
    if (running) return running;

    const generation = this.generation;
    const run = load().then((quota) => {
      if (generation === this.generation) {
        this.inflight.delete(providerId);
        if (!quota.error) this.entries.set(providerId, { quota, storedAt: this.now() });
      }
      return quota;
    });
    this.inflight.set(providerId, run);
    return run;
  }
}

function raceDeadline<T>(work: Promise<T>, deadlineMs: number): Promise<T | undefined> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve(undefined), deadlineMs);
    work.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
