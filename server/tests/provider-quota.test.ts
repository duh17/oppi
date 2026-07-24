import { describe, expect, it, vi } from "vitest";

import {
  fetchCodexProviderQuota,
  fetchProviderQuotas,
  fetchXaiProviderQuota,
} from "../src/provider-quota.js";

describe("fetchCodexProviderQuota", () => {
  it("returns unauthenticated when no openai-codex credential is stored", async () => {
    const result = await fetchCodexProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => undefined),
      fetchImpl: vi.fn() as never,
      now: () => 123,
    });

    expect(result).toEqual({
      providerId: "openai-codex",
      displayName: "Codex",
      authenticated: false,
      planType: null,
      windows: [],
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt: 123,
    });
  });

  it("maps five-hour and weekly windows from the usage payload", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            plan_type: "prolite",
            rate_limit: {
              primary_window: {
                used_percent: 19,
                limit_window_seconds: 18_000,
                reset_at: 1_746_853_708,
              },
              secondary_window: {
                used_percent: 67,
                limit_window_seconds: 604_800,
                reset_at: 1_746_989_363,
              },
            },
            credits: {
              has_credits: false,
              unlimited: false,
              balance: "0",
            },
          }),
          { status: 200 },
        ),
    ) as never;

    const result = await fetchCodexProviderQuota({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "token_123" }, source: "OAuth" })),
      },
      readCredential: vi.fn(
        () =>
          ({
            type: "oauth",
            refresh: "refresh_123",
            access: "token_123",
            expires: 1_800_000_000_000,
            accountId: "acct_123",
          }) as const,
      ),
      fetchImpl,
      now: () => 999,
    });

    expect(result).toMatchObject({
      providerId: "openai-codex",
      displayName: "Codex",
      authenticated: true,
      planType: "prolite",
      windows: [
        {
          key: "five_hour",
          shortLabel: "5h",
          title: "5-hour",
          usedPercent: 19,
          remainingPercent: 81,
          limitWindowSeconds: 18_000,
          resetAt: 1_746_853_708,
          includeWeekdayInReset: false,
        },
        {
          key: "weekly",
          shortLabel: "7d",
          title: "Weekly",
          usedPercent: 67,
          remainingPercent: 33,
          limitWindowSeconds: 604_800,
          resetAt: 1_746_989_363,
          includeWeekdayInReset: true,
        },
      ],
      credits: {
        hasCredits: false,
        unlimited: false,
        balance: "0",
      },
      fetchedAt: 999,
    });

    expect(fetchImpl).toHaveBeenCalledWith(
      "https://chatgpt.com/backend-api/wham/usage",
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("returns a structured error on non-200 responses", async () => {
    const result = await fetchCodexProviderQuota({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "token_123" }, source: "OAuth" })),
      },
      readCredential: vi.fn(
        () =>
          ({
            type: "oauth",
            refresh: "refresh_123",
            access: "token_123",
            expires: 1_800_000_000_000,
            accountId: "acct_123",
          }) as const,
      ),
      fetchImpl: vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { message: "rate limited" } }), { status: 429 }),
      ) as never,
      now: () => 456,
    });

    expect(result).toEqual({
      providerId: "openai-codex",
      displayName: "Codex",
      authenticated: true,
      planType: null,
      windows: [],
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt: 456,
      error: "Codex quota fetch failed (429): rate limited",
    });
  });
});

describe("fetchXaiProviderQuota", () => {
  it("returns unauthenticated when no xai credential is stored", async () => {
    const result = await fetchXaiProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => undefined),
      fetchImpl: vi.fn() as never,
      now: () => 10,
    });

    expect(result.authenticated).toBe(false);
    expect(result.providerId).toBe("xai");
    expect(result.windows).toEqual([]);
  });

  it("skips api-key credentials because consumer credits require OAuth", async () => {
    const fetchImpl = vi.fn() as never;
    const result = await fetchXaiProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "xai-test" }) as const),
      fetchImpl,
      now: () => 11,
    });

    expect(result).toMatchObject({
      providerId: "xai",
      authenticated: false,
      windows: [],
    });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("maps weekly creditUsagePercent and SuperGrok plan from settings", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-23T23:07:26.243780+00:00",
                end: "2026-07-30T23:07:26.243780+00:00",
              },
              creditUsagePercent: 24,
              prepaidBalance: { val: 150 },
            },
          }),
          { status: 200 },
        );
      }
      if (String(url).includes("/settings")) {
        return new Response(
          JSON.stringify({
            subscription_tier_display: "SuperGrok",
          }),
          { status: 200 },
        );
      }
      return new Response("not found", { status: 404 });
    }) as never;

    const result = await fetchXaiProviderQuota({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "oauth_token" }, source: "OAuth" })),
      },
      readCredential: vi.fn(
        () =>
          ({
            type: "oauth",
            access: "oauth_token",
            refresh: "refresh",
            expires: 1_800_000_000_000,
          }) as const,
      ),
      fetchImpl,
      now: () => 222,
    });

    expect(result).toMatchObject({
      providerId: "xai",
      displayName: "xAI",
      authenticated: true,
      planType: "SuperGrok",
      prepaidBalanceCents: 150,
      fetchedAt: 222,
    });
    expect(result.windows).toHaveLength(1);
    expect(result.windows[0]).toMatchObject({
      key: "weekly",
      shortLabel: "7d",
      title: "Weekly",
      usedPercent: 24,
      remainingPercent: 76,
      includeWeekdayInReset: true,
    });
    expect(result.windows[0]?.resetAt).toBe(
      Math.floor(Date.parse("2026-07-30T23:07:26.243780+00:00") / 1000),
    );
  });

  it("keeps billing quota when optional settings fetch fails", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              creditUsagePercent: 10,
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-23T00:00:00Z",
                end: "2026-07-30T00:00:00Z",
              },
            },
          }),
          { status: 200 },
        );
      }
      if (String(url).includes("/settings")) {
        throw new Error("settings timeout");
      }
      return new Response("nope", { status: 404 });
    }) as never;

    const result = await fetchXaiProviderQuota({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "oauth_token" }, source: "OAuth" })),
      },
      readCredential: vi.fn(
        () =>
          ({
            type: "oauth",
            access: "oauth_token",
            refresh: "refresh",
            expires: 1_800_000_000_000,
          }) as const,
      ),
      fetchImpl,
      now: () => 444,
    });

    expect(result.authenticated).toBe(true);
    expect(result.planType).toBeNull();
    expect(result.error).toBeUndefined();
    expect(result.windows[0]).toMatchObject({
      remainingPercent: 90,
      shortLabel: "7d",
    });
  });

  it("falls back to legacy monthly cents when percent is absent", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              monthlyLimit: { val: 15000 },
              used: { val: 7500 },
              billingPeriodStart: "2026-07-01T00:00:00+00:00",
              billingPeriodEnd: "2026-08-01T00:00:00+00:00",
            },
          }),
          { status: 200 },
        );
      }
      return new Response("{}", { status: 200 });
    }) as never;

    const result = await fetchXaiProviderQuota({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "oauth_token" }, source: "OAuth" })),
      },
      readCredential: vi.fn(
        () =>
          ({
            type: "oauth",
            access: "oauth_token",
            refresh: "refresh",
            expires: 1_800_000_000_000,
          }) as const,
      ),
      fetchImpl,
      now: () => 333,
    });

    expect(result.windows[0]).toMatchObject({
      key: "monthly",
      shortLabel: "30d",
      title: "Monthly",
      usedPercent: 50,
      remainingPercent: 50,
    });
  });
});

describe("fetchProviderQuotas", () => {
  it("aggregates codex and xai quotas", async () => {
    const readCredential = vi.fn((providerId: string) => {
      if (providerId === "openai-codex") {
        return {
          type: "oauth",
          refresh: "r",
          access: "a",
          expires: 1_800_000_000_000,
          accountId: "acct",
        } as const;
      }
      if (providerId === "xai") {
        return {
          type: "oauth",
          refresh: "r",
          access: "a",
          expires: 1_800_000_000_000,
        } as const;
      }
      return undefined;
    });

    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("chatgpt.com")) {
        return new Response(
          JSON.stringify({
            plan_type: "plus",
            rate_limit: {
              primary_window: {
                used_percent: 10,
                limit_window_seconds: 18_000,
                reset_at: 100,
              },
              secondary_window: {
                used_percent: 20,
                limit_window_seconds: 604_800,
                reset_at: 200,
              },
            },
          }),
          { status: 200 },
        );
      }
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              creditUsagePercent: 40,
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-23T00:00:00Z",
                end: "2026-07-30T00:00:00Z",
              },
            },
          }),
          { status: 200 },
        );
      }
      if (String(url).includes("/settings")) {
        return new Response(JSON.stringify({ subscription_tier_display: "SuperGrok" }), {
          status: 200,
        });
      }
      return new Response("nope", { status: 404 });
    }) as never;

    const result = await fetchProviderQuotas({
      modelRuntime: {
        getAuth: vi.fn(async () => ({ auth: { apiKey: "token" }, source: "OAuth" })),
      },
      readCredential,
      fetchImpl,
      now: () => 50,
    });

    expect(result.fetchedAt).toBe(50);
    expect(result.providers.map((p) => p.providerId)).toEqual(["openai-codex", "xai"]);
    expect(result.providers[0]?.windows).toHaveLength(2);
    expect(result.providers[1]?.planType).toBe("SuperGrok");
    expect(result.providers[1]?.windows[0]?.remainingPercent).toBe(60);
  });
});
