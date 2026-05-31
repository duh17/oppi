import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  SLO_THRESHOLDS,
  buildTelemetryTrendSvg,
  buildTrendBuckets,
  loadSamples,
  review,
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
    expect(SLO_THRESHOLDS).toHaveProperty("chat.ws_wait_for_connected_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("server.ws_handshake_ms");
    expect(SLO_THRESHOLDS).toHaveProperty("server.session_subscribe_ms");

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
