import { describe, expect, it } from "vitest";

import {
  computeCacheWaste,
  observeCacheMiss,
  replayCacheMissHistory,
  resetCacheMissTracker,
  type CacheMissAssistantMessage,
  type CacheMissTrackerState,
} from "../src/cache-miss.js";
import { importPiDist } from "../src/pi-private.js";

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

describe("agreement with Pi's cache stats", () => {
  it("counts the same re-billing as Pi over a session's history", async () => {
    const { computeCacheWaste: piCacheWaste } = await importPiDist("core/cache-stats.js", [
      "computeCacheWaste",
    ]);
    const models = {
      ...prices,
      getModel: () => ({ cost: { cacheRead: 1 } }),
    };
    const message = (options: Parameters<typeof assistant>[0]) => ({
      type: "message",
      message: assistant(options),
    });
    const entries = [
      message({ timestamp: 1_000, input: 1_000, cacheRead: 69_000, cacheReadCost: 0.069 }),
      // Idle past the cache TTL: re-billed.
      message({ timestamp: 400_000, input: 70_000, inputCost: 0.84 }),
      // A model switch re-bills too.
      message({ timestamp: 401_000, input: 72_000, inputCost: 0.9, model: "claude-opus" }),
      // A warming request refreshes the cache: the next answer is compared with it, not with
      // the larger answer before it.
      {
        type: "usage",
        kind: "cache_warm",
        provider: "anthropic",
        model: "claude-opus",
        timestamp: new Date(600_000).toISOString(),
        usage: assistant({ timestamp: 0, cacheRead: 50_000, cacheReadCost: 0.05 }).usage,
      },
      message({
        timestamp: 700_000,
        input: 23_000,
        cacheRead: 50_000,
        inputCost: 0.276,
        cacheReadCost: 0.05,
        model: "claude-opus",
      }),
      { type: "branch_summary" },
      message({ timestamp: 800_000, input: 50_000, inputCost: 0.6 }),
      { type: "compaction" },
      message({ timestamp: 900_000, input: 30_000, inputCost: 0.36 }),
      // Below the noise floor.
      message({ timestamp: 901_000, input: 1_000, cacheRead: 29_500, cacheReadCost: 0.0295 }),
    ];

    const ours = computeCacheWaste(entries, prices);
    const pi = (piCacheWaste as typeof computeCacheWaste)(entries, models);

    expect(ours.missCount).toBe(2);
    expect(ours).toEqual({
      missedTokens: pi.missedTokens,
      missedCost: expect.closeTo(pi.missedCost, 9),
      missCount: pi.missCount,
    });
  });
});

describe("replaying saved history", () => {
  const warm = {
    type: "message",
    message: assistant({ timestamp: 1_000, cacheRead: 100_000, cacheReadCost: 0.1 }),
  };
  const rebilled = (timestamp: number, stopReason = "stop") => ({
    type: "message",
    message: { ...assistant({ timestamp, input: 100_000, inputCost: 1 }), stopReason },
  });

  it("places each notice at the answer that paid and seeds the next live comparison", () => {
    const tracker: CacheMissTrackerState = {};
    const notices = replayCacheMissHistory(tracker, [warm, rebilled(2_000)], prices);

    expect(notices).toEqual([
      { index: 1, notice: expect.objectContaining({ id: expect.stringContaining(":2000:") }) },
    ]);
    // The next live answer is compared with the last saved one, not treated as the first.
    expect(
      observeCacheMiss(
        tracker,
        assistant({ timestamp: 3_000, input: 100_000, inputCost: 1 }),
        prices,
      ),
    ).toMatchObject({ missedTokens: 100_000 });
  });

  it("compares the first live answer after a restart with the last saved answer", () => {
    const tracker: CacheMissTrackerState = {};
    replayCacheMissHistory(tracker, [warm], prices);

    expect(
      observeCacheMiss(
        tracker,
        assistant({ timestamp: 8 * 60_000, input: 100_000, inputCost: 1 }),
        prices,
      ),
    ).toMatchObject({ reason: "idle", missedTokens: 100_000 });
  });

  it("does not compare a live answer with its own saved entry", () => {
    const tracker: CacheMissTrackerState = {};
    replayCacheMissHistory(tracker, [warm, rebilled(2_000)], prices);

    expect(
      observeCacheMiss(
        tracker,
        assistant({ timestamp: 2_000, input: 100_000, inputCost: 1 }),
        prices,
      ),
    ).toBeUndefined();
  });

  it("shows no notice across a compaction", () => {
    const tracker: CacheMissTrackerState = {};
    const notices = replayCacheMissHistory(
      tracker,
      [warm, { type: "compaction" }, rebilled(2_000)],
      prices,
    );

    expect(notices).toEqual([]);
  });

  it("shows no notice on an aborted answer, but still tracks it", () => {
    const tracker: CacheMissTrackerState = {};
    const notices = replayCacheMissHistory(tracker, [warm, rebilled(2_000, "aborted")], prices);

    expect(notices).toEqual([]);
    // The aborted request still refreshed the cache: idle time counts from it.
    expect(
      observeCacheMiss(
        tracker,
        assistant({ timestamp: 9 * 60_000, input: 100_000, inputCost: 1 }),
        prices,
      ),
    ).toMatchObject({ idleMs: 9 * 60_000 - 2_000 });
  });
});
