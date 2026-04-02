#!/usr/bin/env bun

/**
 * Oppi telemetry review — reads JSONL chat metric files, computes percentiles,
 * and flags SLO reference threshold violations.
 *
 * Follows clanker-farm CLI design principles:
 * - Human tables by default, --json for structured data, --compact for agents
 * - Stdout is data, stderr is everything else
 * - JSON includes computed summaries
 * - Progressive disclosure: bare → overview, --help → full reference
 *
 * Usage:
 *   bun server/scripts/telemetry-review.ts [options]
 *
 * Options:
 *   --data-dir <path>     Oppi data dir (default: $OPPI_DATA_DIR or ~/.config/oppi)
 *   --days <n>            Days of data to include (default: 7)
 *   --json                Machine-readable JSON to stdout
 *   --compact             Minimal JSON (~40% smaller, for agent context windows)
 *   --fields <list>       Comma-separated fields: p50,p95,p99,max,count,slo,status
 *   --gate                Exit non-zero on SLO violations (for CI/release gates)
 *   --no-color            Disable ANSI colors
 *   --help                Show this help
 */

import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

// ─── Types ───

interface SloThreshold {
  p95: number;
  label: string;
  group: string;
  /** Short display name for narrow output (max 14 chars). */
  short: string;
}

interface MetricSample {
  ts: number;
  metric: string;
  value: number;
  unit?: string;
  tags?: Record<string, string>;
}

interface MetricBatch {
  buildNumber?: string;
  appVersion?: string;
  samples?: MetricSample[];
}

interface MetricBucket {
  vals: number[];
  unit: string;
}

interface MetricStats {
  count: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
}

interface BuildInfo {
  version: string;
  samples: number;
  firstSeen: number;
  lastSeen: number;
}

interface LoadResult {
  /** metric name → { vals, unit } */
  values: Record<string, MetricBucket>;
  /** build number → metric name → { vals, unit } */
  byBuild: Record<string, Record<string, MetricBucket>>;
  /** build number → summary info */
  buildSummary: Record<string, BuildInfo>;
  totalSamples: number;
  filesRead: number;
}

interface MetricResult {
  count: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
  unit: string;
  slo_p95: number | null;
  group: string;
  status: "pass" | "over" | "no_slo";
}

interface ReviewSummary {
  days: number;
  totalSamples: number;
  filesRead: number;
  violations: number;
  sloMetricCount: number;
  groups: Record<string, { pass: number; over: number; missing: number }>;
}

interface ReviewOutput {
  summary: ReviewSummary;
  metrics: Record<string, MetricResult>;
  builds: Record<string, BuildInfo & { metrics: Record<string, MetricStats & { unit: string }> }>;
  fetchedAt: string;
}

// ─── SLO Reference Thresholds ───
// Reference targets, not hard limits. Flag regressions early.
//
// Metrics in STATUS_FILTERED only count status=ok samples.
// Error samples measure "time spent failing", not user-perceived latency.

export const STATUS_FILTERED_METRICS = new Set([
  "chat.queue_sync_ms",
  "chat.subscribe_ack_ms",
  "chat.message_queue_ack_ms",
  "chat.connected_dispatch_ms",
]);

export const SLO_THRESHOLDS: Record<string, SloThreshold> = {
  // UX quality — how fast does the user see stuff?
  "chat.ttft_ms":              { p95: 45_000, label: "Time to first token",       group: "UX Quality", short: "ttft" },
  "chat.fresh_content_lag_ms": { p95: 4_000,  label: "Fresh content lag",         group: "UX Quality", short: "content_lag" },
  "chat.catchup_ms":           { p95: 1_500,  label: "Reconnection catch-up",     group: "UX Quality", short: "catchup" },
  "chat.full_reload_ms":       { p95: 3_000,  label: "Full reload",               group: "UX Quality", short: "full_reload" },
  "chat.cache_load_ms":        { p95: 300,    label: "Cache load",                group: "UX Quality", short: "cache_load" },
  "chat.reducer_load_ms":      { p95: 400,    label: "Timeline rebuild",          group: "UX Quality", short: "reducer" },
  "chat.session_load_ms":      { p95: 1_000,  label: "Session switch",            group: "UX Quality", short: "sess_load" },
  "chat.app_launch_ms":        { p95: 1_000,  label: "App cold start",            group: "UX Quality", short: "app_launch" },

  // Network health
  "chat.subscribe_ack_ms":     { p95: 1_500,  label: "Subscribe ack (ok only)",   group: "Network", short: "sub_ack" },
  "chat.ws_connect_ms":        { p95: 5_000,  label: "WS connect",               group: "Network", short: "ws_connect" },
  "chat.queue_sync_ms":        { p95: 1_500,  label: "Queue sync (ok only)",      group: "Network", short: "queue_sync" },
  "chat.connected_dispatch_ms":{ p95: 500,    label: "Connected dispatch (ok)",   group: "Network", short: "dispatch" },
  "chat.message_queue_ack_ms": { p95: 500,    label: "Message queue ack (ok)",    group: "Network", short: "msg_ack" },

  // Render health — frame budget targets
  "chat.timeline_apply_ms":    { p95: 33,     label: "Timeline apply (30fps)",    group: "Render", short: "tl_apply" },
  "chat.timeline_layout_ms":   { p95: 16,     label: "Timeline layout (60fps)",   group: "Render", short: "tl_layout" },
  "chat.cell_configure_ms":    { p95: 16,     label: "Cell configure",            group: "Render", short: "cell_config" },
  "chat.markdown_streaming_ms":{ p95: 16,     label: "Streaming markdown",        group: "Render", short: "md_stream" },
  "chat.jank_pct":             { p95: 30,     label: "Scroll jank %",             group: "Render", short: "jank_pct" },

  // Voice
  "chat.voice_setup_ms":       { p95: 400,    label: "Voice setup",               group: "Voice", short: "voice_setup" },
  "chat.voice_first_result_ms":{ p95: 10_000, label: "Voice first result",        group: "Voice", short: "voice_1st" },
  "chat.voice_prewarm_ms":     { p95: 800,    label: "Voice prewarm",             group: "Voice", short: "voice_prewarm" },

  // Session list
  "chat.session_list_compute_ms":    { p95: 60,   label: "List compute",             group: "Session List", short: "list_compute" },
  "chat.session_list_row_compute_ms":{ p95: 10,   label: "List row compute",         group: "Session List", short: "list_row" },
  "chat.session_list_body_rate":     { p95: 20,   label: "List body evals/5s",       group: "Session List", short: "list_body" },
};

// ─── Data Loading ───

export function loadSamples(telemetryDir: string, daysBack: number): LoadResult {
  const cutoffMs = Date.now() - daysBack * 24 * 60 * 60 * 1_000;
  const values: Record<string, MetricBucket> = {};
  const byBuild: Record<string, Record<string, MetricBucket>> = {};
  const buildSummary: Record<string, BuildInfo> = {};
  let totalSamples = 0;
  let filesRead = 0;

  let files: string[];
  try {
    files = readdirSync(telemetryDir)
      .filter((f) => f.startsWith("chat-metrics-") && f.endsWith(".jsonl"))
      .sort();
  } catch {
    return { values, byBuild, buildSummary, totalSamples: 0, filesRead: 0 };
  }

  for (const file of files) {
    const text = readFileSync(join(telemetryDir, file), "utf8");
    filesRead += 1;

    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let record: MetricBatch;
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

        const metric = sample.metric;
        const unit = sample.unit ?? "ms";

        // Status-filtered metrics: only count status=ok samples
        if (STATUS_FILTERED_METRICS.has(metric)) {
          const status = sample.tags?.status;
          if (status && status !== "ok") continue;
        }

        // Global
        if (!values[metric]) values[metric] = { vals: [], unit };
        values[metric].vals.push(sample.value);

        // Per-build
        if (!byBuild[build]) byBuild[build] = {};
        if (!byBuild[build][metric]) byBuild[build][metric] = { vals: [], unit };
        byBuild[build][metric].vals.push(sample.value);

        // Build summary
        if (!buildSummary[build]) {
          buildSummary[build] = { version, samples: 0, firstSeen: sample.ts, lastSeen: sample.ts };
        }
        buildSummary[build].samples += 1;
        if (sample.ts < buildSummary[build].firstSeen) buildSummary[build].firstSeen = sample.ts;
        if (sample.ts > buildSummary[build].lastSeen) buildSummary[build].lastSeen = sample.ts;

        totalSamples += 1;
      }
    }
  }

  return { values, byBuild, buildSummary, totalSamples, filesRead };
}

// ─── Statistics ───

export function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(Math.floor(sorted.length * p / 100), sorted.length - 1);
  return sorted[idx];
}

export function computeStats(vals: number[]): MetricStats {
  const sorted = [...vals].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
    max: sorted[sorted.length - 1] ?? 0,
  };
}

// ─── Review ───

export function review(data: LoadResult): ReviewOutput {
  const metrics: Record<string, MetricResult> = {};

  for (const [metric, { vals, unit }] of Object.entries(data.values)) {
    const stats = computeStats(vals);
    const slo = SLO_THRESHOLDS[metric];
    metrics[metric] = {
      ...stats,
      unit,
      slo_p95: slo?.p95 ?? null,
      group: slo?.group ?? "other",
      status: slo ? (stats.p95 <= slo.p95 ? "pass" : "over") : "no_slo",
    };
  }

  // Build breakdown
  const builds: ReviewOutput["builds"] = {};
  for (const [build, buildMetrics] of Object.entries(data.byBuild)) {
    const info = data.buildSummary[build];
    builds[build] = { ...info, metrics: {} };
    for (const [metric, { vals, unit }] of Object.entries(buildMetrics)) {
      builds[build].metrics[metric] = { ...computeStats(vals), unit };
    }
  }

  // Computed summary
  let violations = 0;
  const groups: Record<string, { pass: number; over: number; missing: number }> = {};

  for (const [metric, slo] of Object.entries(SLO_THRESHOLDS)) {
    const group = slo.group;
    if (!groups[group]) groups[group] = { pass: 0, over: 0, missing: 0 };

    const result = metrics[metric];
    if (!result || result.count === 0) {
      groups[group].missing += 1;
    } else if (result.status === "over") {
      groups[group].over += 1;
      violations += 1;
    } else {
      groups[group].pass += 1;
    }
  }

  return {
    summary: {
      days: 0, // set by caller
      totalSamples: data.totalSamples,
      filesRead: data.filesRead,
      violations,
      sloMetricCount: Object.keys(SLO_THRESHOLDS).length,
      groups,
    },
    metrics,
    builds,
    fetchedAt: new Date().toISOString(),
  };
}

// ─── Formatting ───

export function fmtValue(n: number, unit: string = "ms"): string {
  if (unit === "ms") {
    if (n >= 10_000) return `${(n / 1_000).toFixed(1)}s`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(2)}s`;
    if (n >= 100) return `${Math.round(n)}ms`;
    if (n >= 10) return `${n.toFixed(1)}ms`;
    return `${n.toFixed(0)}ms`;
  }
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  if (Number.isInteger(n)) return `${n}`;
  return `${n.toFixed(1)}`;
}

// ─── CLI ───
// Only runs when executed directly (not imported).

if (import.meta.main) {
  main();
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  const telemetryDir = join(
    resolve(args.dataDir ?? process.env.OPPI_DATA_DIR ?? join(homedir(), ".config", "oppi")),
    "diagnostics",
    "telemetry",
  );

  const data = loadSamples(telemetryDir, args.days);

  if (data.totalSamples === 0) {
    const err = {
      error: "no_data",
      message: `No telemetry data found at ${telemetryDir}`,
      hint: "Check that the iOS app is sending metrics and the data dir is correct. Try: --data-dir ~/.config/oppi",
      exit_code: 1,
    };
    if (args.json || args.compact) {
      console.log(JSON.stringify(err));
    } else {
      console.error(err.message);
      console.error(`  hint: ${err.hint}`);
    }
    process.exit(1);
  }

  const result = review(data);
  result.summary.days = args.days;

  if (args.compact) {
    printCompact(result, args.fields);
    exitGate(result, args.gate);
    return;
  }

  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
    exitGate(result, args.gate);
    return;
  }

  printHuman(result, args);
  exitGate(result, args.gate);
}

// ─── Compact Output ───
// Minimal JSON for agent context windows. Only SLO metrics, only requested fields.

function printCompact(result: ReviewOutput, fields: Set<string> | null): void {
  const out: Record<string, Record<string, number | string | null>> = {};

  for (const [metric, r] of Object.entries(result.metrics)) {
    if (r.status === "no_slo") continue; // skip informational in compact mode
    const entry: Record<string, number | string | null> = {};
    const f = fields ?? new Set(["p95", "slo", "status"]);
    if (f.has("count")) entry.n = r.count;
    if (f.has("p50")) entry.p50 = r.p50;
    if (f.has("p95")) entry.p95 = r.p95;
    if (f.has("p99")) entry.p99 = r.p99;
    if (f.has("max")) entry.max = r.max;
    if (f.has("slo")) entry.slo = r.slo_p95;
    if (f.has("status")) entry.s = r.status;
    out[metric] = entry;
  }

  console.log(JSON.stringify({ s: result.summary, m: out }));
}

// ─── Human Output ───
// All status/chrome to stderr, table data to stdout.


// ─── ANSI Colors ───
// Colors on by default (Oppi terminal supports ANSI). Use --no-color to disable.

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

// ─── Narrow Output (phone-friendly, default) ───
// Fits in ~45 chars. Format per metric:
//   {short_name:14} {p95:>7} /{slo:>6}  {status}

function printNarrow(result: ReviewOutput, args: ParsedArgs): void {
  const c = makeColors(!args.noColor);
  const { summary } = result;

  // Header
  const samplesStr =
    summary.totalSamples >= 1_000_000
      ? `${(summary.totalSamples / 1_000_000).toFixed(1)}M`
      : summary.totalSamples >= 1_000
        ? `${(summary.totalSamples / 1_000).toFixed(0)}K`
        : String(summary.totalSamples);
  const violStr =
    summary.violations > 0
      ? `  ${c.red}${summary.violations} over${c.reset}`
      : `  ${c.green}all ok${c.reset}`;
  console.log(`${c.bold}Telemetry${c.reset} ${c.dim}${summary.days}d ${samplesStr}${c.reset}${violStr}`);
  console.log();

  // Group SLO metrics
  const groups: Record<string, string[]> = {};
  for (const [metric, slo] of Object.entries(SLO_THRESHOLDS)) {
    if (!groups[slo.group]) groups[slo.group] = [];
    groups[slo.group].push(metric);
  }

  const NAME_W = 14;
  const VAL_W = 7;
  const SLO_W = 6;

  for (const [groupName, metrics] of Object.entries(groups)) {
    // Count pass/total for group header
    let pass = 0;
    let total = 0;
    for (const m of metrics) {
      const r = result.metrics[m];
      if (!r || r.count === 0) continue;
      total++;
      if (r.status === "pass") pass++;
    }
    const allPass = pass === total;
    const groupStatus = allPass
      ? `${c.green}${pass}/${total}${c.reset}`
      : `${c.yellow}${pass}/${total}${c.reset}`;
    console.log(`${c.bold}${c.cyan}${groupName}${c.reset} ${c.dim}${groupStatus}${c.reset}`);

    for (const metric of metrics) {
      const slo = SLO_THRESHOLDS[metric];
      const r = result.metrics[metric];
      const name = (slo?.short ?? metric.replace("chat.", "")).slice(0, NAME_W);

      if (!r || r.count === 0) {
        console.log(`  ${name.padEnd(NAME_W)} ${c.dim}no data${c.reset}`);
        continue;
      }

      const f = (n: number) => fmtValue(n, r.unit);
      const over = r.status === "over";
      const p95Str = f(r.p95).padStart(VAL_W);
      const sloStr = f(r.slo_p95!).padStart(SLO_W);
      const status = over ? `${c.red}OVER${c.reset}` : `${c.green}  ok${c.reset}`;
      const p95Part = over ? `${c.red}${p95Str}${c.reset}` : p95Str;

      console.log(`  ${name.padEnd(NAME_W)} ${p95Part} /${sloStr}  ${status}`);
    }
    console.log();
  }
}

// ─── Wide Output (terminal, --wide) ───
// Original table format with all columns.

function printWide(result: ReviewOutput, args: ParsedArgs): void {
  const c = makeColors(!args.noColor);
  const { summary } = result;
  const fields = args.fields ?? new Set(["count", "p50", "p95", "p99", "max", "slo", "status"]);

  console.error();
  console.error(
    `${c.bold}Oppi Telemetry Review${c.reset}  ${c.dim}(last ${summary.days}d, ${summary.totalSamples.toLocaleString()} samples, ${summary.filesRead} files)${c.reset}`,
  );
  console.error();

  const groups: Record<string, string[]> = {};
  for (const [metric, slo] of Object.entries(SLO_THRESHOLDS)) {
    if (!groups[slo.group]) groups[slo.group] = [];
    groups[slo.group].push(metric);
  }

  for (const [groupName, metrics] of Object.entries(groups)) {
    console.log(`${c.bold}${c.cyan}${groupName}${c.reset}`);

    const cols: string[] = [`  ${"Metric".padEnd(34)}`];
    if (fields.has("count")) cols.push("Count".padStart(8));
    if (fields.has("p50")) cols.push("p50".padStart(8));
    if (fields.has("p95")) cols.push("p95".padStart(8));
    if (fields.has("p99")) cols.push("p99".padStart(8));
    if (fields.has("max")) cols.push("max".padStart(8));
    if (fields.has("slo")) cols.push("SLO p95".padStart(8));
    if (fields.has("status")) cols.push("Status");
    console.log(`${c.dim}${cols.join(" ")}${c.reset}`);

    for (const metric of metrics) {
      const r = result.metrics[metric];
      if (!r || r.count === 0) {
        console.log(`  ${metric.padEnd(34)} ${c.dim}no data${c.reset}`);
        continue;
      }

      const f = (n: number) => fmtValue(n, r.unit);
      const over = r.status === "over";
      const statusIcon = over ? `${c.red}- OVER${c.reset}` : `${c.green}+ ok${c.reset}`;
      const vals: string[] = [`  ${metric.padEnd(34)}`];
      if (fields.has("count")) vals.push(r.count.toLocaleString().padStart(8));
      if (fields.has("p50")) vals.push(f(r.p50).padStart(8));
      if (fields.has("p95")) {
        const p95s = f(r.p95).padStart(8);
        vals.push(over ? `${c.red}${p95s}${c.reset}` : `${p95s}`);
      }
      if (fields.has("p99")) vals.push(f(r.p99).padStart(8));
      if (fields.has("max")) vals.push(f(r.max).padStart(8));
      if (fields.has("slo")) vals.push(f(r.slo_p95!).padStart(8));
      if (fields.has("status")) vals.push(statusIcon);
      console.log(vals.join(" "));
    }
    console.log();
  }

  // Informational metrics (no SLO)
  const informational = Object.entries(result.metrics)
    .filter(([, r]) => r.status === "no_slo")
    .sort(([, a], [, b]) => b.count - a.count);

  if (informational.length > 0) {
    console.log(`${c.bold}${c.cyan}Informational (no SLO)${c.reset}`);
    const cols: string[] = [`  ${"Metric".padEnd(40)}`];
    if (fields.has("count")) cols.push("Count".padStart(8));
    if (fields.has("p50")) cols.push("p50".padStart(10));
    if (fields.has("p95")) cols.push("p95".padStart(10));
    if (fields.has("max")) cols.push("max".padStart(10));
    console.log(`${c.dim}${cols.join(" ")}${c.reset}`);

    for (const [metric, r] of informational) {
      const f = (n: number) => fmtValue(n, r.unit);
      const vals: string[] = [`  ${metric.padEnd(40)}`];
      if (fields.has("count")) vals.push(r.count.toLocaleString().padStart(8));
      if (fields.has("p50")) vals.push(f(r.p50).padStart(10));
      if (fields.has("p95")) vals.push(f(r.p95).padStart(10));
      if (fields.has("max")) vals.push(f(r.max).padStart(10));
      console.log(vals.join(" "));
    }
    console.log();
  }

  // Build comparison
  const buildKeys = Object.keys(result.builds).sort((a, b) => {
    return (result.builds[a].firstSeen ?? 0) - (result.builds[b].firstSeen ?? 0);
  });

  if (buildKeys.length > 1) {
    console.log(`${c.bold}${c.cyan}Build Comparison (SLO metrics, p95)${c.reset}`);

    const compareMetrics = [
      "chat.ttft_ms",
      "chat.fresh_content_lag_ms",
      "chat.full_reload_ms",
      "chat.subscribe_ack_ms",
      "chat.cell_configure_ms",
      "chat.timeline_apply_ms",
    ];

    const buildLabels = buildKeys.map((b) => `b${b}`);
    console.log(
      `${c.dim}  ${"Metric".padEnd(30)} ${buildLabels.map((l) => l.padStart(10)).join(" ")}${c.reset}`,
    );

    for (const metric of compareMetrics) {
      const entry = result.metrics[metric];
      if (!entry) continue;

      const cells = buildKeys.map((build) => {
        const bm = result.builds[build]?.metrics?.[metric];
        if (!bm || bm.count === 0) return "\u2014".padStart(10);
        return fmtValue(bm.p95, bm.unit).padStart(10);
      });

      console.log(`  ${metric.padEnd(30)} ${cells.join(" ")}`);
    }
    console.log();

    console.error(`${c.dim}  Builds:${c.reset}`);
    for (const build of buildKeys) {
      const info = result.builds[build];
      const first = new Date(info.firstSeen).toLocaleDateString();
      const last = new Date(info.lastSeen).toLocaleDateString();
      const range = first === last ? first : `${first} - ${last}`;
      console.error(
        `${c.dim}    b${build} = v${info.version} (${info.samples.toLocaleString()} samples, ${range})${c.reset}`,
      );
    }
    console.error();
  }

  if (summary.violations > 0) {
    console.error(`${c.yellow}${summary.violations} metric(s) over SLO threshold${c.reset}`);
  } else {
    console.error(`${c.green}All metrics within SLO thresholds${c.reset}`);
  }
}

// ─── Human Output ───

function printHuman(result: ReviewOutput, args: ParsedArgs): void {
  if (args.wide) {
    printWide(result, args);
  } else {
    printNarrow(result, args);
  }
}

// ─── Gate ───

function exitGate(result: ReviewOutput, gateMode: boolean): void {
  if (gateMode && result.summary.violations > 0) {
    process.exit(1);
  }
}

// ─── Arg Parsing ───

interface ParsedArgs {
  dataDir: string | undefined;
  days: number;
  json: boolean;
  compact: boolean;
  wide: boolean;
  gate: boolean;
  noColor: boolean;
  help: boolean;
  fields: Set<string> | null;
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
    fields: null,
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
      case "--wide":
        result.wide = true;
        break;
      case "--gate":
        result.gate = true;
        break;
      case "--no-color":
        result.noColor = true;
        break;
      case "--fields": {
        const raw = argv[++i] ?? "";
        result.fields = new Set(raw.split(",").map((s) => s.trim()).filter(Boolean));
        break;
      }
      case "--help":
      case "-h":
        result.help = true;
        break;
    }
  }

  return result;
}

// ─── Help ───

function printHelp(): void {
  console.error(`Oppi Telemetry Review

Phone-friendly by default. Use --wide for full terminal tables.

  bun server/scripts/telemetry-review.ts              # narrow (phone)
  bun server/scripts/telemetry-review.ts --wide       # full table
  bun server/scripts/telemetry-review.ts --days 1     # just today
  bun server/scripts/telemetry-review.ts --gate       # CI, exits 1 on violations

Agent-friendly:
  bun server/scripts/telemetry-review.ts --compact    # minimal JSON
  bun server/scripts/telemetry-review.ts --json       # full JSON

Options:
  --data-dir <path>     Oppi data dir (default: ~/.config/oppi)
  --days <n>            Days of data (default: 7)
  --wide                Full table with all columns
  --json                Machine-readable JSON
  --compact             Minimal JSON for agents
  --fields <list>       Columns: p50,p95,p99,max,count,slo,status
  --gate                Exit non-zero on SLO violations
  --no-color            Disable ANSI colors
  --help                Show this help

Exit codes:
  0  Success (or all SLOs pass in gate mode)
  1  SLO violation (gate mode) or no data found
`);
}
