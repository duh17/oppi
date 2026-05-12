import { describe, expect, it, vi } from "vitest";

import { fetchCodexUsageStatus } from "../src/codex-usage.js";

describe("fetchCodexUsageStatus", () => {
  it("returns unauthenticated when no openai-codex credential is stored", async () => {
    const result = await fetchCodexUsageStatus({
      authStorage: {
        get: vi.fn(() => undefined),
        getApiKey: vi.fn(async () => undefined),
      } as never,
      fetchImpl: vi.fn() as never,
      now: () => 123,
    });

    expect(result).toEqual({
      providerId: "openai-codex",
      authenticated: false,
      planType: null,
      rateLimitReachedType: null,
      fiveHour: null,
      weekly: null,
      credits: null,
      additionalRateLimits: [],
      fetchedAt: 123,
    });
  });

  it("maps five-hour and weekly windows from the usage payload", async () => {
    const authStorage = {
      get: vi.fn(() => ({ type: "oauth", accountId: "acct_123" })),
      getApiKey: vi.fn(async () => "token_123"),
    } as never;

    const fetchImpl = vi.fn(async () =>
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
          additional_rate_limits: [
            {
              metered_feature: "codex_bengalfox",
              limit_name: "GPT-5.3-Codex-Spark",
              rate_limit: {
                primary_window: {
                  used_percent: 0,
                  limit_window_seconds: 18_000,
                  reset_at: 1_746_857_171,
                },
                secondary_window: {
                  used_percent: 0,
                  limit_window_seconds: 604_800,
                  reset_at: 1_747_461_171,
                },
              },
            },
          ],
        }),
        { status: 200 },
      ),
    ) as never;

    const result = await fetchCodexUsageStatus({
      authStorage,
      fetchImpl,
      now: () => 999,
    });

    expect(result).toMatchObject({
      providerId: "openai-codex",
      authenticated: true,
      planType: "prolite",
      fiveHour: {
        usedPercent: 19,
        remainingPercent: 81,
        limitWindowSeconds: 18_000,
        resetAt: 1_746_853_708,
      },
      weekly: {
        usedPercent: 67,
        remainingPercent: 33,
        limitWindowSeconds: 604_800,
        resetAt: 1_746_989_363,
      },
      credits: {
        hasCredits: false,
        unlimited: false,
        balance: "0",
      },
      additionalRateLimits: [
        {
          meteredFeature: "codex_bengalfox",
          limitName: "GPT-5.3-Codex-Spark",
          fiveHour: { remainingPercent: 100 },
          weekly: { remainingPercent: 100 },
        },
      ],
      fetchedAt: 999,
    });

    expect(fetchImpl).toHaveBeenCalledWith(
      "https://chatgpt.com/backend-api/wham/usage",
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("returns a structured error on non-200 responses", async () => {
    const result = await fetchCodexUsageStatus({
      authStorage: {
        get: vi.fn(() => ({ type: "oauth", accountId: "acct_123" })),
        getApiKey: vi.fn(async () => "token_123"),
      } as never,
      fetchImpl: vi.fn(async () =>
        new Response(
          JSON.stringify({ error: { message: "rate limited" } }),
          { status: 429 },
        ),
      ) as never,
      now: () => 456,
    });

    expect(result).toEqual({
      providerId: "openai-codex",
      authenticated: true,
      planType: null,
      rateLimitReachedType: null,
      fiveHour: null,
      weekly: null,
      credits: null,
      additionalRateLimits: [],
      fetchedAt: 456,
      error: "Codex usage fetch failed (429): rate limited",
    });
  });
});
