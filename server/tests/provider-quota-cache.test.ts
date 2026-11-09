import { afterEach, describe, expect, it, vi } from "vitest";
import {
  fetchProviderQuotas,
  fetchXaiProviderQuota,
  type ProviderQuota,
  type ProviderQuotaAdapter,
} from "../src/provider-quota.js";
import { ProviderQuotaCache, QUOTA_CACHE_TTL_MS } from "../src/provider-quota/cache.js";

function quota(providerId: string, planType: string, fetchedAt = 0): ProviderQuota {
  return {
    providerId,
    displayName: providerId,
    authenticated: true,
    planType,
    windows: [],
    credits: null,
    prepaidBalanceCents: null,
    fetchedAt,
  };
}

/** An adapter whose every fetch stays pending until the test settles it. */
function controlledAdapter(providerId: string) {
  const pending: Array<(value: ProviderQuota | Error) => void> = [];
  const adapter: ProviderQuotaAdapter = {
    providerId,
    displayName: providerId,
    fetch: () =>
      new Promise<ProviderQuota>((resolve, reject) => {
        pending.push((value) => (value instanceof Error ? reject(value) : resolve(value)));
      }),
  };
  return {
    adapter,
    calls: () => pending.length,
    settle: (index: number, value: ProviderQuota | Error) => pending[index]!(value),
  };
}

function harness() {
  let clock = 1_000_000;
  const cache = new ProviderQuotaCache(() => clock);
  const fetched: Array<{ providerId: string; durationMs: number; ok: boolean }> = [];
  const run = (adapters: ProviderQuotaAdapter[], deadlineMs = 4_000) =>
    fetchProviderQuotas({
      modelRuntime: { getAuth: vi.fn() },
      now: () => clock,
      adapters,
      cache,
      deadlineMs,
      onAdapterFetched: (entry) => fetched.push(entry),
    });
  return { cache, fetched, run, advance: (ms: number) => (clock += ms) };
}

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

afterEach(() => vi.useRealTimers());

describe("provider quota cache", () => {
  it("serves a fresh snapshot without another upstream fetch", async () => {
    const { run, advance } = harness();
    const source = controlledAdapter("alpha");

    const first = run([source.adapter]);
    await flush();
    source.settle(0, quota("alpha", "pro"));
    expect((await first).providers[0]?.planType).toBe("pro");

    advance(QUOTA_CACHE_TTL_MS - 1);
    expect((await run([source.adapter])).providers[0]?.planType).toBe("pro");
    expect(source.calls()).toBe(1);
  });

  it("answers a stale snapshot immediately and refreshes in the background", async () => {
    const { run, advance } = harness();
    const source = controlledAdapter("alpha");
    const first = run([source.adapter]);
    await flush();
    source.settle(0, quota("alpha", "old"));
    await first;

    advance(QUOTA_CACHE_TTL_MS);
    const stale = await run([source.adapter]);
    expect(stale.providers[0]?.planType).toBe("old");
    expect(source.calls()).toBe(2);

    source.settle(1, quota("alpha", "new"));
    await flush();
    expect((await run([source.adapter])).providers[0]?.planType).toBe("new");
    expect(source.calls()).toBe(2);
  });

  it("keeps the last good snapshot when a refresh fails", async () => {
    const { run, advance } = harness();
    const source = controlledAdapter("alpha");
    const first = run([source.adapter]);
    await flush();
    source.settle(0, quota("alpha", "good"));
    await first;

    advance(QUOTA_CACHE_TTL_MS);
    await run([source.adapter]);
    source.settle(1, new Error("upstream down"));
    await flush();

    const next = await run([source.adapter]);
    expect(next.providers[0]?.planType).toBe("good");
    expect(next.providers[0]?.error).toBeUndefined();
  });

  it("shares one upstream fetch between concurrent requests", async () => {
    const { run } = harness();
    const source = controlledAdapter("alpha");

    const a = run([source.adapter]);
    const b = run([source.adapter]);
    await flush();
    expect(source.calls()).toBe(1);

    source.settle(0, quota("alpha", "pro"));
    expect((await a).providers[0]?.planType).toBe("pro");
    expect((await b).providers[0]?.planType).toBe("pro");
  });

  it("drops snapshots and in-flight results on invalidate", async () => {
    const { run, cache } = harness();
    const source = controlledAdapter("alpha");
    const first = run([source.adapter]);
    await flush();
    source.settle(0, quota("alpha", "before"));
    await first;

    cache.invalidate();
    const second = run([source.adapter]);
    await flush();
    expect(source.calls()).toBe(2);
    // Invalidated while the second fetch is running: its result answers this request only.
    cache.invalidate();
    source.settle(1, quota("alpha", "raced"));
    expect((await second).providers[0]?.planType).toBe("raced");

    const third = run([source.adapter]);
    await flush();
    expect(source.calls()).toBe(3);
    source.settle(2, quota("alpha", "after"));
    expect((await third).providers[0]?.planType).toBe("after");
  });

  it("returns providers that answered and marks the slow one when the deadline passes", async () => {
    vi.useFakeTimers();
    const { run, fetched } = harness();
    const fast = controlledAdapter("fast");
    const slow = controlledAdapter("slow");

    const pending = run([fast.adapter, slow.adapter], 4_000);
    await vi.advanceTimersByTimeAsync(0);
    fast.settle(0, quota("fast", "pro"));
    await vi.advanceTimersByTimeAsync(4_000);

    const result = await pending;
    expect(result.providers.map((p) => [p.providerId, p.planType, p.error !== undefined])).toEqual([
      ["fast", "pro", false],
      ["slow", null, true],
    ]);
    expect(result.providers[1]?.authenticated).toBe(true);

    // The slow fetch lands later, is recorded, and answers the next request.
    slow.settle(0, quota("slow", "late"));
    await vi.advanceTimersByTimeAsync(0);
    expect(fetched.map((f) => [f.providerId, f.ok])).toEqual([
      ["fast", true],
      ["slow", true],
    ]);
    const next = await run([fast.adapter, slow.adapter]);
    expect(next.providers.map((p) => p.planType)).toEqual(["pro", "late"]);
    expect(slow.calls()).toBe(1);
  });

  it("records each upstream fetch duration and outcome", async () => {
    const { run, fetched, advance } = harness();
    const ok = controlledAdapter("ok");
    const bad = controlledAdapter("bad");
    const pending = run([ok.adapter, bad.adapter]);
    await flush();
    advance(250);
    ok.settle(0, quota("ok", "pro"));
    bad.settle(0, new Error("boom"));
    await pending;
    expect(fetched).toEqual([
      { providerId: "ok", durationMs: 250, ok: true },
      { providerId: "bad", durationMs: 250, ok: false },
    ]);
  });
});

describe("xAI plan lookup", () => {
  it("starts the settings request together with billing", async () => {
    const urls: string[] = [];
    const releases: Array<() => void> = [];
    const fetchImpl = vi.fn((input: string | URL | Request) => {
      const url = String(input);
      urls.push(url);
      return new Promise<Response>((resolve) => {
        releases.push(() =>
          resolve(
            new Response(
              JSON.stringify(
                url.includes("settings")
                  ? { subscription_tier_display: "SuperGrok" }
                  : {
                      config: {
                        monthlyLimit: { val: 15000 },
                        used: { val: 7277 },
                        onDemandCap: { val: 0 },
                        billingPeriodStart: "2026-07-01T00:00:00+00:00",
                        billingPeriodEnd: "2026-08-01T00:00:00+00:00",
                      },
                    },
              ),
              { status: 200 },
            ),
          ),
        );
      });
    });
    const pending = fetchXaiProviderQuota({
      modelRuntime: { getAuth: vi.fn(async () => ({ auth: { apiKey: "t" }, source: "OAuth" })) },
      readCredential: () => ({ type: "oauth", access: "t", refresh: "r", expires: 9e12 }) as never,
      fetchImpl: fetchImpl as never,
      now: () => 1,
    });
    await flush();
    await flush();
    // Nothing has answered yet, so all three requests were started up front.
    expect(urls).toHaveLength(3);
    expect(urls.some((url) => url.includes("settings"))).toBe(true);
    for (const release of releases) release();
    expect((await pending).planType).toBe("SuperGrok");
  });
});
