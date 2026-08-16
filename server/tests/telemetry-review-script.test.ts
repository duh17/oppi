import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  SLO_THRESHOLDS,
  buildTelemetryTrendSvg,
  buildTrendBuckets,
  formatModelsReview,
  loadSamples,
  parseArgs,
  review,
  reviewModels,
} from "../scripts/telemetry-review.ts";

const HOUR_MS = 60 * 60 * 1_000;

function makeReviewData(endTs: number) {
  const startTs = endTs - 24 * HOUR_MS;
  const samples = [
    { ts: startTs + 1 * HOUR_MS, metric: "chat.timeline_apply_ms", value: 10, unit: "ms" },
    { ts: startTs + 7 * HOUR_MS, metric: "chat.timeline_apply_ms", value: 20, unit: "ms" },
    { ts: startTs + 13 * HOUR_MS, metric: "chat.timeline_apply_ms", value: 30, unit: "ms" },
    { ts: startTs + 13.5 * HOUR_MS, metric: "chat.timeline_apply_ms", value: 50, unit: "ms" },
    { ts: startTs + 21 * HOUR_MS, metric: "chat.timeline_apply_ms", value: 40, unit: "ms" },
    { ts: startTs + 2 * HOUR_MS, metric: "chat.ttft_ms", value: 800, unit: "ms" },
    { ts: startTs + 8 * HOUR_MS, metric: "chat.ttft_ms", value: 900, unit: "ms" },
    { ts: startTs + 14 * HOUR_MS, metric: "chat.ttft_ms", value: 1000, unit: "ms" },
    { ts: startTs + 20 * HOUR_MS, metric: "chat.ttft_ms", value: 1200, unit: "ms" },
  ];

  return {
    values: {
      "chat.timeline_apply_ms": { vals: [10, 20, 30, 50, 40], unit: "ms" },
      "chat.ttft_ms": { vals: [800, 900, 1000, 1200], unit: "ms" },
    },
    byBuild: {},
    buildSummary: {},
    samples,
    totalSamples: samples.length,
    filesRead: 1,
  } satisfies Parameters<typeof review>[0];
}

describe("telemetry-review svg reporting", () => {
  it("gates on current emitted release metrics", () => {
    expect(SLO_THRESHOLDS).toHaveProperty("chat.trace_fetch_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("chat.reducer_load_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("chat.ws_wait_for_connected_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("server.ws_handshake_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("server.session_subscribe_ms");

    expect(SLO_THRESHOLDS).not.toHaveProperty("chat.full_reload_ms");
    expect(SLO_THRESHOLDS).not.toHaveProperty("chat.subscribe_ack_ms");
    expect(SLO_THRESHOLDS).not.toHaveProperty("chat.ws_connect_ms");
    expect(SLO_THRESHOLDS).not.toHaveProperty("chat.connected_dispatch_ms");
    expect(SLO_THRESHOLDS).not.toHaveProperty("server.dictation_llm_correction_ms");
    expect(SLO_THRESHOLDS).not.toHaveProperty("chat.session_list_row_compute_ms");
  });

  it("counts server resource samples as telemetry data", () => {
    const telemetryDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-review-"));
    try {
      const now = Date.now();
      writeFileSync(
        join(telemetryDir, "server-metrics-2026-05-31.jsonl"),
        JSON.stringify({
          ts: now,
          cpu: { total: 12 },
          memory: { rss: 123, heapUsed: 45 },
          sessions: { total: 2 },
          wsConnections: 3,
          eventLoop: { p99: 7 },
        }) + "\n",
      );

      const result = loadSamples(telemetryDir, 1);

      expect(result.filesRead).toBe(1);
      expect(result.totalSamples).toBe(6);
      expect(result.samples).toHaveLength(6);
      expect(result.values["server.cpu_total"]?.vals).toEqual([12]);
      expect(result.values["server.event_loop_lag_ms"]?.vals).toEqual([7]);
    } finally {
      rmSync(telemetryDir, { recursive: true, force: true });
    }
  });

  it("excludes failed trace fetches from latency SLOs", () => {
    const telemetryDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-review-"));
    try {
      const now = Date.now();
      writeFileSync(
        join(telemetryDir, "chat-metrics-2026-07-14.jsonl"),
        JSON.stringify({
          buildNumber: "42",
          samples: [
            {
              ts: now,
              metric: "chat.trace_fetch_ms",
              value: 120,
              unit: "ms",
              tags: { status: "ok" },
            },
            {
              ts: now,
              metric: "chat.trace_fetch_ms",
              value: 10_000,
              unit: "ms",
              tags: { status: "error", error_kind: "timeout" },
            },
          ],
        }) + "\n",
      );

      const result = loadSamples(telemetryDir, 1);

      expect(result.values["chat.trace_fetch_ms"]?.vals).toEqual([120]);
    } finally {
      rmSync(telemetryDir, { recursive: true, force: true });
    }
  });

  it("buckets trend samples into deterministic p95 windows", () => {
    const endTs = Date.UTC(2026, 4, 13, 12, 0, 0);
    const data = makeReviewData(endTs);

    const buckets = buildTrendBuckets(data, ["chat.timeline_apply_ms"], {
      days: 1,
      bucketCount: 4,
      dictationOnly: false,
      endTs,
    });

    expect(buckets).toHaveLength(4);
    expect(buckets[0].metrics["chat.timeline_apply_ms"]?.p95).toBe(10);
    expect(buckets[1].metrics["chat.timeline_apply_ms"]?.p95).toBe(20);
    expect(buckets[2].metrics["chat.timeline_apply_ms"]?.p95).toBe(50);
    expect(buckets[3].metrics["chat.timeline_apply_ms"]?.p95).toBe(40);
  });

  it("renders an svg dashboard with escaped labels and status cards", () => {
    const endTs = Date.UTC(2026, 4, 13, 12, 0, 0);
    const data = makeReviewData(endTs);
    for (const sample of data.samples) {
      if (sample.metric === "chat.timeline_apply_ms") sample.value = 50;
    }
    data.values["chat.timeline_apply_ms"].vals = [50, 50, 50, 50, 50];

    const result = review(data, {
      days: 1,
      dataDir: "/tmp/oppi-test-data",
      dictationOnly: false,
      byTags: [],
    });
    const trendBuckets = buildTrendBuckets(data, Object.keys(result.metrics), {
      days: 1,
      bucketCount: 4,
      dictationOnly: false,
      endTs,
    });

    const svg = buildTelemetryTrendSvg(result, trendBuckets, {
      dictationOnly: false,
      title: "Release <31>",
      subtitle: "A & B",
    });

    expect(svg).toContain("<svg");
    expect(svg).toContain("Release &lt;31&gt;");
    expect(svg).toContain("A &amp; B");
    expect(result.summary.statusBasis).toBe("tm99_vs_slo");
    expect(svg).toContain("Timeline apply (30fps)");
    expect(svg).toContain("Time to first token");
    expect(svg).toContain("overall tm99");
    expect(svg).toContain(">OVER<");
    expect(svg).toContain("SLO 20.0ms");
  });
});

describe("telemetry-review --models", () => {
  it("parses a read-only models mode", () => {
    expect(parseArgs(["--models", "--days", "3", "--json"]).models).toBe(true);
    expect(parseArgs(["--wide"]).models).toBe(false);
  });

  it("reports latency, call frequency, and error rates by model and model+tool", () => {
    const now = Date.now();
    const data = {
      values: {},
      byBuild: {},
      buildSummary: {},
      samples: [
        {
          ts: now,
          metric: "server.turn_ttft_ms",
          value: 100,
          unit: "ms",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_ttft_ms",
          value: 300,
          unit: "ms",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_duration_ms",
          value: 1_000,
          unit: "ms",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_duration_ms",
          value: 3_000,
          unit: "ms",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_error",
          value: 1,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_tool_calls",
          value: 2,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_input_tokens",
          value: 1_000,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_output_tokens",
          value: 500,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_cost",
          value: 250_000,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_input_tokens",
          value: 500,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_output_tokens",
          value: 100,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.turn_cost",
          value: 50_000,
          unit: "count",
          tags: { provider: "anthropic", model: "claude-sonnet-4-0" },
        },
        {
          ts: now,
          metric: "server.tool_duration_ms",
          value: 40,
          unit: "ms",
          tags: {
            provider: "anthropic",
            model: "claude-sonnet-4-0",
            tool: "bash",
            status: "ok",
          },
        },
        {
          ts: now,
          metric: "server.tool_duration_ms",
          value: 80,
          unit: "ms",
          tags: {
            provider: "anthropic",
            model: "claude-sonnet-4-0",
            tool: "bash",
            status: "error",
          },
        },
        {
          ts: now,
          metric: "server.tool_result",
          value: 1,
          unit: "count",
          tags: {
            provider: "anthropic",
            model: "claude-sonnet-4-0",
            tool: "bash",
            status: "ok",
          },
        },
        {
          ts: now,
          metric: "server.tool_result",
          value: 1,
          unit: "count",
          tags: {
            provider: "anthropic",
            model: "claude-sonnet-4-0",
            tool: "bash",
            status: "error",
          },
        },
        {
          ts: now,
          metric: "server.turn_duration_ms",
          value: 9_000,
          unit: "ms",
        },
        {
          ts: now,
          metric: "server.turn_tool_calls",
          value: 3,
          unit: "count",
        },
        {
          ts: now,
          metric: "server.tool_result",
          value: 1,
          unit: "count",
          tags: { tool: "read", status: "ok" },
        },
      ],
      totalSamples: 19,
      filesRead: 1,
    } satisfies Parameters<typeof reviewModels>[0];

    const result = reviewModels(data, { days: 2 });
    expect(result.untaggedSamples).toBe(3);
    expect(result.note).toMatch(/operational success is not accepted-task correctness/i);

    const tagged = result.models.find(
      (row) => row.provider === "anthropic" && row.model === "claude-sonnet-4-0",
    );
    expect(tagged).toMatchObject({
      samples: 16,
      turns: 2,
      untagged: false,
      ttft: { count: 2, p50: 100, p95: 300 },
      turnDuration: { count: 2, p50: 1_000, p95: 3_000 },
      toolDuration: { count: 2, p50: 40, p95: 80 },
      toolCalls: 2,
      observedToolResults: 2,
      toolCallFrequency: 1,
      turnErrorRate: 0.5,
      toolErrorRate: 0.5,
      inputTokens: 1_500,
      outputTokens: 600,
      costUsd: 0.3,
      totalCostPerToolStartUsd: 0.15,
      totalOutputTokensPerToolStart: 300,
    });

    const untagged = result.models.find((row) => row.untagged);
    expect(untagged).toMatchObject({
      provider: null,
      model: null,
      samples: 3,
      turns: 1,
      toolCalls: 3,
      observedToolResults: 1,
    });

    const bash = result.modelTools.find(
      (row) =>
        row.provider === "anthropic" && row.model === "claude-sonnet-4-0" && row.tool === "bash",
    );
    expect(bash).toMatchObject({
      calls: 2,
      frequency: 1,
      duration: { count: 2, p50: 40, p95: 80 },
      errors: 1,
      errorRate: 0.5,
      untagged: false,
    });

    const historical = result.modelTools.find((row) => row.untagged && row.tool === "read");
    expect(historical).toMatchObject({
      provider: null,
      model: null,
      calls: 1,
      errors: 0,
      errorRate: 0,
    });
  });

  it("prints human output with untagged history and the operational-success caveat", () => {
    const now = Date.now();
    const result = reviewModels(
      {
        values: {},
        byBuild: {},
        buildSummary: {},
        samples: [
          {
            ts: now,
            metric: "server.turn_ttft_ms",
            value: 120,
            unit: "ms",
            tags: { provider: "openai", model: "gpt-5.5" },
          },
          {
            ts: now,
            metric: "server.turn_duration_ms",
            value: 2_000,
            unit: "ms",
          },
        ],
        totalSamples: 2,
        filesRead: 1,
      },
      { days: 1 },
    );

    const text = formatModelsReview(result, { noColor: true });
    expect(text).toContain("openai/gpt-5.5");
    expect(text).toContain("untagged");
    expect(text).toMatch(/operational success is not accepted-task correctness/i);
    expect(text).toContain("p50");
    expect(text).toContain("p95");
    expect(text).toContain("Total$/call");
  });
});
