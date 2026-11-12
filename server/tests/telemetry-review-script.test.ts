import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  SLO_THRESHOLDS,
  buildTelemetryTrendSvg,
  buildTrendBuckets,
  formatHttpReview,
  formatModelsReview,
  loadSamples,
  parseArgs,
  review,
  reviewHttp,
  reviewModels,
  type LoadedRecord,
} from "../scripts/telemetry-review.ts";

const HOUR_MS = 60 * 60 * 1_000;
const APPLY = "app.timeline_apply.duration_ms";
const TTFT = "app.ttft.duration_ms";

type ReviewData = Parameters<typeof review>[0];

function dataOf(records: LoadedRecord[]): ReviewData {
  return {
    values: {},
    byBuild: {},
    buildSummary: {},
    samples: [],
    records,
    foregroundMinutes: {},
    totalSamples: records.length,
    filesRead: 1,
  };
}

function makeReviewData(endTs: number): ReviewData {
  const startTs = endTs - 24 * HOUR_MS;
  const device = "iPhone" as const;
  const samples = [
    { ts: startTs + 1 * HOUR_MS, metric: APPLY, value: 10, unit: "ms", device },
    { ts: startTs + 7 * HOUR_MS, metric: APPLY, value: 20, unit: "ms", device },
    { ts: startTs + 13 * HOUR_MS, metric: APPLY, value: 30, unit: "ms", device },
    { ts: startTs + 13.5 * HOUR_MS, metric: APPLY, value: 50, unit: "ms", device },
    { ts: startTs + 21 * HOUR_MS, metric: APPLY, value: 40, unit: "ms", device },
    { ts: startTs + 2 * HOUR_MS, metric: TTFT, value: 800, unit: "ms", device },
    { ts: startTs + 8 * HOUR_MS, metric: TTFT, value: 900, unit: "ms", device },
    { ts: startTs + 14 * HOUR_MS, metric: TTFT, value: 1000, unit: "ms", device },
    { ts: startTs + 20 * HOUR_MS, metric: TTFT, value: 1200, unit: "ms", device },
  ];

  return {
    values: {
      [APPLY]: { vals: [10, 20, 30, 50, 40], unit: "ms" },
      [TTFT]: { vals: [800, 900, 1000, 1200], unit: "ms" },
    },
    byBuild: {},
    buildSummary: {},
    samples,
    records: [],
    // Five slow applies in one foreground minute.
    foregroundMinutes: { iPhone: 1 },
    totalSamples: samples.length,
    filesRead: 1,
  };
}

function withTelemetryDir(files: Record<string, unknown[]>, run: (dir: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "oppi-telemetry-review-"));
  try {
    for (const [name, lines] of Object.entries(files)) {
      writeFileSync(join(dir, name), lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
    }
    run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("telemetry-review on v2 events", () => {
  it("splits multi-field events into per-field series with catalog units and builds", () => {
    const now = Date.now();
    withTelemetryDir(
      {
        "app-events-2026-10-27.jsonl": [
          {
            v: 2,
            ts: now,
            origin: "app",
            name: "app.device_resources",
            fields: { cpu_pct: 12.5, memory_mb: 180, memory_available_mb: 900, thermal_state: 0 },
            tags: { screen: "chat" },
            client: { kind: "ios", buildNumber: "77", appVersion: "1.2" },
          },
          // An event the catalog no longer has, and a legacy line, are skipped.
          { v: 2, ts: now, origin: "app", name: "app.retired_thing", fields: { x: 1 }, tags: {} },
          { metric: "chat.ttft_ms", value: 5, ts: now },
        ],
        "server-events-2026-10-27.jsonl": [
          {
            v: 2,
            ts: now,
            origin: "server",
            name: "server.resources",
            fields: { cpu_total_pct: 3, event_loop_p99_ms: 20, event_loop_max_ms: 40 },
            tags: {},
          },
        ],
        // Pre-v2 files are not read.
        "chat-metrics-2026-10-27.jsonl": [
          { samples: [{ ts: now, metric: "chat.ttft_ms", value: 1, unit: "ms" }] },
        ],
      },
      (dir) => {
        const loaded = loadSamples(dir, 1);
        expect(loaded.filesRead).toBe(2);
        expect(loaded.totalSamples).toBe(2);
        expect(loaded.values["app.device_resources.memory_mb"]).toEqual({
          vals: [180],
          unit: "mb",
        });
        expect(loaded.values["app.device_resources.cpu_pct"]?.unit).toBe("pct");
        expect(loaded.values["server.resources.event_loop_max_ms"]?.vals).toEqual([40]);
        expect(loaded.buildSummary["77"]).toMatchObject({ version: "1.2", samples: 1 });
        expect(loaded.byBuild["77"]?.["app.device_resources.memory_mb"]?.vals).toEqual([180]);
      },
    );
  });

  it("separates builds by commit and breaks a metric down by app launch", () => {
    const now = Date.now();
    const memory = (mb: number, client: Record<string, string>) => ({
      v: 2,
      ts: now,
      origin: "app",
      name: "app.device_resources",
      fields: { memory_mb: mb },
      tags: {},
      client: { kind: "ios", buildNumber: "56", appVersion: "1.1.2", ...client },
    });
    withTelemetryDir(
      {
        "app-events-2026-10-27.jsonl": [
          memory(100, { gitCommit: "aaaaaaaaaaaa", bootId: "boot-1" }),
          memory(120, { gitCommit: "aaaaaaaaaaaa", bootId: "boot-2" }),
          memory(300, { gitCommit: "bbbbbbbbbbbb", bootId: "boot-3" }),
          // No commit: still counted, labelled by build number alone.
          memory(50, {}),
        ],
      },
      (dir) => {
        const loaded = loadSamples(dir, 1);
        const result = review(loaded, {
          days: 1,
          dataDir: "/tmp/oppi-test-data",
          dictationOnly: false,
          byTags: ["boot"],
        });

        expect(Object.keys(result.builds).sort()).toEqual([
          "56",
          "56@aaaaaaaaaaaa",
          "56@bbbbbbbbbbbb",
        ]);
        const memoryMax = (label: string) =>
          result.builds[label]?.metrics["app.device_resources.memory_mb"]?.max;
        expect(memoryMax("56@aaaaaaaaaaaa")).toBe(120);
        expect(memoryMax("56@bbbbbbbbbbbb")).toBe(300);
        expect(memoryMax("56")).toBe(50);
        expect(result.builds["56@aaaaaaaaaaaa"]).toMatchObject({ version: "1.1.2", samples: 2 });

        // Fleet-wide series and counts do not depend on the split.
        expect(result.metrics["app.device_resources.memory_mb"]?.count).toBe(4);
        expect(result.summary.totalSamples).toBe(4);

        const boot = result.breakdowns.find((section) => section.tag === "boot");
        expect(Object.keys(boot?.values ?? {}).sort()).toEqual(["boot-1", "boot-2", "boot-3"]);
        expect(boot?.values["boot-3"]?.metrics["app.device_resources.memory_mb"]?.max).toBe(300);
      },
    );
  });

  it("narrows client events to one device and breaks a metric down by device", () => {
    const now = Date.now();
    const memory = (mb: number, deviceModel: string) => ({
      v: 2,
      ts: now,
      origin: "app",
      name: "app.device_resources",
      fields: { memory_mb: mb },
      tags: {},
      client: { kind: "ios", buildNumber: "57", deviceModel },
    });
    withTelemetryDir(
      {
        "app-events-2026-10-27.jsonl": [
          memory(200, "iPhone17,1"),
          memory(400, "iPad19,1"),
          memory(500, "iPad19,1"),
        ],
        "server-events-2026-10-27.jsonl": [
          {
            v: 2,
            ts: now,
            origin: "server",
            name: "server.resources",
            fields: { rss_mb: 300 },
            tags: {},
          },
        ],
      },
      (dir) => {
        const options = { days: 1, dataDir: "/tmp/oppi-test-data", dictationOnly: false };
        const all = review(loadSamples(dir, 1), { ...options, byTags: ["device"] });
        expect(all.summary.devices).toEqual({ iPhone: 1, iPad: 2 });
        const byDevice = all.breakdowns.find((section) => section.tag === "device");
        expect(byDevice?.values.iPad?.metrics["app.device_resources.memory_mb"]?.max).toBe(500);
        expect(byDevice?.values.iPhone?.metrics["app.device_resources.memory_mb"]?.max).toBe(200);

        const ipad = review(loadSamples(dir, 1, "iPad"), { ...options, byTags: [] });
        expect(ipad.summary.devices).toEqual({ iPad: 2 });
        expect(ipad.metrics["app.device_resources.memory_mb"]?.count).toBe(2);
        // Server events have no device and stay in a device-narrowed review.
        expect(ipad.metrics["server.resources.rss_mb"]?.count).toBe(1);
      },
    );
  });

  it("keeps only events matching an SLO's where filter in that field's series", () => {
    const now = Date.now();
    const event = (status: string, durationMs: number) => ({
      v: 2,
      ts: now,
      origin: "app",
      name: "app.trace_fetch",
      fields: { duration_ms: durationMs },
      tags: status === "ok" ? { status } : { status, error_kind: "timeout" },
    });
    withTelemetryDir(
      { "app-events-2026-10-27.jsonl": [event("ok", 120), event("error", 10_000)] },
      (dir) => {
        const loaded = loadSamples(dir, 1);
        expect(loaded.values["app.trace_fetch.duration_ms"]?.vals).toEqual([120]);
        // The record itself stays available to breakdowns and counts.
        expect(loaded.records).toHaveLength(2);
      },
    );
  });

  it("judges every SLO per device and gates when any device is over", () => {
    expect(SLO_THRESHOLDS).not.toHaveProperty("server.resources.event_loop_p99_ms");
    const now = Date.now();
    const app = (name: string, fields: Record<string, number>, deviceModel: string) => ({
      v: 2,
      ts: now,
      origin: "app",
      name,
      fields,
      tags: {},
      client: { kind: "ios", deviceModel },
    });
    // One foreground sample every 10 s: the iPhone was active 1 minute, the iPad 2.
    const resources = (deviceModel: string, count: number, availableMb: number, thermal: number) =>
      Array.from({ length: count }, () =>
        app(
          "app.device_resources",
          { memory_available_mb: availableMb, thermal_state: thermal },
          deviceModel,
        ),
      );
    const apply = (ms: number, deviceModel: string) =>
      app("app.timeline_apply", { duration_ms: ms, items: 10, changed: 1 }, deviceModel);
    withTelemetryDir(
      {
        "app-events-2026-10-27.jsonl": [
          // iPhone: little headroom and hot the whole minute.
          ...resources("iPhone17,1", 6, 40, 2),
          ...resources("iPad19,1", 12, 4_000, 0),
          // Three slow applies in the iPhone's one minute, against a limit of 2.
          apply(12, "iPhone17,1"),
          apply(9, "iPhone17,1"),
          apply(30, "iPhone17,1"),
          apply(5, "iPhone17,1"),
          // Cheap applies on the iPad count for nothing; it was never slow.
          apply(5, "iPad19,1"),
        ],
        "server-events-2026-10-27.jsonl": Array.from({ length: 100 }, () => ({
          v: 2,
          ts: now,
          origin: "server",
          name: "server.resources",
          fields: { event_loop_max_ms: 120, event_loop_p99_ms: 5_000 },
          tags: {},
        })),
      },
      (dir) => {
        const options = {
          days: 1,
          dataDir: "/tmp/oppi-test-data",
          dictationOnly: false,
          byTags: [],
        };
        const result = review(loadSamples(dir, 1), options);
        const verdicts = (metric: string) =>
          Object.fromEntries(
            (result.metrics[metric]?.devices ?? []).map((row) => [
              row.device,
              [row.value, row.status],
            ]),
          );

        expect(verdicts("app.timeline_apply.duration_ms")).toEqual({
          iPhone: [3, "over"],
          iPad: [0, "pass"],
        });
        expect(verdicts("app.device_resources.memory_available_mb")).toEqual({
          iPhone: [40, "over"],
          iPad: [4_000, "pass"],
        });
        expect(verdicts("app.device_resources.thermal_state")).toEqual({
          iPhone: [1, "over"],
          iPad: [0, "pass"],
        });
        expect(verdicts("server.resources.event_loop_max_ms")).toEqual({ server: [120, "over"] });
        expect(result.metrics["server.resources.event_loop_p99_ms"]?.status).toBe("no_slo");
        expect(result.metrics["app.timeline_apply.duration_ms"]?.status).toBe("over");
        // Three iPhone misses and the server's; the iPad's passes do not hide them.
        expect(result.summary.violations).toBe(4);

        // Narrowed to the iPad, the same window passes on the client side.
        const ipad = review(loadSamples(dir, 1, "iPad"), options);
        expect(ipad.metrics["app.timeline_apply.duration_ms"]?.status).toBe("pass");
        expect(ipad.summary.violations).toBe(1);
      },
    );
  });

  it("judges a release only on the candidate build, so a device on an older build cannot fail it", () => {
    const now = Date.now();
    const RC = "aaaaaaaaaaaa";
    const app = (
      name: string,
      fields: Record<string, number>,
      deviceModel: string,
      gitCommit: string,
    ) => ({
      v: 2,
      ts: now,
      origin: "app",
      name,
      fields,
      tags: {},
      client: { kind: "ios", buildNumber: "58", deviceModel, gitCommit },
    });
    const minute = (deviceModel: string, gitCommit: string) =>
      Array.from({ length: 6 }, () =>
        app(
          "app.device_resources",
          { memory_available_mb: 2_000, thermal_state: 0 },
          deviceModel,
          gitCommit,
        ),
      );
    const slowApplies = (deviceModel: string, gitCommit: string) =>
      Array.from({ length: 5 }, () =>
        app(
          "app.timeline_apply",
          { duration_ms: 40, items: 10, changed: 1 },
          deviceModel,
          gitCommit,
        ),
      );
    withTelemetryDir(
      {
        "app-events-2026-10-27.jsonl": [
          // The iPhone runs the candidate and is smooth.
          ...minute("iPhone17,1", RC),
          // The iPad is still on an older build, and a local dirty build of the
          // candidate is not the candidate either: both are slow.
          ...minute("iPad19,1", "bbbbbbbbbbbb"),
          ...slowApplies("iPad19,1", "bbbbbbbbbbbb"),
          ...slowApplies("iPhone17,1", `${RC}-dirty`),
        ],
      },
      (dir) => {
        const options = {
          days: 1,
          dataDir: "/tmp/oppi-test-data",
          dictationOnly: false,
          byTags: [],
        };
        expect(review(loadSamples(dir, 1), options).summary.violations).toBeGreaterThan(0);

        // The full 40-character commit matches the stored 12-character one.
        const commit = `${RC}${"0".repeat(28)}`;
        const candidate = review(loadSamples(dir, 1, undefined, commit), { ...options, commit });
        expect(candidate.summary.violations).toBe(0);
        expect(candidate.summary.deviceBuilds).toEqual({ iPhone: [`58@${RC}`] });
        expect(candidate.summary.commit).toBe(commit);
      },
    );

    expect(() => parseArgs(["--gate"])).toThrow("--commit");
    expect(parseArgs(["--gate", "--commit", "AAAAAAA"]).commit).toBe("aaaaaaa");
  });

  it("breaks dictation down by tag with setup and capture error rates", () => {
    const now = Date.now();
    const setup = (model: string, status: string): LoadedRecord => ({
      ts: now,
      name: "app.dictation_setup",
      fields: { total_ms: 200 },
      tags: { voice_engine: "server", stt_model: model, status },
    });
    const result = review(
      dataOf([
        setup("whisper", "ok"),
        setup("whisper", "ok"),
        setup("whisper", "error"),
        setup("whisper", "cancelled"),
        setup("parakeet", "ok"),
        {
          ts: now,
          name: "app.dictation_capture_error",
          fields: {},
          tags: {
            voice_engine: "server",
            stt_model: "whisper",
            error_kind: "capture_pipeline_dead",
          },
        },
      ]),
      { days: 1, dataDir: "/tmp/oppi-test-data", dictationOnly: true, byTags: ["stt_model"] },
    );
    const section = result.breakdowns.find((entry) => entry.tag === "stt_model");
    expect(section?.values.whisper?.dictationErrors).toEqual({
      attempts: 3,
      errors: 2,
      setupErrors: 1,
      captureErrors: 1,
      errorRate: 2 / 3,
    });
    expect(section?.values.parakeet?.dictationErrors?.errorRate).toBe(0);
  });

  it("buckets trend samples into deterministic p95 windows", () => {
    const endTs = Date.UTC(2026, 4, 13, 12, 0, 0);
    const buckets = buildTrendBuckets(makeReviewData(endTs), [APPLY], {
      days: 1,
      bucketCount: 4,
      dictationOnly: false,
      endTs,
    });

    expect(buckets).toHaveLength(4);
    expect(buckets.map((bucket) => bucket.metrics[APPLY]?.p95)).toEqual([10, 20, 50, 40]);
  });

  it("renders an svg dashboard with escaped labels and per-device SLO verdicts", () => {
    const endTs = Date.UTC(2026, 4, 13, 12, 0, 0);
    const data = makeReviewData(endTs);
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

    expect(svg).toContain("Release &lt;31&gt;");
    expect(svg).toContain("A &amp; B");
    expect(svg).toContain("Slow timeline applies");
    expect(svg).toContain("iPhone 5.00/min");
    expect(svg).toContain("Time to first token");
    expect(svg).toContain(">OVER<");
    expect(svg).toContain("SLO ≤ 2.00/min (&gt; 8.3)");
  });
});

const ROUTE = { runtime: "durable", provider: "anthropic", model: "claude-sonnet-4-0" };

describe("telemetry-review --models", () => {
  it("parses a read-only models mode", () => {
    expect(parseArgs(["--models", "--days", "3", "--json"]).models).toBe(true);
    expect(parseArgs(["--wide"]).models).toBe(false);
  });

  it("reports latency, call frequency, cost, and error rates by model and model+tool", () => {
    const now = Date.now();
    const record = (
      name: string,
      fields: Record<string, number>,
      tags: Record<string, string>,
    ): LoadedRecord => ({ ts: now, name, fields, tags });
    const result = reviewModels(
      dataOf([
        record("server.turn_ttft", { duration_ms: 100 }, ROUTE),
        record("server.turn_ttft", { duration_ms: 300 }, ROUTE),
        record("server.turn", { duration_ms: 1_000, tool_calls: 2 }, { ...ROUTE, status: "ok" }),
        record(
          "server.turn",
          { duration_ms: 3_000, tool_calls: 0 },
          { ...ROUTE, status: "error", error_kind: "overloaded" },
        ),
        // Aggregated usage windows sum.
        record(
          "server.turn_usage",
          { input_tokens: 1_000, output_tokens: 500, cost_usd_micros: 250_000 },
          ROUTE,
        ),
        record(
          "server.turn_usage",
          { input_tokens: 500, output_tokens: 100, cost_usd_micros: 50_000 },
          ROUTE,
        ),
        record("server.tool_call", { duration_ms: 40 }, { ...ROUTE, tool: "bash", status: "ok" }),
        record(
          "server.tool_call",
          { duration_ms: 80 },
          { ...ROUTE, tool: "bash", status: "error" },
        ),
        // Untagged route: no provider/model.
        record(
          "server.turn",
          { duration_ms: 9_000, tool_calls: 3 },
          { runtime: "oppi", status: "ok" },
        ),
        // An unpaired tool end counts as a call without duration.
        record("server.tool_call", {}, { runtime: "oppi", tool: "read", status: "ok" }),
      ]),
      { days: 2 },
    );

    expect(result.untaggedSamples).toBe(2);
    expect(result.note).toMatch(/operational success is not accepted-task correctness/i);
    expect(result.models.find((row) => !row.untagged)).toMatchObject({
      samples: 8,
      turns: 2,
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
    expect(result.models.find((row) => row.untagged)).toMatchObject({
      samples: 2,
      turns: 1,
      toolCalls: 3,
      observedToolResults: 1,
    });
    expect(result.modelTools.find((row) => !row.untagged && row.tool === "bash")).toMatchObject({
      calls: 2,
      frequency: 1,
      duration: { count: 2 },
      errors: 1,
      errorRate: 0.5,
    });
    expect(result.modelTools.find((row) => row.untagged && row.tool === "read")).toMatchObject({
      calls: 1,
      duration: { count: 0 },
      errors: 0,
    });

    expect(result.runtimes.map((row) => row.runtime)).toEqual(["durable", "oppi"]);
    expect(result.runtimes[0]).toMatchObject({ turns: 2, turnErrorRate: 0.5, costUsd: 0.3 });

    const text = formatModelsReview(result, { noColor: true });
    expect(text).toContain("anthropic/claude-sonnet-4-0");
    expect(text).toContain("untagged");
    expect(text).toContain("Total$/call");
  });
});

describe("telemetry-review --http", () => {
  it("parses the http flag without turning on models mode", () => {
    expect(parseArgs(["--http", "--days", "1"]).http).toBe(true);
    expect(parseArgs(["--http"]).models).toBe(false);
    expect(parseArgs(["--wide"]).http).toBe(false);
  });

  it("reports duration percentiles, error rate, and response bytes by route", () => {
    const now = Date.now();
    const request = (
      durationMs: number,
      statusCode: string,
      responseBytes?: number,
      pathPattern = "/sessions/:sessionId",
    ): LoadedRecord => ({
      ts: now,
      name: "server.http_request",
      fields: {
        duration_ms: durationMs,
        ...(responseBytes === undefined ? {} : { response_bytes: responseBytes }),
      },
      tags: { method: "GET", path_pattern: pathPattern, status_code: statusCode },
    });
    const result = reviewHttp(
      dataOf([
        request(10, "200", 100),
        request(20, "200", 200),
        request(30, "200", 300),
        request(40, "500"),
        request(5, "404", 9, "unregistered"),
      ]),
      { days: 1 },
    );

    expect(result.samples).toBe(5);
    expect(result.routes[0]).toEqual({
      method: "GET",
      pathPattern: "/sessions/:sessionId",
      samples: 4,
      p50: 20,
      p90: 40,
      p99: 40,
      errors: 1,
      errorRate: 0.25,
      byteSamples: 3,
      bytesP50: 200,
      bytesP90: 300,
      bytesMax: 300,
    });
    expect(result.routes[1]).toMatchObject({ pathPattern: "unregistered", errors: 1 });
    expect(formatHttpReview(result, { noColor: true })).toContain("25.0%");
  });
});
