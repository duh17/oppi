import { describe, expect, it } from "vitest";

import {
  estimateUsageCostFromModel,
  normalizePiUsage,
  resolveCacheWriteForModelBreakdown,
} from "../src/token-usage.js";

const codexSparkExpectedCost = 0.0049;

describe("normalizePiUsage", () => {
  it("returns canonical usage when explicit fields are present", () => {
    const usage = normalizePiUsage({
      input: 120,
      output: 45,
      cacheRead: 800,
      cacheWrite: 30,
      cost: { total: 0.25 },
    });

    expect(usage).toEqual({
      input: 120,
      output: 45,
      cacheRead: 800,
      cacheWrite: 30,
      contextTokens: 995,
      cost: 0.25,
    });
  });

  it("prefers a reported totalTokens for context size (Cursor reports input deltas)", () => {
    const usage = normalizePiUsage({
      input: 538,
      output: 284,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 18_098,
      cost: { total: 0 },
    });

    // Per-request deltas stay untouched so running totals are not inflated.
    expect(usage).toEqual({
      input: 538,
      output: 284,
      cacheRead: 0,
      cacheWrite: 0,
      contextTokens: 18_098,
      cost: 0,
    });
  });

  it("accepts a raw total_tokens counter", () => {
    expect(normalizePiUsage({ input: 40, output: 10, total_tokens: 9_000 })?.contextTokens).toBe(
      9_000,
    );
  });

  it("falls back to the field sum when totalTokens is absent or zero", () => {
    expect(normalizePiUsage({ input: 40, output: 10 })?.contextTokens).toBe(50);
    expect(normalizePiUsage({ input: 40, output: 10, totalTokens: 0 })?.contextTokens).toBe(50);
    expect(normalizePiUsage({ input: 40, output: 10, totalTokens: -5 })?.contextTokens).toBe(50);
    expect(
      normalizePiUsage({ input: 40, output: 10, totalTokens: Number.NaN })?.contextTokens,
    ).toBe(50);
  });

  it("normalizes OpenAI Chat Completions usage fields", () => {
    const usage = normalizePiUsage({
      prompt_tokens: 1500,
      completion_tokens: 80,
      prompt_tokens_details: {
        cached_tokens: 1200,
        cache_write_tokens: 100,
      },
      cost: { total: 0.41 },
    });

    expect(usage).toEqual({
      input: 200, // 1500 - 1200 - 100
      output: 80,
      cacheRead: 1200,
      cacheWrite: 100,
      contextTokens: 1580,
      cost: 0.41,
    });
  });

  it("normalizes OpenAI Responses usage fields", () => {
    const usage = normalizePiUsage({
      input_tokens: 1400,
      output_tokens: 70,
      input_tokens_details: {
        cached_tokens: 1100,
        cache_write_tokens: 120,
      },
      cost: { total: 0.33 },
    });

    expect(usage).toEqual({
      input: 180, // 1400 - 1100 - 120
      output: 70,
      cacheRead: 1100,
      cacheWrite: 120,
      contextTokens: 1470,
      cost: 0.33,
    });
  });

  it("normalizes Anthropic cache_read/cache_creation usage fields", () => {
    const usage = normalizePiUsage({
      input: 90,
      output: 20,
      cache_read_input_tokens: 700,
      cache_creation_input_tokens: 55,
      cost: { total: 0.11 },
    });

    expect(usage).toEqual({
      input: 90,
      output: 20,
      cacheRead: 700,
      cacheWrite: 55,
      contextTokens: 865,
      cost: 0.11,
    });
  });

  it("falls back to model pricing when provider reports zero cost", () => {
    const usage = normalizePiUsage(
      {
        input: 1000,
        output: 100,
        cacheRead: 10000,
        cacheWrite: 0,
        cost: { total: 0 },
      },
      "openai-codex/gpt-5.3-codex-spark",
    );

    expect(usage).toEqual({
      input: 1000,
      output: 100,
      cacheRead: 10000,
      cacheWrite: 0,
      contextTokens: 11100,
      cost: codexSparkExpectedCost,
    });
  });

  it("returns null for non-object usage", () => {
    expect(normalizePiUsage(undefined)).toBeNull();
    expect(normalizePiUsage(null)).toBeNull();
    expect(normalizePiUsage("oops")).toBeNull();
  });
});

describe("estimateUsageCostFromModel", () => {
  it("falls back from openai-codex to priced catalog entries for codex spark", () => {
    const cost = estimateUsageCostFromModel("openai-codex/gpt-5.3-codex-spark", {
      input: 1000,
      output: 100,
      cacheRead: 10000,
      cacheWrite: 0,
    });

    expect(cost).toBe(codexSparkExpectedCost);
  });

  it("returns zero for dynamic providers without static pricing", () => {
    const cost = estimateUsageCostFromModel("radius/custom-model", {
      input: 1000,
      output: 100,
    });

    expect(cost).toBe(0);
  });
});

describe("resolveCacheWriteForModelBreakdown", () => {
  it("uses reported cacheWrite when available", () => {
    const resolved = resolveCacheWriteForModelBreakdown("openai-codex/gpt-5.4", {
      input: 1000,
      output: 200,
      cacheRead: 5000,
      cacheWrite: 77,
    });

    expect(resolved).toEqual({ value: 77, source: "reported" });
  });

  it("estimates cacheWrite for OpenAI GPT models from uncached input", () => {
    const resolved = resolveCacheWriteForModelBreakdown("openai-codex/gpt-5.4", {
      input: 1200,
      output: 300,
      cacheRead: 5000,
      cacheWrite: 0,
    });

    expect(resolved.value).toBe(1200);
    expect(resolved.source).toBe("estimated");
    expect(resolved.ruleId).toBe("openai-gpt-uncached-input");
  });

  it("supports OpenRouter OpenAI model IDs", () => {
    const resolved = resolveCacheWriteForModelBreakdown("openrouter/openai/gpt-5.4", {
      input: 900,
      output: 200,
      cacheRead: 4000,
      cacheWrite: 0,
    });

    expect(resolved.value).toBe(900);
    expect(resolved.source).toBe("estimated");
  });

  it("marks xAI Grok cacheWrite as unsupported (provider has no write counter)", () => {
    const resolved = resolveCacheWriteForModelBreakdown("xai/grok-4.5", {
      input: 2100,
      output: 400,
      cacheRead: 35000,
      cacheWrite: 0,
    });

    expect(resolved).toEqual({
      value: null,
      source: "unsupported",
      ruleId: "xai-grok-no-cache-write",
    });
  });

  it("marks OpenRouter Grok cacheWrite as unsupported", () => {
    const resolved = resolveCacheWriteForModelBreakdown("openrouter/x-ai/grok-4.5", {
      input: 900,
      output: 200,
      cacheRead: 1400,
      cacheWrite: 0,
    });

    expect(resolved).toEqual({
      value: null,
      source: "unsupported",
      ruleId: "xai-grok-no-cache-write",
    });
  });

  it("still uses a reported cacheWrite for Grok if one is present", () => {
    const resolved = resolveCacheWriteForModelBreakdown("xai/grok-4.5", {
      input: 100,
      output: 50,
      cacheRead: 500,
      cacheWrite: 12,
    });

    expect(resolved).toEqual({ value: 12, source: "reported" });
  });

  it("does not estimate cacheWrite for Anthropic models that report writes", () => {
    const resolved = resolveCacheWriteForModelBreakdown("anthropic/claude-opus-4-6", {
      input: 1200,
      output: 300,
      cacheRead: 5000,
      cacheWrite: 0,
    });

    expect(resolved).toEqual({ value: 0, source: "none" });
  });

  it("does not estimate when there is no cache read signal", () => {
    const resolved = resolveCacheWriteForModelBreakdown("openai-codex/gpt-5.4", {
      input: 1200,
      output: 300,
      cacheRead: 0,
      cacheWrite: 0,
    });

    expect(resolved).toEqual({ value: 0, source: "none", ruleId: "openai-gpt-uncached-input" });
  });
});
