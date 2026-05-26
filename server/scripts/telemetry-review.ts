#!/usr/bin/env bun

/**
 * Oppi telemetry review — reads JSONL metric files, computes percentiles,
 * flags SLO reference threshold violations, and provides dictation-focused
 * dashboard views with engine/source/provider/model breakdowns.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

interface SloThreshold {
  p95: number;
  label: string;
  group: string;
  short: string;
  lowerIsBad?: boolean;
  displayUnit?: string;
}

interface LoadedSample {
  ts: number;
  metric: string;
  value: number;
  unit: string;
  tags?: Record<string, string>;
}

interface MetricBucket {
  vals: number[];
  unit: string;
}

interface MetricStats {
  count: number;
  tm99: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
}

interface MetricResult extends MetricStats {
  unit: string;
  slo_p95: number | null;
  group: string;
  status: "pass" | "over" | "no_slo";
}

interface BuildInfo {
  version: string;
  samples: number;
  firstSeen: number;
  lastSeen: number;
}

interface LoadResult {
  values: Record<string, MetricBucket>;
  byBuild: Record<string, Record<string, MetricBucket>>;
  buildSummary: Record<string, BuildInfo>;
  samples: LoadedSample[];
  totalSamples: number;
  filesRead: number;
}

interface DictationErrorSummary {
  attempts: number;
  errors: number;
  setupErrors: number;
  streamErrors: number;
  otherErrors: number;
  errorRate: number | null;
}

interface BreakdownEntry {
  sampleCount: number;
  metrics: Record<string, MetricResult>;
  dictationErrors?: DictationErrorSummary;
}

interface BreakdownSection {
  tag: string;
  values: Record<string, BreakdownEntry>;
}

interface ReviewSummary {
  days: number;
  totalSamples: number;
  filesRead: number;
  violations: number;
  sloMetricCount: number;
  groups: Record<string, { pass: number; over: number; missing: number }>;
  statusBasis: "tm99_vs_slo";
}

interface DictationConfigSummary {
  sttProvider: string;
  sttModel: string;
  sttEndpoint: string;
  llmCorrectionEnabled: boolean;
  llmModel: string;
}

interface DictationAssetModelSummary {
  sessions: number;
  totalDurationMs: number;
  totalStorageBytes: number;
  llmCorrectedSessions: number;
}

interface DictationAssetSummary {
  sessions: number;
  totalDurationMs: number;
  totalStorageBytes: number;
  formats: Record<string, number>;
  languages: Record<string, number>;
  models: Record<string, DictationAssetModelSummary>;
}

interface ReviewOutput {
  summary: ReviewSummary;
  metrics: Record<string, MetricResult>;
  builds: Record<string, BuildInfo & { metrics: Record<string, MetricStats & { unit: string }> }>;
  breakdowns: BreakdownSection[];
  dictationAssets: DictationAssetSummary | null;
  dictationConfig: DictationConfigSummary | null;
  fetchedAt: string;
}

export const STATUS_FILTERED_METRICS = new Set(["chat.queue_sync_ms", "chat.message_queue_ack_ms"]);

// Release SLOs gate on TM99, not raw p95. Values are intentionally tighter
// than historical p95-era thresholds while keeping headroom over recent
// two-week daily TM99 behavior.
export const SLO_THRESHOLDS: Record<string, SloThreshold> = {
  "chat.ttft_ms": { p95: 20_000, label: "Time to first token", group: "UX Quality", short: "ttft" },
  "chat.fresh_content_lag_ms": {
    p95: 1_000,
    label: "Fresh content lag",
    group: "UX Quality",
    short: "content_lag",
  },
  "chat.catchup_ms": {
    p95: 500,
    label: "Reconnection catch-up",
    group: "UX Quality",
    short: "catchup",
  },
  "chat.full_reload_ms": {
    p95: 1_500,
    label: "Full reload",
    group: "UX Quality",
    short: "full_reload",
  },
  "chat.cache_load_ms": { p95: 200, label: "Cache load", group: "UX Quality", short: "cache_load" },
  "chat.reducer_load_ms": {
    p95: 200,
    label: "Timeline rebuild",
    group: "UX Quality",
    short: "reducer",
  },
  "chat.session_load_ms": {
    p95: 600,
    label: "Session switch",
    group: "UX Quality",
    short: "sess_load",
  },
  "chat.app_launch_ms": {
    p95: 1_000,
    label: "App cold start",
    group: "UX Quality",
    short: "app_launch",
  },

  "chat.ws_wait_for_connected_ms": {
    p95: 1_000,
    label: "Client WS connected wait",
    group: "Network",
    short: "ws_wait",
  },
  "server.ws_handshake_ms": {
    p95: 100,
    label: "Server WS handshake",
    group: "Network",
    short: "ws_handshake",
  },
  "server.session_subscribe_ms": {
    p95: 300,
    label: "Server session subscribe",
    group: "Network",
    short: "srv_sub",
  },
  "chat.queue_sync_ms": {
    p95: 500,
    label: "Queue sync (ok only)",
    group: "Network",
    short: "queue_sync",
  },
  "chat.message_queue_ack_ms": {
    p95: 300,
    label: "Message queue ack (ok)",
    group: "Network",
    short: "msg_ack",
  },

  "chat.timeline_apply_ms": {
    p95: 20,
    label: "Timeline apply (30fps)",
    group: "Render",
    short: "tl_apply",
  },
  "chat.timeline_layout_ms": {
    p95: 16,
    label: "Timeline layout (60fps)",
    group: "Render",
    short: "tl_layout",
  },
  "chat.cell_configure_ms": {
    p95: 8,
    label: "Cell configure",
    group: "Render",
    short: "cell_config",
  },
  "chat.markdown_streaming_ms": {
    p95: 16,
    label: "Streaming markdown",
    group: "Render",
    short: "md_stream",
  },
  "chat.jank_pct": { p95: 25, label: "Scroll jank %", group: "Render", short: "jank_pct" },

  "chat.voice_setup_ms": {
    p95: 150,
    label: "Voice setup (legacy alias)",
    group: "Voice Compatibility",
    short: "voice_setup",
  },
  "chat.voice_first_result_ms": {
    p95: 6_000,
    label: "Voice first result (legacy alias)",
    group: "Voice Compatibility",
    short: "voice_1st",
  },
  "chat.voice_prewarm_ms": {
    p95: 100,
    label: "Voice prewarm (legacy alias)",
    group: "Voice Compatibility",
    short: "voice_prewarm",
  },

  "chat.dictation_setup_ms": {
    p95: 350,
    label: "Dictation setup",
    group: "Dictation UX",
    short: "setup",
  },
  "chat.dictation_first_result_ms": {
    p95: 6_000,
    label: "Dictation first result",
    group: "Dictation UX",
    short: "first_result",
  },
  "chat.dictation_finalize_ms": {
    p95: 500,
    label: "Dictation finalize",
    group: "Dictation UX",
    short: "finalize",
  },
  "chat.dictation_preview_final_delta": {
    p95: 0.15,
    label: "Preview/final delta",
    group: "Dictation UX",
    short: "preview_delta",
  },

  "server.dictation_stt_ms": {
    p95: 200,
    label: "STT inference",
    group: "Dictation Backend",
    short: "stt_ms",
  },
  "server.dictation_stt_audio_ratio": {
    p95: 0.1,
    label: "STT real-time factor",
    group: "Dictation Backend",
    short: "stt_rtf",
  },
  "server.dictation_finalize_ms": {
    p95: 250,
    label: "Finalize total",
    group: "Dictation Backend",
    short: "finalize",
  },
  "chat.session_list_compute_ms": {
    p95: 10,
    label: "List compute",
    group: "Session List",
    short: "list_compute",
  },
  "chat.session_list_body_rate": {
    p95: 12,
    label: "List body evals/5s",
    group: "Session List",
    short: "list_body",
  },

  "device.cpu_pct": {
    p95: 20,
    label: "CPU usage %",
    group: "Device",
    short: "cpu_pct",
    displayUnit: "pct",
  },
  "device.memory_mb": {
    p95: 250,
    label: "Memory footprint",
    group: "Device",
    short: "mem_mb",
    displayUnit: "mb",
  },
  "device.memory_available_mb": {
    p95: 100,
    label: "Memory avail (low=bad)",
    group: "Device",
    short: "mem_avail",
    lowerIsBad: true,
    displayUnit: "mb",
  },
  "device.thermal_state": { p95: 1, label: "Thermal (0-3)", group: "Device", short: "thermal" },

  "server.cpu_total": {
    p95: 10,
    label: "Server CPU %",
    group: "Server",
    short: "srv_cpu",
    displayUnit: "pct",
  },
  "server.rss_mb": {
    p95: 800,
    label: "Server RSS",
    group: "Server",
    short: "srv_rss",
    displayUnit: "mb",
  },
  "server.heap_mb": {
    p95: 200,
    label: "Server heap",
    group: "Server",
    short: "srv_heap",
    displayUnit: "mb",
  },
  "server.ws_connections": { p95: 5, label: "WS connections", group: "Server", short: "srv_ws" },
  "server.sessions_total": {
    p95: 8,
    label: "Active sessions",
    group: "Server",
    short: "srv_sess",
  },
};

const DICTATION_COMPARE_METRICS = [
  "chat.dictation_setup_ms",
  "chat.dictation_first_result_ms",
  "chat.dictation_finalize_ms",
  "chat.dictation_preview_final_delta",
  "server.dictation_stt_ms",
  "server.dictation_stt_audio_ratio",
] as const;

const DICTATION_BREAKDOWN_METRICS = new Set<string>([
  ...DICTATION_COMPARE_METRICS,
  "server.dictation_finalize_ms",
  "chat.dictation_error",
]);

function inferUnit(metric: string): string {
  if (metric.endsWith("_ratio") || metric.includes("_delta")) return "ratio";
  if (metric.endsWith("_pct")) return "pct";
  if (metric.endsWith("_mb")) return "mb";
  if (
    metric.endsWith("_count") ||
    metric.endsWith("_skip") ||
    metric.endsWith("_error") ||
    metric.endsWith("_cancel") ||
    metric.endsWith("_updates")
  )
    return "count";
  return "ms";
}

function isDictationMetric(metric: string): boolean {
  return (
    metric.startsWith("chat.dictation_") ||
    metric.startsWith("server.dictation_") ||
    metric.startsWith("chat.voice_")
  );
}

function shouldIncludeMetric(metric: string, dictationOnly: boolean): boolean {
  return dictationOnly ? isDictationMetric(metric) : true;
}

function pushValue(
  values: Record<string, MetricBucket>,
  metric: string,
  value: number,
  unit: string,
): void {
  if (!values[metric]) values[metric] = { vals: [], unit };
  values[metric].vals.push(value);
}

function pushSample(samples: LoadedSample[], sample: LoadedSample): void {
  samples.push(sample);
}

export function loadSamples(telemetryDir: string, daysBack: number): LoadResult {
  const cutoffMs = Date.now() - daysBack * 24 * 60 * 60 * 1_000;
  const values: Record<string, MetricBucket> = {};
  const byBuild: Record<string, Record<string, MetricBucket>> = {};
  const buildSummary: Record<string, BuildInfo> = {};
  const samples: LoadedSample[] = [];
  let totalSamples = 0;
  let filesRead = 0;

  let files: string[] = [];
  try {
    files = readdirSync(telemetryDir)
      .filter((f) => f.startsWith("chat-metrics-") && f.endsWith(".jsonl"))
      .sort();
  } catch {
    return { values, byBuild, buildSummary, samples, totalSamples: 0, filesRead: 0 };
  }

  for (const file of files) {
    const text = readFileSync(join(telemetryDir, file), "utf8");
    filesRead += 1;

    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let record: { buildNumber?: string; appVersion?: string; samples?: LoadedSample[] };
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }

      const build = record.buildNumber ?? "unknown";
      const version = record.appVersion ?? "?";

      for (const sample of record.samples ?? []) {
        if (typeof sample.ts !== "number" || sample.ts < cutoffMs) continue;
        if (typeof sample.value !== "number" || !Number.isFinite(sample.value)) continue;

        if (STATUS_FILTERED_METRICS.has(sample.metric)) {
          const status = sample.tags?.status;
          if (status && status !== "ok") continue;
        }

        const unit = sample.unit ?? inferUnit(sample.metric);
        pushValue(values, sample.metric, sample.value, unit);
        if (!byBuild[build]) byBuild[build] = {};
        pushValue(byBuild[build], sample.metric, sample.value, unit);
        pushSample(samples, { ...sample, unit });

        if (!buildSummary[build]) {
          buildSummary[build] = { version, samples: 0, firstSeen: sample.ts, lastSeen: sample.ts };
        }
        buildSummary[build].samples += 1;
        buildSummary[build].firstSeen = Math.min(buildSummary[build].firstSeen, sample.ts);
        buildSummary[build].lastSeen = Math.max(buildSummary[build].lastSeen, sample.ts);
        totalSamples += 1;
      }
    }
  }

  loadServerMetrics(telemetryDir, cutoffMs, values, samples);
  const opsResult = loadServerOpsMetrics(telemetryDir, cutoffMs, values, samples);
  totalSamples += opsResult.samples;
  filesRead += opsResult.files;

  return { values, byBuild, buildSummary, samples, totalSamples, filesRead };
}

function loadServerMetrics(
  telemetryDir: string,
  cutoffMs: number,
  values: Record<string, MetricBucket>,
  samples: LoadedSample[],
): void {
  let files: string[] = [];
  try {
    files = readdirSync(telemetryDir)
      .filter((f) => f.startsWith("server-metrics-") && f.endsWith(".jsonl"))
      .sort();
  } catch {
    return;
  }

  for (const file of files) {
    const text = readFileSync(join(telemetryDir, file), "utf8");
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let rec: {
        ts?: number;
        cpu?: { total?: number };
        memory?: { rss?: number; heapUsed?: number };
        sessions?: { total?: number };
        wsConnections?: number;
      };
      try {
        rec = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof rec.ts !== "number" || rec.ts < cutoffMs) continue;

      const push = (metric: string, val: number | undefined, unit: string) => {
        if (typeof val !== "number" || !Number.isFinite(val)) return;
        pushValue(values, metric, val, unit);
        pushSample(samples, { ts: rec.ts!, metric, value: val, unit });
      };

      push("server.cpu_total", rec.cpu?.total, "pct");
      push("server.rss_mb", rec.memory?.rss, "mb");
      push("server.heap_mb", rec.memory?.heapUsed, "mb");
      push("server.ws_connections", rec.wsConnections, "count");
      push("server.sessions_total", rec.sessions?.total, "count");
    }
  }
}

function loadServerOpsMetrics(
  telemetryDir: string,
  cutoffMs: number,
  values: Record<string, MetricBucket>,
  samples: LoadedSample[],
): { samples: number; files: number } {
  let files: string[] = [];
  let totalSamples = 0;
  let filesRead = 0;
  try {
    files = readdirSync(telemetryDir)
      .filter((f) => f.startsWith("server-ops-metrics-") && f.endsWith(".jsonl"))
      .sort();
  } catch {
    return { samples: 0, files: 0 };
  }

  for (const file of files) {
    const text = readFileSync(join(telemetryDir, file), "utf8");
    filesRead += 1;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let record: {
        samples?: Array<{
          ts?: number;
          metric?: string;
          value?: number;
          tags?: Record<string, string>;
        }>;
      };
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }

      for (const sample of record.samples ?? []) {
        if (typeof sample.ts !== "number" || sample.ts < cutoffMs) continue;
        if (typeof sample.metric !== "string") continue;
        if (typeof sample.value !== "number" || !Number.isFinite(sample.value)) continue;
        const unit = inferUnit(sample.metric);
        pushValue(values, sample.metric, sample.value, unit);
        pushSample(samples, {
          ts: sample.ts,
          metric: sample.metric,
          value: sample.value,
          unit,
          tags: sample.tags,
        });
        totalSamples += 1;
      }
    }
  }

  return { samples: totalSamples, files: filesRead };
}

function walkJsonFiles(dir: string): string[] {
  const out: string[] = [];
  if (!existsSync(dir)) return out;
  const stack = [dir];
  while (stack.length > 0) {
    const current = stack.pop()!;
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (
        entry.isFile() &&
        entry.name.endsWith(".json") &&
        entry.name !== "dictionary.json"
      ) {
        out.push(full);
      }
    }
  }
  return out.sort();
}

function loadDictationAssetSummary(
  dataDir: string,
  daysBack: number,
): DictationAssetSummary | null {
  const dictationDir = join(dataDir, "dictation");
  const cutoffMs = Date.now() - daysBack * 24 * 60 * 60 * 1_000;
  const summary: DictationAssetSummary = {
    sessions: 0,
    totalDurationMs: 0,
    totalStorageBytes: 0,
    formats: {},
    languages: {},
    models: {},
  };

  for (const file of walkJsonFiles(dictationDir)) {
    let meta: {
      startedAt?: string;
      durationMs?: number;
      language?: string;
      model?: string;
      timing?: { llmCorrectionMs?: number };
    };
    try {
      meta = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      continue;
    }

    const startedMs = meta.startedAt ? Date.parse(meta.startedAt) : NaN;
    if (!Number.isFinite(startedMs) || startedMs < cutoffMs) continue;

    const base = file.replace(/\.json$/, "");
    const audioPath = existsSync(`${base}.flac`)
      ? `${base}.flac`
      : existsSync(`${base}.wav`)
        ? `${base}.wav`
        : null;
    const format = audioPath?.endsWith(".flac")
      ? "flac"
      : audioPath?.endsWith(".wav")
        ? "wav"
        : "missing";
    const storageBytes = audioPath ? statSync(audioPath).size : 0;
    const model = meta.model ?? "unknown";
    const language = meta.language ?? "unknown";

    summary.sessions += 1;
    summary.totalDurationMs += Math.max(0, meta.durationMs ?? 0);
    summary.totalStorageBytes += storageBytes;
    summary.formats[format] = (summary.formats[format] ?? 0) + 1;
    summary.languages[language] = (summary.languages[language] ?? 0) + 1;
    if (!summary.models[model]) {
      summary.models[model] = {
        sessions: 0,
        totalDurationMs: 0,
        totalStorageBytes: 0,
        llmCorrectedSessions: 0,
      };
    }
    summary.models[model].sessions += 1;
    summary.models[model].totalDurationMs += Math.max(0, meta.durationMs ?? 0);
    summary.models[model].totalStorageBytes += storageBytes;
    if ((meta.timing?.llmCorrectionMs ?? 0) > 0) summary.models[model].llmCorrectedSessions += 1;
  }

  return summary.sessions > 0 ? summary : null;
}

function loadDictationConfigSummary(dataDir: string): DictationConfigSummary | null {
  const configPath = join(dataDir, "config.json");
  if (!existsSync(configPath)) return null;
  try {
    const raw = JSON.parse(readFileSync(configPath, "utf8")) as { asr?: Record<string, unknown> };
    const asr = raw.asr;
    if (!asr || typeof asr !== "object") return null;
    return {
      sttProvider: typeof asr.sttProvider === "string" ? asr.sttProvider : "mlx-server",
      sttModel: typeof asr.sttModel === "string" ? asr.sttModel : "unknown",
      sttEndpoint: typeof asr.sttEndpoint === "string" ? asr.sttEndpoint : "unknown",
      llmCorrectionEnabled: asr.llmCorrectionEnabled === true,
      llmModel: typeof asr.llmModel === "string" ? asr.llmModel : "unknown",
    };
  } catch {
    return null;
  }
}

export function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(Math.floor((sorted.length * p) / 100), sorted.length - 1);
  return sorted[idx];
}

export function trimmedMean99(sorted: number[]): number {
  if (sorted.length === 0) return 0;
  const cutIdx = Math.max(1, Math.floor(sorted.length * 0.99));
  let sum = 0;
  for (let i = 0; i < cutIdx; i++) sum += sorted[i];
  return sum / cutIdx;
}

export function computeStats(vals: number[]): MetricStats {
  const sorted = [...vals].sort((a, b) => a - b);
  return {
    count: sorted.length,
    tm99: trimmedMean99(sorted),
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
    max: sorted[sorted.length - 1] ?? 0,
  };
}

function statusValue(stats: MetricStats): number {
  return stats.tm99;
}

function metricPassesSlo(stats: MetricStats, slo: SloThreshold): boolean {
  const value = statusValue(stats);
  return slo.lowerIsBad ? value >= slo.p95 : value <= slo.p95;
}

function buildMetricResult(metric: string, vals: number[], unit: string): MetricResult {
  const stats = computeStats(vals);
  const slo = SLO_THRESHOLDS[metric];
  return {
    ...stats,
    unit: slo?.displayUnit ?? unit,
    slo_p95: slo?.p95 ?? null,
    group: slo?.group ?? "Informational",
    status: slo ? (metricPassesSlo(stats, slo) ? "pass" : "over") : "no_slo",
  };
}

function buildBreakdowns(
  data: LoadResult,
  byTags: string[],
  dictationOnly: boolean,
): BreakdownSection[] {
  const sections: BreakdownSection[] = [];

  for (const tag of byTags) {
    const buckets: Record<string, Record<string, MetricBucket>> = {};
    const dictationErrorsByValue: Record<
      string,
      {
        attempts: number;
        errors: number;
        setupErrors: number;
        streamErrors: number;
        otherErrors: number;
      }
    > = {};
    let sawAny = false;

    for (const sample of data.samples) {
      if (!shouldIncludeMetric(sample.metric, dictationOnly)) continue;
      if (dictationOnly && !DICTATION_BREAKDOWN_METRICS.has(sample.metric)) continue;
      const tagValue = sample.tags?.[tag];
      if (!tagValue) continue;
      sawAny = true;
      if (!buckets[tagValue]) buckets[tagValue] = {};
      if (!dictationErrorsByValue[tagValue]) {
        dictationErrorsByValue[tagValue] = {
          attempts: 0,
          errors: 0,
          setupErrors: 0,
          streamErrors: 0,
          otherErrors: 0,
        };
      }
      pushValue(buckets[tagValue], sample.metric, sample.value, sample.unit);

      if (sample.metric === "chat.dictation_setup_ms") {
        dictationErrorsByValue[tagValue].attempts += 1;
      } else if (sample.metric === "chat.dictation_error") {
        const count = Math.max(0, Math.round(sample.value));
        const phase = sample.tags?.phase;
        dictationErrorsByValue[tagValue].errors += count;
        if (phase === "setup") {
          dictationErrorsByValue[tagValue].setupErrors += count;
          dictationErrorsByValue[tagValue].attempts += count;
        } else if (phase === "stream") {
          dictationErrorsByValue[tagValue].streamErrors += count;
        } else {
          dictationErrorsByValue[tagValue].otherErrors += count;
        }
      }
    }

    if (!sawAny) continue;

    const values: Record<string, BreakdownEntry> = {};
    for (const [tagValue, metrics] of Object.entries(buckets)) {
      const metricResults: Record<string, MetricResult> = {};
      let sampleCount = 0;
      for (const [metric, bucket] of Object.entries(metrics)) {
        metricResults[metric] = buildMetricResult(metric, bucket.vals, bucket.unit);
        sampleCount += bucket.vals.length;
      }
      const errorSummary = dictationErrorsByValue[tagValue];
      values[tagValue] = {
        sampleCount,
        metrics: metricResults,
        dictationErrors:
          errorSummary && (errorSummary.attempts > 0 || errorSummary.errors > 0)
            ? {
                ...errorSummary,
                errorRate:
                  errorSummary.attempts > 0 ? errorSummary.errors / errorSummary.attempts : null,
              }
            : undefined,
      };
    }

    sections.push({
      tag,
      values: Object.fromEntries(
        Object.entries(values).sort(
          (a, b) =>
            (b[1].dictationErrors?.attempts ?? b[1].sampleCount) -
            (a[1].dictationErrors?.attempts ?? a[1].sampleCount),
        ),
      ),
    });
  }

  return sections;
}

export function review(
  data: LoadResult,
  options: { days: number; dataDir: string; dictationOnly: boolean; byTags: string[] },
): ReviewOutput {
  const metrics: Record<string, MetricResult> = {};

  for (const [metric, bucket] of Object.entries(data.values)) {
    if (!shouldIncludeMetric(metric, options.dictationOnly)) continue;
    metrics[metric] = buildMetricResult(metric, bucket.vals, bucket.unit);
  }

  const builds: ReviewOutput["builds"] = {};
  for (const [build, buildMetrics] of Object.entries(data.byBuild)) {
    builds[build] = { ...data.buildSummary[build], metrics: {} };
    for (const [metric, bucket] of Object.entries(buildMetrics)) {
      if (!shouldIncludeMetric(metric, options.dictationOnly)) continue;
      builds[build].metrics[metric] = { ...computeStats(bucket.vals), unit: bucket.unit };
    }
  }

  let violations = 0;
  const groups: Record<string, { pass: number; over: number; missing: number }> = {};
  for (const [metric, slo] of Object.entries(SLO_THRESHOLDS)) {
    if (!shouldIncludeMetric(metric, options.dictationOnly)) continue;
    if (!groups[slo.group]) groups[slo.group] = { pass: 0, over: 0, missing: 0 };
    const result = metrics[metric];
    if (!result || result.count === 0) groups[slo.group].missing += 1;
    else if (result.status === "over") {
      groups[slo.group].over += 1;
      violations += 1;
    } else groups[slo.group].pass += 1;
  }

  return {
    summary: {
      days: options.days,
      totalSamples: data.totalSamples,
      filesRead: data.filesRead,
      violations,
      sloMetricCount: Object.entries(SLO_THRESHOLDS).filter(([metric]) =>
        shouldIncludeMetric(metric, options.dictationOnly),
      ).length,
      groups,
      statusBasis: "tm99_vs_slo",
    },
    metrics,
    builds,
    breakdowns: buildBreakdowns(data, options.byTags, options.dictationOnly),
    dictationAssets: options.dictationOnly
      ? loadDictationAssetSummary(options.dataDir, options.days)
      : null,
    dictationConfig: options.dictationOnly ? loadDictationConfigSummary(options.dataDir) : null,
    fetchedAt: new Date().toISOString(),
  };
}

export interface TrendBucket {
  startTs: number;
  endTs: number;
  label: string;
  metrics: Record<string, MetricStats & { unit: string }>;
}

const DAY_MS = 24 * 60 * 60 * 1_000;

function defaultTrendBucketCount(days: number): number {
  return Math.min(24, Math.max(6, days * 4));
}

function formatTrendLabel(ts: number, spanMs: number): string {
  const date = new Date(ts);
  const month = date.getMonth() + 1;
  const day = date.getDate();
  if (spanMs >= DAY_MS) return `${month}/${day}`;
  const hour = String(date.getHours()).padStart(2, "0");
  return `${month}/${day} ${hour}:00`;
}

export function buildTrendBuckets(
  data: LoadResult,
  metricNames: string[],
  options: { days: number; bucketCount?: number; dictationOnly: boolean; endTs?: number },
): TrendBucket[] {
  const metricSet = new Set(
    metricNames.filter((metric) => shouldIncludeMetric(metric, options.dictationOnly)),
  );
  if (metricSet.size === 0) return [];

  const endTs = options.endTs ?? Date.now();
  const startTs = endTs - options.days * DAY_MS;
  const bucketCount = Math.max(1, options.bucketCount ?? defaultTrendBucketCount(options.days));
  const spanMs = Math.max(1, Math.ceil((endTs - startTs) / bucketCount));
  const buckets = Array.from({ length: bucketCount }, (_, index) => ({
    startTs: startTs + index * spanMs,
    endTs: index === bucketCount - 1 ? endTs : startTs + (index + 1) * spanMs,
    values: {} as Record<string, MetricBucket>,
  }));

  for (const sample of data.samples) {
    if (sample.ts < startTs || sample.ts > endTs) continue;
    if (!metricSet.has(sample.metric)) continue;
    const bucketIndex = Math.min(
      bucketCount - 1,
      Math.max(0, Math.floor((sample.ts - startTs) / spanMs)),
    );
    const bucket = buckets[bucketIndex];
    pushValue(bucket.values, sample.metric, sample.value, sample.unit);
  }

  return buckets.map((bucket) => ({
    startTs: bucket.startTs,
    endTs: bucket.endTs,
    label: formatTrendLabel(bucket.startTs, spanMs),
    metrics: Object.fromEntries(
      Object.entries(bucket.values).map(([metric, metricBucket]) => [
        metric,
        {
          ...computeStats(metricBucket.vals),
          unit: metricBucket.unit,
        },
      ]),
    ),
  }));
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function truncateLabel(value: string, maxChars: number): string {
  return value.length > maxChars ? `${value.slice(0, Math.max(1, maxChars - 1))}…` : value;
}

function seriesPath(
  values: Array<number | null>,
  x: number,
  y: number,
  width: number,
  height: number,
  maxValue: number,
): string {
  if (values.length === 0 || maxValue <= 0) return "";
  const step = values.length > 1 ? width / (values.length - 1) : 0;
  let path = "";
  let drawing = false;

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value == null || !Number.isFinite(value)) {
      drawing = false;
      continue;
    }
    const px = x + step * index;
    const py = y + height - (value / maxValue) * height;
    path += `${drawing ? "L" : "M"}${px.toFixed(1)},${py.toFixed(1)} `;
    drawing = true;
  }

  return path.trim();
}

function lastDefinedValue(values: Array<number | null>): number | null {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    const value = values[index];
    if (value != null && Number.isFinite(value)) return value;
  }
  return null;
}

function statusPalette(status: MetricResult["status"]): {
  fill: string;
  stroke: string;
  text: string;
  line: string;
} {
  if (status === "over") {
    return {
      fill: "#fff1f2",
      stroke: "#f43f5e",
      text: "#9f1239",
      line: "#e11d48",
    };
  }
  if (status === "pass") {
    return {
      fill: "#f0fdf4",
      stroke: "#22c55e",
      text: "#166534",
      line: "#2563eb",
    };
  }
  return {
    fill: "#f8fafc",
    stroke: "#94a3b8",
    text: "#334155",
    line: "#475569",
  };
}

export function buildTelemetryTrendSvg(
  result: ReviewOutput,
  trendBuckets: TrendBucket[],
  options: { dictationOnly: boolean; title?: string; subtitle?: string },
): string {
  const width = 1240;
  const margin = 36;
  const columnGap = 20;
  const rowGap = 16;
  const columns = 2;
  const cardHeight = 128;
  const innerWidth = width - margin * 2;
  const cardWidth = (innerWidth - columnGap * (columns - 1)) / columns;

  const groupNames: string[] = [];
  const metricsByGroup: Record<string, string[]> = {};
  for (const [metric, slo] of visibleSloEntries(options.dictationOnly)) {
    const metricResult = result.metrics[metric];
    if (!metricResult || metricResult.count === 0) continue;
    if (!metricsByGroup[slo.group]) {
      metricsByGroup[slo.group] = [];
      groupNames.push(slo.group);
    }
    metricsByGroup[slo.group].push(metric);
  }

  for (const groupName of groupNames) {
    metricsByGroup[groupName].sort((left, right) => {
      const leftResult = result.metrics[left];
      const rightResult = result.metrics[right];
      if (leftResult.status !== rightResult.status) {
        return leftResult.status === "over" ? -1 : 1;
      }
      return SLO_THRESHOLDS[left].label.localeCompare(SLO_THRESHOLDS[right].label);
    });
  }

  const chipSpecs = Object.entries(result.summary.groups).map(([groupName, counts]) => ({
    groupName,
    text: `${groupName} ${counts.pass}/${counts.over}/${counts.missing}`,
    over: counts.over > 0,
  }));

  const topBlockHeight = 110 + Math.max(0, Math.ceil(chipSpecs.length / 4) - 1) * 28;
  let totalHeight = margin + topBlockHeight;
  for (const groupName of groupNames) {
    const metricCount = metricsByGroup[groupName]?.length ?? 0;
    const rows = Math.ceil(metricCount / columns);
    totalHeight += 28 + rows * cardHeight + Math.max(0, rows - 1) * rowGap + 18;
  }
  totalHeight += margin;

  const pieces: string[] = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${totalHeight}" viewBox="0 0 ${width} ${totalHeight}" role="img" aria-label="${escapeXml(options.title ?? "Oppi telemetry trend review")}">`,
    `<style>
      .bg { fill: #ffffff; }
      .title { font: 700 28px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #0f172a; }
      .subtitle { font: 500 14px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #475569; }
      .section { font: 700 18px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #0f172a; }
      .section-meta { font: 500 12px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #64748b; }
      .chip { font: 600 12px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
      .metric-title { font: 700 15px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #0f172a; }
      .metric-meta { font: 500 12px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #475569; }
      .status { font: 700 12px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
      .axis { font: 500 11px -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; fill: #64748b; }
      .threshold { stroke: #f59e0b; stroke-width: 1.5; stroke-dasharray: 4 4; }
      .grid { stroke: #e2e8f0; stroke-width: 1; }
      .spark { fill: none; stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round; }
    </style>`,
    `<rect class="bg" x="0" y="0" width="${width}" height="${totalHeight}" rx="24" />`,
  ];

  const title = options.title ?? "Oppi Telemetry Trend Review";
  const subtitle =
    options.subtitle ??
    `Last ${result.summary.days}d · ${result.summary.totalSamples.toLocaleString()} samples · ${result.summary.violations} metric(s) over SLO · fetched ${result.fetchedAt}`;
  pieces.push(`<text class="title" x="${margin}" y="${margin + 8}">${escapeXml(title)}</text>`);
  pieces.push(
    `<text class="subtitle" x="${margin}" y="${margin + 34}">${escapeXml(subtitle)}</text>`,
  );
  pieces.push(
    `<text class="subtitle" x="${margin}" y="${margin + 56}">Status uses overall TM99 vs SLO. Each card sparkline shows bucketed TM99 so release regressions are visible without one-off spikes dominating.</text>`,
  );

  let chipX = margin;
  let chipY = margin + 78;
  for (const chip of chipSpecs) {
    const chipWidth = Math.max(150, 28 + chip.text.length * 7.1);
    if (chipX + chipWidth > width - margin) {
      chipX = margin;
      chipY += 28;
    }
    pieces.push(
      `<rect x="${chipX}" y="${chipY - 15}" width="${chipWidth}" height="24" rx="12" fill="${chip.over ? "#fff1f2" : "#f8fafc"}" stroke="${chip.over ? "#f43f5e" : "#cbd5e1"}" />`,
    );
    pieces.push(
      `<text class="chip" x="${chipX + 12}" y="${chipY + 1}" fill="${chip.over ? "#9f1239" : "#334155"}">${escapeXml(chip.text)}</text>`,
    );
    chipX += chipWidth + 10;
  }

  let y = margin + topBlockHeight;
  const startLabel = trendBuckets[0]?.label ?? "start";
  const endLabel = trendBuckets[trendBuckets.length - 1]?.label ?? "now";

  for (const groupName of groupNames) {
    const metrics = metricsByGroup[groupName] ?? [];
    if (metrics.length === 0) continue;
    const counts = result.summary.groups[groupName];
    pieces.push(`<text class="section" x="${margin}" y="${y}">${escapeXml(groupName)}</text>`);
    pieces.push(
      `<text class="section-meta" x="${margin + 170}" y="${y}">${escapeXml(`${counts.pass} pass · ${counts.over} over · ${counts.missing} missing`)}</text>`,
    );
    y += 16;

    for (let index = 0; index < metrics.length; index += 1) {
      const metric = metrics[index];
      const cardRow = Math.floor(index / columns);
      const cardCol = index % columns;
      const cardX = margin + cardCol * (cardWidth + columnGap);
      const cardY = y + 12 + cardRow * (cardHeight + rowGap);
      const metricResult = result.metrics[metric];
      const palette = statusPalette(metricResult.status);
      const slo = SLO_THRESHOLDS[metric];
      const titleText = truncateLabel(slo.label, 40);
      const chartX = cardX + 16;
      const chartY = cardY + 60;
      const chartWidth = cardWidth - 32;
      const chartHeight = 34;
      const series = trendBuckets.map((bucket) => bucket.metrics[metric]?.tm99 ?? null);
      const latestValue = lastDefinedValue(series);
      const maxSeriesValue = series.reduce((max, value) => {
        if (value == null || !Number.isFinite(value)) return max;
        return Math.max(max, value);
      }, 0);
      const chartMax = Math.max(1, maxSeriesValue, metricResult.tm99, metricResult.slo_p95 ?? 0);
      const thresholdY =
        metricResult.slo_p95 == null
          ? null
          : chartY + chartHeight - ((metricResult.slo_p95 ?? 0) / chartMax) * chartHeight;
      const sparkPathData = seriesPath(series, chartX, chartY, chartWidth, chartHeight, chartMax);

      pieces.push(
        `<rect x="${cardX}" y="${cardY}" width="${cardWidth}" height="${cardHeight}" rx="16" fill="${palette.fill}" stroke="${palette.stroke}" stroke-width="1.5" />`,
      );
      pieces.push(
        `<text class="metric-title" x="${cardX + 16}" y="${cardY + 22}">${escapeXml(titleText)}</text>`,
      );
      pieces.push(
        `<text class="metric-meta" x="${cardX + 16}" y="${cardY + 40}">overall tm99 ${escapeXml(fmtValue(metricResult.tm99, metricResult.unit))} / slo ${escapeXml(fmtValue(metricResult.slo_p95 ?? 0, metricResult.unit))}${slo.lowerIsBad ? " · low bad" : ""}</text>`,
      );
      pieces.push(
        `<text class="status" x="${cardX + cardWidth - 16}" y="${cardY + 22}" text-anchor="end" fill="${palette.text}">${metricResult.status === "over" ? "OVER" : "OK"}</text>`,
      );
      pieces.push(
        `<text class="metric-meta" x="${cardX + cardWidth - 16}" y="${cardY + 40}" text-anchor="end">${metricResult.count.toLocaleString()} samples</text>`,
      );
      pieces.push(
        `<line class="grid" x1="${chartX}" y1="${chartY + chartHeight}" x2="${chartX + chartWidth}" y2="${chartY + chartHeight}" />`,
      );
      if (thresholdY != null) {
        pieces.push(
          `<line class="threshold" x1="${chartX}" y1="${thresholdY.toFixed(1)}" x2="${chartX + chartWidth}" y2="${thresholdY.toFixed(1)}" />`,
        );
        pieces.push(
          `<text class="axis" x="${chartX + chartWidth}" y="${(thresholdY - 4).toFixed(1)}" text-anchor="end">SLO ${escapeXml(fmtValue(metricResult.slo_p95 ?? 0, metricResult.unit))}</text>`,
        );
      }
      if (sparkPathData) {
        pieces.push(`<path class="spark" d="${sparkPathData}" stroke="${palette.line}" />`);
      }
      if (latestValue != null) {
        const step = series.length > 1 ? chartWidth / (series.length - 1) : 0;
        const latestIndex = series.reduce(
          (found, value, index) => (value != null ? index : found),
          0,
        );
        const latestX = chartX + step * latestIndex;
        const latestY = chartY + chartHeight - (latestValue / chartMax) * chartHeight;
        pieces.push(
          `<circle cx="${latestX.toFixed(1)}" cy="${latestY.toFixed(1)}" r="4" fill="${palette.line}" stroke="#ffffff" stroke-width="1.5" />`,
        );
      }
      pieces.push(
        `<text class="axis" x="${chartX}" y="${cardY + 112}">${escapeXml(startLabel)}</text>`,
      );
      pieces.push(
        `<text class="axis" x="${chartX + chartWidth}" y="${cardY + 112}" text-anchor="end">${escapeXml(endLabel)}</text>`,
      );
      pieces.push(
        `<text class="axis" x="${cardX + cardWidth - 16}" y="${cardY + 58}" text-anchor="end">latest ${escapeXml(latestValue == null ? "—" : fmtValue(latestValue, metricResult.unit))}</text>`,
      );
    }

    const rows = Math.ceil(metrics.length / columns);
    y += 12 + rows * cardHeight + Math.max(0, rows - 1) * rowGap + 18;
  }

  pieces.push(`</svg>`);
  return pieces.join("\n");
}

function writeSvgReport(svgPath: string, svg: string): string {
  const resolvedPath = resolve(svgPath);
  mkdirSync(dirname(resolvedPath), { recursive: true });
  writeFileSync(resolvedPath, svg, "utf8");
  return resolvedPath;
}

export function fmtValue(n: number, unit: string = "ms"): string {
  if (unit === "ms") {
    if (n >= 10_000) return `${(n / 1_000).toFixed(1)}s`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(2)}s`;
    if (n >= 100) return `${Math.round(n)}ms`;
    if (n >= 10) return `${n.toFixed(1)}ms`;
    return `${n.toFixed(0)}ms`;
  }
  if (unit === "ratio") return n.toFixed(2);
  if (unit === "mb") {
    if (n >= 1_024) return `${(n / 1_024).toFixed(1)}GB`;
    return `${Math.round(n)}MB`;
  }
  if (unit === "pct") return `${n.toFixed(1)}%`;
  if (unit === "bytes") {
    if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(2)}GB`;
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}MB`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}KB`;
    return `${Math.round(n)}B`;
  }
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return Number.isInteger(n) ? `${n}` : n.toFixed(1);
}

function fmtStorage(n: number): string {
  return fmtValue(n, "bytes");
}

function visibleSloEntries(dictationOnly: boolean): Array<[string, SloThreshold]> {
  return Object.entries(SLO_THRESHOLDS).filter(([metric]) =>
    shouldIncludeMetric(metric, dictationOnly),
  );
}

function makeColors(enabled: boolean) {
  return {
    reset: enabled ? "\x1b[0m" : "",
    bold: enabled ? "\x1b[1m" : "",
    dim: enabled ? "\x1b[2m" : "",
    red: enabled ? "\x1b[31m" : "",
    green: enabled ? "\x1b[32m" : "",
    yellow: enabled ? "\x1b[33m" : "",
    cyan: enabled ? "\x1b[36m" : "",
  };
}

const GROUP_NOTES: Record<string, string> = {
  "Voice Compatibility":
    "chat.voice_* metrics are legacy aliases kept for older dashboards; Dictation UX is the canonical voice-input namespace.",
};

function printGroupNote(groupName: string, c: ReturnType<typeof makeColors>): void {
  const note = GROUP_NOTES[groupName];
  if (note) console.log(`  ${c.dim}${note}${c.reset}`);
}

function printConfigSummary(
  config: DictationConfigSummary,
  c: ReturnType<typeof makeColors>,
): void {
  console.log(`${c.bold}${c.cyan}Dictation Config${c.reset}`);
  console.log(`  provider             ${config.sttProvider}`);
  console.log(`  stt model            ${config.sttModel}`);
  console.log(`  stt endpoint         ${config.sttEndpoint}`);
  console.log(`  llm correction       ${config.llmCorrectionEnabled ? "on" : "off"}`);
  console.log(`  llm model            ${config.llmModel}`);
  console.log();
}

function printDictationAssets(
  summary: DictationAssetSummary,
  c: ReturnType<typeof makeColors>,
): void {
  console.log(`${c.bold}${c.cyan}Persisted Dictation Audio${c.reset}`);
  console.log(`  sessions             ${summary.sessions}`);
  console.log(`  audio duration       ${fmtValue(summary.totalDurationMs, "ms")}`);
  console.log(`  storage              ${fmtStorage(summary.totalStorageBytes)}`);
  console.log(
    `  formats              ${Object.entries(summary.formats)
      .map(([k, v]) => `${k}:${v}`)
      .join("  ")}`,
  );
  console.log(
    `  languages            ${
      Object.entries(summary.languages)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 6)
        .map(([k, v]) => `${k}:${v}`)
        .join("  ") || "none"
    }`,
  );
  console.log();

  console.log(`${c.bold}${c.cyan}Persisted Audio by Model${c.reset}`);
  console.log(
    `  ${"Model".padEnd(42)} ${"Sess".padStart(6)} ${"Audio".padStart(10)} ${"Storage".padStart(10)} ${"LLM".padStart(6)}`,
  );
  for (const [model, item] of Object.entries(summary.models).sort(
    (a, b) => b[1].sessions - a[1].sessions,
  )) {
    console.log(
      `  ${model.padEnd(42)} ${String(item.sessions).padStart(6)} ${fmtValue(item.totalDurationMs, "ms").padStart(10)} ${fmtStorage(item.totalStorageBytes).padStart(10)} ${String(item.llmCorrectedSessions).padStart(6)}`,
    );
  }
  console.log();
}

function fmtPercent(ratio: number | null): string {
  if (ratio == null || !Number.isFinite(ratio)) return "—";
  return `${(ratio * 100).toFixed(1)}%`;
}

function fmtDictationErrorSummary(summary?: DictationErrorSummary): string {
  if (!summary || summary.attempts === 0) return "—";
  return `${summary.errors}/${fmtPercent(summary.errorRate)}`;
}

function printBreakdowns(result: ReviewOutput, c: ReturnType<typeof makeColors>): void {
  for (const section of result.breakdowns) {
    console.log(`${c.bold}${c.cyan}Breakdown by ${section.tag}${c.reset}`);
    console.log(
      `  ${"Value".padEnd(32)} ${"Attempts".padStart(8)} ${"setup p95".padStart(10)} ${"first p95".padStart(10)} ${"final p95".padStart(10)} ${"delta p95".padStart(10)} ${"stt p95".padStart(10)} ${"errors".padStart(12)}`,
    );
    for (const [tagValue, entry] of Object.entries(section.values)) {
      const setup = entry.metrics["chat.dictation_setup_ms"];
      const first = entry.metrics["chat.dictation_first_result_ms"];
      const final = entry.metrics["chat.dictation_finalize_ms"];
      const delta = entry.metrics["chat.dictation_preview_final_delta"];
      const stt = entry.metrics["server.dictation_stt_ms"];
      const attempts =
        entry.dictationErrors?.attempts ??
        setup?.count ??
        stt?.count ??
        first?.count ??
        entry.sampleCount;
      const errorSummary = fmtDictationErrorSummary(entry.dictationErrors);
      console.log(
        `  ${tagValue.slice(0, 32).padEnd(32)} ${String(attempts).padStart(8)} ${setup ? fmtValue(setup.p95, setup.unit).padStart(10) : "—".padStart(10)} ${first ? fmtValue(first.p95, first.unit).padStart(10) : "—".padStart(10)} ${final ? fmtValue(final.p95, final.unit).padStart(10) : "—".padStart(10)} ${delta ? fmtValue(delta.p95, delta.unit).padStart(10) : "—".padStart(10)} ${stt ? fmtValue(stt.p95, stt.unit).padStart(10) : "—".padStart(10)} ${errorSummary.padStart(12)}`,
      );
    }
    console.log();
  }
}

function printNarrow(result: ReviewOutput, args: ParsedArgs): void {
  const c = makeColors(!args.noColor);
  const { summary } = result;
  const samplesStr =
    summary.totalSamples >= 1_000_000
      ? `${(summary.totalSamples / 1_000_000).toFixed(1)}M`
      : summary.totalSamples >= 1_000
        ? `${(summary.totalSamples / 1_000).toFixed(0)}K`
        : String(summary.totalSamples);
  const violStr =
    summary.violations > 0
      ? `${c.red}${summary.violations} over${c.reset}`
      : `${c.green}all ok${c.reset}`;
  const title = args.dictation ? "Dictation Telemetry" : "Telemetry";
  console.log(
    `${c.bold}${title}${c.reset} ${c.dim}${summary.days}d ${samplesStr} samples  status:${summary.statusBasis}${c.reset}  ${violStr}`,
  );
  console.log();

  if (args.dictation && result.dictationConfig) printConfigSummary(result.dictationConfig, c);

  const groups: Record<string, string[]> = {};
  for (const [metric, slo] of visibleSloEntries(args.dictation)) {
    if (!groups[slo.group]) groups[slo.group] = [];
    groups[slo.group].push(metric);
  }

  const NAME_W = 14;
  const VAL_W = 7;
  const SLO_W = 6;

  for (const [groupName, metrics] of Object.entries(groups)) {
    console.log(`${c.bold}${c.cyan}${groupName}${c.reset}`);
    printGroupNote(groupName, c);
    for (const metric of metrics) {
      const slo = SLO_THRESHOLDS[metric];
      const r = result.metrics[metric];
      const name = slo.short.slice(0, NAME_W);
      if (!r || r.count === 0) {
        console.log(`  ${name.padEnd(NAME_W)} ${c.dim}no data${c.reset}`);
        continue;
      }
      const over = r.status === "over";
      const statusStr = fmtValue(statusValue(r), r.unit).padStart(VAL_W);
      const sloStr = fmtValue(r.slo_p95 ?? 0, r.unit).padStart(SLO_W);
      console.log(
        `  ${name.padEnd(NAME_W)} ${over ? c.red : ""}${statusStr}${c.reset} /${sloStr}  ${over ? `${c.red}OVER${c.reset}` : `${c.green}ok${c.reset}`}`,
      );
    }
    console.log();
  }

  if (args.dictation && result.breakdowns.length > 0) printBreakdowns(result, c);
  if (args.dictation && result.dictationAssets) printDictationAssets(result.dictationAssets, c);
}

function printWide(result: ReviewOutput, args: ParsedArgs): void {
  const c = makeColors(!args.noColor);
  const fields =
    args.fields ?? new Set(["count", "tm99", "p50", "p95", "p99", "max", "slo", "status"]);
  const title = args.dictation ? "Oppi Dictation Telemetry Review" : "Oppi Telemetry Review";

  console.error();
  console.error(
    `${c.bold}${title}${c.reset}  ${c.dim}(last ${result.summary.days}d, ${result.summary.totalSamples.toLocaleString()} samples, ${result.summary.filesRead} files, status uses ${result.summary.statusBasis})${c.reset}`,
  );
  console.error();

  if (args.dictation && result.dictationConfig) printConfigSummary(result.dictationConfig, c);

  const groups: Record<string, string[]> = {};
  for (const [metric, slo] of visibleSloEntries(args.dictation)) {
    if (!groups[slo.group]) groups[slo.group] = [];
    groups[slo.group].push(metric);
  }

  for (const [groupName, metrics] of Object.entries(groups)) {
    console.log(`${c.bold}${c.cyan}${groupName}${c.reset}`);
    printGroupNote(groupName, c);
    const cols: string[] = [`  ${"Metric".padEnd(34)}`];
    if (fields.has("count")) cols.push("Count".padStart(8));
    if (fields.has("tm99")) cols.push("tm99".padStart(8));
    if (fields.has("p50")) cols.push("p50".padStart(8));
    if (fields.has("p95")) cols.push("p95".padStart(8));
    if (fields.has("p99")) cols.push("p99".padStart(8));
    if (fields.has("max")) cols.push("max".padStart(8));
    if (fields.has("slo")) cols.push("SLO".padStart(8));
    if (fields.has("status")) cols.push("Status");
    console.log(`${c.dim}${cols.join(" ")}${c.reset}`);

    for (const metric of metrics) {
      const r = result.metrics[metric];
      if (!r || r.count === 0) {
        console.log(`  ${metric.padEnd(34)} ${c.dim}no data${c.reset}`);
        continue;
      }
      const over = r.status === "over";
      const vals: string[] = [`  ${metric.padEnd(34)}`];
      if (fields.has("count")) vals.push(r.count.toLocaleString().padStart(8));
      if (fields.has("tm99")) vals.push(fmtValue(r.tm99, r.unit).padStart(8));
      if (fields.has("p50")) vals.push(fmtValue(r.p50, r.unit).padStart(8));
      if (fields.has("p95"))
        vals.push((over ? c.red : "") + fmtValue(r.p95, r.unit).padStart(8) + c.reset);
      if (fields.has("p99")) vals.push(fmtValue(r.p99, r.unit).padStart(8));
      if (fields.has("max")) vals.push(fmtValue(r.max, r.unit).padStart(8));
      if (fields.has("slo")) vals.push(fmtValue(r.slo_p95 ?? 0, r.unit).padStart(8));
      if (fields.has("status"))
        vals.push(over ? `${c.red}- OVER${c.reset}` : `${c.green}+ ok${c.reset}`);
      console.log(vals.join(" "));
    }
    console.log();
  }

  const informational = Object.entries(result.metrics)
    .filter(([, r]) => r.status === "no_slo")
    .sort(([, a], [, b]) => b.count - a.count);
  if (informational.length > 0) {
    console.log(`${c.bold}${c.cyan}Informational (no SLO)${c.reset}`);
    for (const [metric, r] of informational) {
      console.log(
        `  ${metric.padEnd(40)} ${String(r.count).padStart(8)} ${fmtValue(r.p50, r.unit).padStart(10)} ${fmtValue(r.p95, r.unit).padStart(10)} ${fmtValue(r.max, r.unit).padStart(10)}`,
      );
    }
    console.log();
  }

  if (args.dictation && result.breakdowns.length > 0) printBreakdowns(result, c);
  if (args.dictation && result.dictationAssets) printDictationAssets(result.dictationAssets, c);

  if (result.summary.violations > 0)
    console.error(`${c.yellow}${result.summary.violations} metric(s) over SLO threshold${c.reset}`);
  else console.error(`${c.green}All metrics within SLO thresholds${c.reset}`);
}

function printCompact(result: ReviewOutput, args: ParsedArgs): void {
  const fields = args.fields ?? new Set(["p95", "slo", "status"]);
  const metrics: Record<string, Record<string, number | string | null>> = {};
  for (const [metric, r] of Object.entries(result.metrics)) {
    if (r.status === "no_slo") continue;
    const entry: Record<string, number | string | null> = {};
    if (fields.has("count")) entry.n = r.count;
    if (fields.has("tm99")) entry.tm99 = r.tm99;
    if (fields.has("p50")) entry.p50 = r.p50;
    if (fields.has("p95")) entry.p95 = r.p95;
    if (fields.has("p99")) entry.p99 = r.p99;
    if (fields.has("max")) entry.max = r.max;
    if (fields.has("slo")) entry.slo = r.slo_p95;
    if (fields.has("status")) entry.s = r.status;
    metrics[metric] = entry;
  }
  console.log(
    JSON.stringify({
      s: result.summary,
      m: metrics,
      b: result.breakdowns,
      a: result.dictationAssets,
      c: result.dictationConfig,
    }),
  );
}

function printHuman(result: ReviewOutput, args: ParsedArgs): void {
  if (args.wide) printWide(result, args);
  else printNarrow(result, args);
}

function exitGate(result: ReviewOutput, gateMode: boolean): void {
  if (gateMode && result.summary.violations > 0) process.exit(1);
}

interface ParsedArgs {
  dataDir: string | undefined;
  days: number;
  json: boolean;
  compact: boolean;
  wide: boolean;
  gate: boolean;
  noColor: boolean;
  help: boolean;
  dictation: boolean;
  fields: Set<string> | null;
  byTags: string[];
  svgOut: string | undefined;
}

function parseArgs(argv: string[]): ParsedArgs {
  const result: ParsedArgs = {
    dataDir: undefined,
    days: 7,
    json: false,
    compact: false,
    wide: false,
    gate: false,
    noColor: false,
    help: false,
    dictation: false,
    fields: null,
    byTags: [],
    svgOut: undefined,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--data-dir":
        result.dataDir = argv[++i];
        break;
      case "--days":
        result.days = Math.max(1, parseInt(argv[++i] ?? "7", 10) || 7);
        break;
      case "--json":
        result.json = true;
        break;
      case "--compact":
        result.compact = true;
        break;
      case "--svg-out":
        result.svgOut = argv[++i];
        break;
      case "--wide":
        result.wide = true;
        break;
      case "--gate":
        result.gate = true;
        break;
      case "--no-color":
        result.noColor = true;
        break;
      case "--dictation":
        result.dictation = true;
        break;
      case "--by": {
        const raw = argv[++i] ?? "";
        result.byTags.push(
          ...raw
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean),
        );
        break;
      }
      case "--fields": {
        const raw = argv[++i] ?? "";
        result.fields = new Set(
          raw
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean),
        );
        break;
      }
      case "--help":
      case "-h":
        result.help = true;
        break;
    }
  }

  result.byTags = [...new Set(result.byTags)];
  if (result.dictation && result.byTags.length === 0) {
    result.byTags = ["engine", "source", "provider_id", "model"];
  }
  return result;
}

function printHelp(): void {
  console.error(`Oppi Telemetry Review

Phone-friendly by default. Use --wide for full tables.

  bun server/scripts/telemetry-review.ts
  bun server/scripts/telemetry-review.ts --wide
  bun server/scripts/telemetry-review.ts --days 1
  bun server/scripts/telemetry-review.ts --dictation --wide
  bun server/scripts/telemetry-review.ts --dictation --by engine,source,provider_id,model

Options:
  --data-dir <path>     Oppi data dir (default: ~/.config/oppi)
  --days <n>            Days of data (default: 7)
  --wide                Full table with all columns
  --dictation           Dictation-focused dashboard (UX + backend + assets)
                        Defaults to --by engine,source,provider_id,model
  --by <tags>           Breakdown tags (comma-separated). Example: engine,source,provider_id,model
  --json                Machine-readable JSON
  --compact             Minimal JSON for agents
  --svg-out <path>      Write an app-viewable SVG trend dashboard to a file
  --fields <list>       Columns: p50,p95,p99,max,count,slo,status,tm99
  --gate                Exit non-zero on SLO violations
  --no-color            Disable ANSI colors
  --help                Show this help
`);
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }

  const dataDir = resolve(
    args.dataDir ?? process.env.OPPI_DATA_DIR ?? join(homedir(), ".config", "oppi"),
  );
  const telemetryDir = join(dataDir, "diagnostics", "telemetry");
  const data = loadSamples(telemetryDir, args.days);

  if (data.totalSamples === 0) {
    const err = {
      error: "no_data",
      message: `No telemetry data found at ${telemetryDir}`,
      hint: "Check that the iOS app is sending metrics and the data dir is correct. Try: --data-dir ~/.config/oppi",
      exit_code: 1,
    };
    if (args.json || args.compact) console.log(JSON.stringify(err));
    else {
      console.error(err.message);
      console.error(`  hint: ${err.hint}`);
    }
    process.exit(1);
  }

  const result = review(data, {
    days: args.days,
    dataDir,
    dictationOnly: args.dictation,
    byTags: args.byTags,
  });

  let writtenSvgPath: string | null = null;
  if (args.svgOut) {
    const svgMetrics = visibleSloEntries(args.dictation)
      .map(([metric]) => metric)
      .filter((metric) => (result.metrics[metric]?.count ?? 0) > 0);
    const trendBuckets = buildTrendBuckets(data, svgMetrics, {
      days: args.days,
      dictationOnly: args.dictation,
    });
    const svg = buildTelemetryTrendSvg(result, trendBuckets, {
      dictationOnly: args.dictation,
      title: args.dictation
        ? "Oppi Dictation Telemetry Trend Review"
        : "Oppi Telemetry Trend Review",
    });
    writtenSvgPath = writeSvgReport(args.svgOut, svg);
  }

  if (args.compact) {
    printCompact(result, args);
    if (writtenSvgPath) console.error(`SVG report: ${writtenSvgPath}`);
    exitGate(result, args.gate);
    return;
  }
  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
    if (writtenSvgPath) console.error(`SVG report: ${writtenSvgPath}`);
    exitGate(result, args.gate);
    return;
  }

  printHuman(result, args);
  if (writtenSvgPath) {
    console.log();
    console.log(`SVG report: ${writtenSvgPath}`);
  }
  exitGate(result, args.gate);
}

if (import.meta.main) {
  main();
}
