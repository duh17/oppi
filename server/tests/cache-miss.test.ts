import { describe, expect, it } from "vitest";

import {
  computeCacheWaste,
  observeCacheMiss,
  resetCacheMissTracker,
  type CacheMissAssistantMessage,
  type CacheMissTrackerState,
} from "../src/cache-miss.js";

const prices = {
  find: () => ({ cost: { cacheRead: 1 } }),
};

function assistant(options: {
  timestamp: number;
  input?: number;
  cacheRead?: number;
  cacheWrite?: number;
  inputCost?: number;
  cacheReadCost?: number;
  cacheWriteCost?: number;
  model?: string;
}): CacheMissAssistantMessage {
  return {
    role: "assistant",
    provider: "anthropic",
    model: options.model ?? "claude-sonnet",
    timestamp: options.timestamp,
    stopReason: "stop",
    usage: {
      input: options.input ?? 0,
      cacheRead: options.cacheRead ?? 0,
      cacheWrite: options.cacheWrite ?? 0,
      cost: {
        input: options.inputCost ?? 0,
        cacheRead: options.cacheReadCost ?? 0,
        cacheWrite: options.cacheWriteCost ?? 0,
      },
    },
  };
}

describe("Pi-compatible cache miss notices", () => {
  it("reports a significant miss after Pi's five-minute idle TTL", () => {
    const tracker: CacheMissTrackerState = {};
    observeCacheMiss(
      tracker,
      assistant({
        timestamp: 1_000,
        input: 1_000,
        cacheRead: 69_000,
        inputCost: 0.012,
        cacheReadCost: 0.069,
      }),
    );

    const notice = observeCacheMiss(
      tracker,
      assistant({
        timestamp: 310_700,
        input: 70_000,
        inputCost: 0.84,
      }),
      prices,
    );

    expect(notice).toMatchObject({
      missedTokens: 70_000,
      idleMs: 309_700,
      reason: "idle",
    });
    expect(notice?.missedCost).toBeCloseTo(0.77, 6);
  });

  it("keeps insignificant cache churn out of the timeline", () => {
    const tracker: CacheMissTrackerState = {};
    observeCacheMiss(
      tracker,
      assistant({ timestamp: 1_000, input: 1_000, cacheRead: 69_000, cacheReadCost: 0.069 }),
    );

    const notice = observeCacheMiss(
      tracker,
      assistant({ timestamp: 2_000, input: 5_000, inputCost: 0.06 }),
      prices,
    );

    expect(notice).toBeUndefined();
  });

  it("does not compare across a compaction boundary", () => {
    const tracker: CacheMissTrackerState = {};
    observeCacheMiss(
      tracker,
      assistant({ timestamp: 1_000, cacheRead: 70_000, cacheReadCost: 0.07 }),
    );
    resetCacheMissTracker(tracker);

    const notice = observeCacheMiss(
      tracker,
      assistant({ timestamp: 310_700, input: 70_000, inputCost: 0.84 }),
      prices,
    );
    expect(notice).toBeUndefined();
  });

  it("aggregates full-history re-billing while resetting at structural context changes", () => {
    const entries = [
      {
        type: "message",
        message: assistant({
          timestamp: 1_000,
          input: 1_000,
          cacheRead: 69_000,
          inputCost: 0.012,
          cacheReadCost: 0.069,
        }),
      },
      { type: "message", message: assistant({ timestamp: 2_000, input: 70_000, inputCost: 0.84 }) },
      { type: "compaction" },
      { type: "message", message: assistant({ timestamp: 3_000, input: 40_000, inputCost: 0.48 }) },
      {
        type: "message",
        message: assistant({
          timestamp: 4_000,
          input: 1_000,
          cacheRead: 39_000,
          inputCost: 0.012,
          cacheReadCost: 0.039,
        }),
      },
    ];

    expect(computeCacheWaste(entries, prices)).toEqual({
      missedTokens: 70_000,
      missedCost: expect.closeTo(0.77, 6),
      missCount: 1,
    });
  });
});
