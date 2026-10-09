import { describe, expect, it } from "vitest";

import { ScheduleDispatchError, recordScheduleRun } from "../src/schedule-run-metrics.js";
import type { ServerMetricCollector } from "../src/server-metric-collector.js";

function collector() {
  const samples: Array<{ metric: string; value: number; tags?: Record<string, string> }> = [];
  return {
    samples,
    metrics: {
      record(metric: string, value: number, tags?: Record<string, string>) {
        samples.push({ metric, value, tags });
      },
    } as unknown as ServerMetricCollector,
  };
}

describe("schedule run metrics", () => {
  it("records a bounded failure reason and drops the raw error text", () => {
    const { samples, metrics } = collector();
    recordScheduleRun(metrics, {
      startedAt: 1_000,
      now: 1_250,
      kind: "due",
      status: "failed",
      error: new Error(
        'Required model "ds4/deepseek-v4-flash" is not available at /Users/chenda/secret',
      ),
    });
    expect(samples).toEqual([
      {
        metric: "server.schedule_run_ms",
        value: 250,
        tags: { status: "failed", kind: "due", reason: "other" },
      },
    ]);
    expect(JSON.stringify(samples)).not.toContain("deepseek");
    expect(JSON.stringify(samples)).not.toContain("/Users/chenda/secret");
  });

  it("maps a promptError that mentions release or not found to other", () => {
    const { samples, metrics } = collector();
    recordScheduleRun(metrics, {
      startedAt: 1,
      now: 2,
      kind: "due",
      status: "failed",
      error: new ScheduleDispatchError(
        "other",
        "please release the workspace; model not found at /Users/chenda/secret",
      ),
    });
    expect(samples[0]?.tags).toEqual({ status: "failed", kind: "due", reason: "other" });
    recordScheduleRun(metrics, {
      startedAt: 1,
      now: 2,
      kind: "due",
      status: "failed",
      error: new Error("please release the file; model not found"),
    });
    expect(samples[1]?.tags?.reason).toBe("other");
    expect(JSON.stringify(samples)).not.toContain("release");
    expect(JSON.stringify(samples)).not.toContain("not found");
    expect(JSON.stringify(samples)).not.toContain("/Users/chenda/secret");
  });

  it("classifies lease loss without keeping the run id", () => {
    const { samples, metrics } = collector();
    recordScheduleRun(metrics, {
      startedAt: 10,
      now: 10,
      kind: "manual",
      status: "failed",
      error: new Error("Schedule run lease was lost: run-9f3a"),
    });
    expect(samples[0]?.tags).toEqual({
      status: "failed",
      kind: "manual",
      reason: "lease_lost",
    });
    expect(JSON.stringify(samples)).not.toContain("run-9f3a");
  });
});
