import { describe, expect, it, vi } from "vitest";

import {
  fetchCodexProviderQuota,
  fetchOpenCodeGoProviderQuota,
  fetchProviderQuotas,
  fetchXaiProviderQuota,
  deriveProviderQuotaPacing,
  normalizeProviderQuotaWindows,
  type ProviderQuotaAdapter,
  type ProviderQuotaWindow,
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
      const href = String(url);
      if (href.includes("format=credits")) {
        return new Response(
          JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-30T23:07:26.243780+00:00",
                end: "2026-08-06T23:07:26.243780+00:00",
              },
              creditUsagePercent: 30,
              onDemandCap: { val: 0 },
              onDemandUsed: { val: 0 },
              productUsage: [{ product: "GrokBuild", usagePercent: 30 }],
              isUnifiedBillingUser: true,
              prepaidBalance: { val: 0 },
              topUpMethod: "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
              billingPeriodStart: "2026-07-30T23:07:26.243780+00:00",
              billingPeriodEnd: "2026-08-06T23:07:26.243780+00:00",
            },
          }),
          { status: 200 },
        );
      }
      if (href.includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              monthlyLimit: { val: 15000 },
              used: { val: 7277 },
              onDemandCap: { val: 0 },
              billingPeriodStart: "2026-07-01T00:00:00+00:00",
              billingPeriodEnd: "2026-08-01T00:00:00+00:00",
            },
          }),
          { status: 200 },
        );
      }
      if (href.includes("/settings")) {
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
      prepaidBalanceCents: 0,
      fetchedAt: 222,
    });
    expect(result.error).toBeUndefined();
    expect(result.windows).toHaveLength(1);
    expect(result.windows[0]).toMatchObject({
      key: "weekly",
      shortLabel: "7d",
      title: "Weekly",
      usedPercent: 30,
      remainingPercent: 70,
      includeWeekdayInReset: true,
    });
    expect(result.windows[0]?.resetAt).toBe(
      Math.floor(Date.parse("2026-08-06T23:07:26.243780+00:00") / 1000),
    );
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
      expect.objectContaining({ method: "GET" }),
    );
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://cli-chat-proxy.grok.com/v1/billing",
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("falls back to plain monthly billing when credits omits creditUsagePercent", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      const href = String(url);
      if (href.includes("format=credits")) {
        return new Response(
          JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-30T23:07:26.243780+00:00",
                end: "2026-08-06T23:07:26.243780+00:00",
              },
              onDemandCap: { val: 0 },
              onDemandUsed: { val: 0 },
              isUnifiedBillingUser: true,
              prepaidBalance: { val: 0 },
              topUpMethod: "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
              billingPeriodStart: "2026-07-30T23:07:26.243780+00:00",
              billingPeriodEnd: "2026-08-06T23:07:26.243780+00:00",
            },
          }),
          { status: 200 },
        );
      }
      if (href.includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              monthlyLimit: { val: 15000 },
              used: { val: 5846 },
              onDemandCap: { val: 0 },
              billingPeriodStart: "2026-07-01T00:00:00+00:00",
              billingPeriodEnd: "2026-08-01T00:00:00+00:00",
            },
          }),
          { status: 200 },
        );
      }
      if (href.includes("/settings")) {
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
      now: () => 555,
    });

    expect(result).toMatchObject({
      providerId: "xai",
      displayName: "xAI",
      authenticated: true,
      planType: "SuperGrok",
      prepaidBalanceCents: 0,
      fetchedAt: 555,
    });
    expect(result.error).toBeUndefined();
    expect(result.windows).toHaveLength(1);
    expect(result.windows[0]).toMatchObject({
      key: "monthly",
      shortLabel: "30d",
      title: "Monthly",
      usedPercent: expect.closeTo((5846 / 15000) * 100, 5),
      remainingPercent: expect.closeTo(100 - (5846 / 15000) * 100, 5),
      includeWeekdayInReset: false,
    });
    expect(result.windows[0]?.resetAt).toBe(
      Math.floor(Date.parse("2026-08-01T00:00:00+00:00") / 1000),
    );
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
      expect.objectContaining({ method: "GET" }),
    );
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://cli-chat-proxy.grok.com/v1/billing",
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("keeps billing quota when optional settings fetch fails", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              monthlyLimit: { val: 10000 },
              used: { val: 1000 },
              billingPeriodStart: "2026-07-01T00:00:00Z",
              billingPeriodEnd: "2026-08-01T00:00:00Z",
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
      shortLabel: "30d",
    });
  });
});

describe("fetchOpenCodeGoProviderQuota", () => {
  it("returns unauthenticated when no opencode-go credential is stored", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => undefined),
      fetchImpl: vi.fn() as never,
      now: () => 20,
    });

    expect(result).toEqual({
      providerId: "opencode-go",
      displayName: "OpenCode Go",
      authenticated: false,
      planType: null,
      windows: [],
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt: 20,
    });
  });

  it("maps rolling, weekly, and monthly windows from the usage payload", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            usage: {
              rolling: { status: "ok", percent: 2, resetsAt: "2026-08-15T12:48:46.948Z" },
              weekly: { status: "ok", percent: 1, resetsAt: "2026-08-17T00:00:00.948Z" },
              monthly: { status: "ok", percent: 0, resetsAt: "2026-09-15T07:35:54.948Z" },
            },
          }),
          { status: 200 },
        ),
    ) as never;

    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl,
      now: () => 321,
    });

    expect(result).toMatchObject({
      providerId: "opencode-go",
      displayName: "OpenCode Go",
      authenticated: true,
      planType: "Go",
      windows: [
        {
          key: "five_hour",
          shortLabel: "5h",
          title: "5-hour",
          usedPercent: 2,
          remainingPercent: 98,
          limitWindowSeconds: 18_000,
          resetAt: Math.floor(Date.parse("2026-08-15T12:48:46.948Z") / 1000),
          includeWeekdayInReset: false,
        },
        {
          key: "weekly",
          shortLabel: "7d",
          title: "Weekly",
          usedPercent: 1,
          remainingPercent: 99,
          limitWindowSeconds: 604_800,
          resetAt: Math.floor(Date.parse("2026-08-17T00:00:00.948Z") / 1000),
          includeWeekdayInReset: true,
        },
        {
          key: "monthly",
          shortLabel: "30d",
          title: "Monthly",
          usedPercent: 0,
          remainingPercent: 100,
          limitWindowSeconds: 31 * 24 * 60 * 60,
          resetAt: Math.floor(Date.parse("2026-09-15T07:35:54.948Z") / 1000),
          includeWeekdayInReset: false,
        },
      ],
      fetchedAt: 321,
    });
    expect(result.error).toBeUndefined();
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://opencode.ai/zen/go/v1/usage",
      expect.objectContaining({ method: "GET", headers: expect.any(Headers) }),
    );
    const [, init] = (fetchImpl as ReturnType<typeof vi.fn>).mock.calls[0] as [
      string,
      { headers: Headers },
    ];
    expect(init.headers.get("Authorization")).toBe("Bearer sk-go-test");
  });

  it("infers monthly length from resetAt so snapshot pacing can be calculated", async () => {
    const fetchedAt = Date.parse("2026-08-25T07:01:00.000Z");
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            usage: {
              monthly: {
                status: "ok",
                percent: 97,
                resetsAt: "2026-09-15T07:35:54.948Z",
              },
            },
          }),
          { status: 200 },
        ),
    ) as never;

    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl,
      now: () => fetchedAt,
    });

    const monthly = result.windows.find((window) => window.key === "monthly");
    expect(monthly?.limitWindowSeconds).toBe(31 * 24 * 60 * 60);
    expect(monthly?.remainingPercent).toBe(3);
    expect(monthly?.pacing?.source).toBe("snapshot");
    expect(monthly?.pacing?.status).toBe("conserve");
    expect(monthly?.pacing?.supplyRatio).toBeCloseTo(0.044, 2);
  });

  it.each([
    {
      name: "Mar 31",
      resetsAt: "2026-03-31T12:00:00.000Z",
      limitWindowSeconds: 31 * 24 * 60 * 60,
    },
    {
      name: "May 31",
      resetsAt: "2026-05-31T12:00:00.000Z",
      limitWindowSeconds: 31 * 24 * 60 * 60,
    },
    {
      name: "Dec 31",
      resetsAt: "2026-12-31T12:00:00.000Z",
      limitWindowSeconds: 31 * 24 * 60 * 60,
    },
    {
      name: "non-leap Mar 29",
      resetsAt: "2026-03-29T12:00:00.000Z",
      limitWindowSeconds: 29 * 24 * 60 * 60,
    },
    {
      name: "leap Mar 31",
      resetsAt: "2028-03-31T12:00:00.000Z",
      limitWindowSeconds: 31 * 24 * 60 * 60,
    },
  ])(
    "clamps OpenCode Go monthly length at $name instead of overflowing",
    async ({ resetsAt, limitWindowSeconds }) => {
      const fetchedAt = Date.parse(resetsAt) - 24 * 60 * 60 * 1000;
      const fetchImpl = vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              usage: {
                monthly: { status: "ok", percent: 40, resetsAt },
              },
            }),
            { status: 200 },
          ),
      ) as never;

      const result = await fetchOpenCodeGoProviderQuota({
        modelRuntime: { getAuth: vi.fn() },
        readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
        fetchImpl,
        now: () => fetchedAt,
      });

      const monthly = result.windows.find((window) => window.key === "monthly");
      expect(monthly?.limitWindowSeconds).toBe(limitWindowSeconds);
      expect(monthly?.pacing?.source).toBe("snapshot");
      expect(monthly?.pacing?.status).not.toBe("unknown");
    },
  );

  it("clamps percent above 100 and tolerates unparseable resetsAt", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            usage: {
              rolling: { status: "rate-limited", percent: 250, resetsAt: "not-a-date" },
              weekly: { status: "ok" },
            },
          }),
          { status: 200 },
        ),
    ) as never;

    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl,
      now: () => 322,
    });

    expect(result.error).toBeUndefined();
    expect(result.windows).toHaveLength(1);
    expect(result.windows[0]).toMatchObject({
      key: "five_hour",
      usedPercent: 100,
      remainingPercent: 0,
      resetAt: null,
    });
  });

  it("rejects non-api_key credentials with a structured error", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(
        () => ({ type: "oauth", access: "a", refresh: "r", expires: 1 }) as const,
      ),
      fetchImpl: vi.fn() as never,
      now: () => 323,
    });

    expect(result.authenticated).toBe(true);
    expect(result.windows).toEqual([]);
    expect(result.error).toContain("unexpected credential type");
  });

  it("reports a missing API key on an api_key credential", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key" }) as const),
      fetchImpl: vi.fn() as never,
      now: () => 324,
    });

    expect(result.authenticated).toBe(true);
    expect(result.error).toContain("no API key is available");
  });

  it("returns an invalid-payload error when usage is missing", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl: vi.fn(async () => new Response(JSON.stringify({}), { status: 200 })) as never,
      now: () => 325,
    });

    expect(result.authenticated).toBe(true);
    expect(result.error).toBe("OpenCode Go quota fetch failed: invalid response payload.");
  });

  it("surfaces network failures as structured errors", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl: vi.fn(async () => {
        throw new Error("socket hang up");
      }) as never,
      now: () => 326,
    });

    expect(result.authenticated).toBe(true);
    expect(result.error).toBe("OpenCode Go quota fetch failed: socket hang up");
  });

  it("returns a structured error on upstream 401 (invalid key)", async () => {
    const result = await fetchOpenCodeGoProviderQuota({
      modelRuntime: { getAuth: vi.fn() },
      readCredential: vi.fn(() => ({ type: "api_key", key: "sk-go-test" }) as const),
      fetchImpl: vi.fn(
        async () =>
          new Response(JSON.stringify({ error: "no active subscription" }), { status: 401 }),
      ) as never,
      now: () => 456,
    });

    expect(result).toEqual({
      providerId: "opencode-go",
      displayName: "OpenCode Go",
      authenticated: true,
      planType: null,
      windows: [],
      credits: null,
      prepaidBalanceCents: null,
      fetchedAt: 456,
      error: "OpenCode Go quota fetch failed (401): no active subscription",
    });
  });
});

describe("deriveProviderQuotaPacing", () => {
  const baseWindow: ProviderQuotaWindow = {
    key: "hourly",
    shortLabel: "1h",
    title: "Hourly",
    usedPercent: 35,
    remainingPercent: 65,
    limitWindowSeconds: 3600,
    resetAt: 3_601,
    includeWeekdayInReset: false,
  };

  it.each([
    [1.301, "plenty"],
    [1.201, "plenty"],
    [1.2, "on_pace"],
    [0.801, "on_pace"],
    [0.8, "on_pace"],
    [0.799, "conserve"],
  ] as const)("classifies a supply ratio at the %s boundary", (ratio, status) => {
    const resetAt = 1_000 + (0.65 / ratio) * 3_600;
    const pacing = deriveProviderQuotaPacing({ ...baseWindow, resetAt }, 1_000_000);

    expect(pacing.status).toBe(status);
    expect(pacing.source).toBe("snapshot");
    expect(pacing.supplyRatio).toBeCloseTo(ratio);
  });

  it("derives exact snapshot values and leaves observation fields null", () => {
    const pacing = deriveProviderQuotaPacing(
      { ...baseWindow, remainingPercent: 54, resetAt: 203_309 },
      1_000_000,
    );

    expect(pacing).toEqual({
      source: "snapshot",
      status: "conserve",
      timeRemainingSeconds: 202_309,
      supplyRatio: 0.54 / (202_309 / 3_600),
      targetBurnPercentPerHour: 54 / (202_309 / 3_600),
      recentBurnPercentPerHour: null,
      paceRatio: null,
      projectedExhaustionAt: null,
      projectedRemainingPercent: null,
    });
  });

  it.each([
    { resetAt: null, limitWindowSeconds: 3600, remainingPercent: 50 },
    { resetAt: 999, limitWindowSeconds: 3600, remainingPercent: 50 },
    { resetAt: 3_601, limitWindowSeconds: 0, remainingPercent: 50 },
    { resetAt: 3_601, limitWindowSeconds: Number.NaN, remainingPercent: 50 },
    { resetAt: 3_601, limitWindowSeconds: 3600, remainingPercent: Number.NaN },
  ])("returns unknown for missing, elapsed, invalid, or non-finite inputs", (input) => {
    const pacing = deriveProviderQuotaPacing({ ...baseWindow, ...input }, 1_000_000);

    expect(pacing).toEqual({
      source: "unknown",
      status: "unknown",
      timeRemainingSeconds:
        input.resetAt !== null && input.resetAt > 1_000 ? input.resetAt - 1_000 : null,
      supplyRatio: null,
      targetBurnPercentPerHour: null,
      recentBurnPercentPerHour: null,
      paceRatio: null,
      projectedExhaustionAt: null,
      projectedRemainingPercent: null,
    });
  });

  it("clamps remaining percent before deriving without producing non-finite values", () => {
    const pacing = deriveProviderQuotaPacing(
      { ...baseWindow, remainingPercent: 250, resetAt: 2_800 },
      1_000_000,
    );

    expect(pacing.status).toBe("plenty");
    expect(pacing.supplyRatio).toBe(2);
    expect(Number.isFinite(pacing.targetBurnPercentPerHour)).toBe(true);
  });
});

describe("normalizeProviderQuotaWindows", () => {
  it("dedupes by key and sorts shortest period first", () => {
    const windows: ProviderQuotaWindow[] = [
      {
        key: "monthly",
        shortLabel: "30d",
        title: "Monthly",
        usedPercent: 50,
        remainingPercent: 50,
        limitWindowSeconds: 30 * 24 * 60 * 60,
        resetAt: 3,
        includeWeekdayInReset: false,
      },
      {
        key: "weekly",
        shortLabel: "7d",
        title: "Weekly",
        usedPercent: 40,
        remainingPercent: 60,
        limitWindowSeconds: 7 * 24 * 60 * 60,
        resetAt: 2,
        includeWeekdayInReset: true,
      },
      {
        key: "weekly",
        shortLabel: "dup",
        title: "Dup",
        usedPercent: 99,
        remainingPercent: 1,
        limitWindowSeconds: 7 * 24 * 60 * 60,
        resetAt: 9,
        includeWeekdayInReset: true,
      },
      {
        key: "unknown",
        shortLabel: "?",
        title: "Unknown",
        usedPercent: 10,
        remainingPercent: 90,
        limitWindowSeconds: null,
        resetAt: null,
        includeWeekdayInReset: false,
      },
      {
        key: "five_hour",
        shortLabel: "5h",
        title: "5-hour",
        usedPercent: 20,
        remainingPercent: 80,
        limitWindowSeconds: 18_000,
        resetAt: 1,
        includeWeekdayInReset: false,
      },
    ];

    expect(normalizeProviderQuotaWindows(windows).map((window) => window.key)).toEqual([
      "five_hour",
      "weekly",
      "monthly",
      "unknown",
    ]);
    expect(normalizeProviderQuotaWindows(windows)[1]?.shortLabel).toBe("7d");
  });
});

describe("fetchProviderQuotas", () => {
  it("runs injected adapters without hard-coding provider ids", async () => {
    const adapters: ProviderQuotaAdapter[] = [
      {
        providerId: "example",
        displayName: "Example",
        fetch: async () => ({
          providerId: "example",
          displayName: "Example",
          authenticated: true,
          planType: null,
          windows: [
            {
              key: "monthly",
              shortLabel: "30d",
              title: "Monthly",
              usedPercent: 10,
              remainingPercent: 90,
              limitWindowSeconds: 30 * 24 * 60 * 60,
              resetAt: null,
              includeWeekdayInReset: false,
            },
            {
              key: "hourly",
              shortLabel: "1h",
              title: "Hourly",
              usedPercent: 25,
              remainingPercent: 75,
              limitWindowSeconds: 3600,
              resetAt: 3_601,
              includeWeekdayInReset: false,
            },
          ],
          credits: null,
          prepaidBalanceCents: null,
          fetchedAt: 1,
        }),
      },
    ];

    const result = await fetchProviderQuotas({
      modelRuntime: { getAuth: vi.fn() },
      adapters,
      now: () => 9,
    });

    expect(result.providers).toHaveLength(1);
    expect(result.providers[0]?.providerId).toBe("example");
    expect(result.providers[0]?.windows.map((window) => window.key)).toEqual(["hourly", "monthly"]);
    expect(result.providers[0]?.windows[0]?.pacing?.status).toBe("conserve");
    expect(result.providers[0]?.windows[0]?.pacing?.supplyRatio).toBeCloseTo(0.75, 3);
  });

  it("isolates a throwing adapter and stamps registry identity", async () => {
    const adapters: ProviderQuotaAdapter[] = [
      {
        providerId: "healthy",
        displayName: "Healthy",
        fetch: async () => ({
          // Deliberately wrong identity — aggregator must stamp registry metadata.
          providerId: "wrong",
          displayName: "Wrong",
          authenticated: true,
          planType: null,
          windows: [
            {
              key: "daily",
              shortLabel: "1d",
              title: "Daily",
              usedPercent: 10,
              remainingPercent: 90,
              limitWindowSeconds: 86_400,
              resetAt: null,
              includeWeekdayInReset: false,
            },
          ],
          credits: null,
          prepaidBalanceCents: null,
          fetchedAt: 1,
        }),
      },
      {
        providerId: "broken",
        displayName: "Broken",
        fetch: async () => {
          throw new Error("upstream exploded");
        },
      },
    ];

    const result = await fetchProviderQuotas({
      modelRuntime: { getAuth: vi.fn() },
      adapters,
      now: () => 42,
    });

    expect(result.providers).toHaveLength(2);
    expect(result.providers.map((provider) => provider.providerId)).toEqual(["healthy", "broken"]);
    expect(result.providers[0]).toMatchObject({
      providerId: "healthy",
      displayName: "Healthy",
      authenticated: true,
      windows: [{ key: "daily" }],
    });
    expect(result.providers[1]).toMatchObject({
      providerId: "broken",
      displayName: "Broken",
      authenticated: true,
      windows: [],
      error: "Broken quota fetch failed: upstream exploded",
    });
  });

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
      if (providerId === "opencode-go") {
        return { type: "api_key", key: "sk-go" } as const;
      }
      return undefined;
    });

    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url).includes("opencode.ai")) {
        return new Response(
          JSON.stringify({
            usage: {
              rolling: { status: "ok", percent: 5, resetsAt: "2026-08-15T12:00:00Z" },
              weekly: { status: "ok", percent: 3, resetsAt: "2026-08-17T00:00:00Z" },
              monthly: { status: "ok", percent: 1, resetsAt: "2026-09-15T00:00:00Z" },
            },
          }),
          { status: 200 },
        );
      }
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
      if (String(url).includes("format=credits")) {
        return new Response(
          JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-23T00:00:00Z",
                end: "2026-07-30T00:00:00Z",
              },
              creditUsagePercent: 40,
              prepaidBalance: { val: 0 },
            },
          }),
          { status: 200 },
        );
      }
      if (String(url).includes("/billing")) {
        return new Response(
          JSON.stringify({
            config: {
              monthlyLimit: { val: 10000 },
              used: { val: 4000 },
              billingPeriodStart: "2026-07-01T00:00:00Z",
              billingPeriodEnd: "2026-08-01T00:00:00Z",
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
    expect(result.providers.map((p) => p.providerId)).toEqual([
      "openai-codex",
      "opencode-go",
      "xai",
    ]);
    expect(result.providers[0]?.windows).toHaveLength(2);
    expect(result.providers[1]).toMatchObject({
      providerId: "opencode-go",
      planType: "Go",
      authenticated: true,
    });
    expect(result.providers[1]?.windows.map((w) => w.key)).toEqual([
      "five_hour",
      "weekly",
      "monthly",
    ]);
    expect(result.providers[2]?.planType).toBe("SuperGrok");
    expect(result.providers[2]?.windows[0]?.remainingPercent).toBe(60);
  });
});
