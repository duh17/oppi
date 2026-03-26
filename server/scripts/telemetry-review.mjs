#!/usr/bin/env node

/**
 * Oppi telemetry review — reads JSONL chat metric files, computes percentiles,
 * and flags SLO reference threshold violations.
 *
 * Usage:
 *   node server/scripts/telemetry-review.mjs [options]
 *
 * Options:
 *   --data-dir <path>     Oppi data dir (default: $OPPI_DATA_DIR or ~/.config/oppi)
 *   --days <n>            Days of data to include (default: 7)
 *   --json                Output machine-readable JSON
 *   --no-color            Disable ANSI colors
 *   --help                Show this help
 */

import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

// ─── SLO Reference Thresholds ───
// These are reference targets, not hard limits. They help spot regressions.

const SLO_THRESHOLDS = {
  // UX quality — how fast does the user see stuff?
  "chat.ttft_ms":              { p95: 10_000, label: "Time to first token",       group: "UX Quality" },
  "chat.fresh_content_lag_ms": { p95: 3_000,  label: "Fresh content lag",         group: "UX Quality" },
  "chat.catchup_ms":           { p95: 1_500,  label: "Reconnection catch-up",     group: "UX Quality" },
  "chat.full_reload_ms":       { p95: 2_000,  label: "Full reload",               group: "UX Quality" },
  "chat.cache_load_ms":        { p95: 150,    label: "Cache load",                group: "UX Quality" },
  "chat.reducer_load_ms":      { p95: 200,    label: "Timeline rebuild",          group: "UX Quality" },

  // Network health — is connectivity reliable?
  "chat.stream_open_ms":       { p95: 500,    label: "Stream open",               group: "Network" },
  "chat.subscribe_ack_ms":     { p95: 1_500,  label: "Subscribe ack",             group: "Network" },
  "chat.ws_connect_ms":        { p95: 5_000,  label: "WS connect (legacy)",       group: "Network" },
  "chat.queue_sync_ms":        { p95: 1_500,  label: "Queue sync",                group: "Network" },
  "chat.connected_dispatch_ms":{ p95: 200,    label: "Connected dispatch",        group: "Network" },
  "chat.message_queue_ack_ms": { p95: 500,    label: "Message queue ack",         group: "Network" },

  // Render health
  "chat.timeline_apply_ms":    { p95: 16,     label: "Timeline apply (>4ms only)",group: "Render" },
  "chat.timeline_layout_ms":   { p95: 8,      label: "Timeline layout (>2ms only)",group: "Render" },
  "chat.cell_configure_ms":    { p95: 10,     label: "Cell configure",            group: "Render" },

  // Voice
  "chat.voice_setup_ms":       { p95: 400,    label: "Voice setup",               group: "Voice" },
  "chat.voice_first_result_ms":{ p95: 8_000,  label: "Voice first result",        group: "Voice" },
  "chat.voice_prewarm_ms":     { p95: 200,    label: "Voice prewarm",             group: "Voice" },

  // Session list
  "chat.session_list_compute_ms":    { p95: 4,    label: "List viewData compute",    group: "Session List" },
  "chat.session_list_row_compute_ms":{ p95: 2,    label: "List row compute",         group: "Session List" },
  "chat.session_list_body_rate":     { p95: 20,   label: "List body evals per 5s",   group: "Session List" },
};

// ─── CLI ───

function getArg(name) {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx < 0 || idx + 1 >= process.argv.length) return undefined;
  return process.argv[idx + 1];
}

function hasFlag(name) {
  return process.argv.includes(`--${name}`);
}

if (hasFlag("help") || hasFlag("h")) {
  console.log(`
Usage: node server/scripts/telemetry-review.mjs [options]

Options:
  --data-dir <path>     Oppi data dir (default: $OPPI_DATA_DIR or ~/.config/oppi)
  --days <n>            Days of data to include (default: 7)
  --gate                Exit non-zero if any SLO violations (for CI/release gates)
  --json                Machine-readable JSON output
  --no-color            Disable ANSI colors
  --help                Show this help
`);
  process.exit(0);
}

const dataDir = resolve(
  getArg("data-dir") ?? process.env.OPPI_DATA_DIR ?? join(homedir(), ".config", "oppi"),
);
const telemetryDir = join(dataDir, "diagnostics", "telemetry");
const daysBack = Math.max(1, Number.parseInt(getArg("days") ?? "7", 10) || 7);
const jsonOutput = hasFlag("json");
const gateMode = hasFlag("gate");
const useColor = !hasFlag("no-color") && process.stdout.isTTY;

// ─── Colors ───

const c = {
  reset: useColor ? "\x1b[0m" : "",
  bold: useColor ? "\x1b[1m" : "",
  dim: useColor ? "\x1b[2m" : "",
  red: useColor ? "\x1b[31m" : "",
  green: useColor ? "\x1b[32m" : "",
  yellow: useColor ? "\x1b[33m" : "",
  cyan: useColor ? "\x1b[36m" : "",
};

// ─── Data Loading ───

function loadSamples() {
  const cutoffMs = Date.now() - daysBack * 24 * 60 * 60 * 1_000;
  const values = {};       // metric → { vals, unit }
  const byBuild = {};      // build → metric → { vals, unit }
  const buildSummary = {}; // build → { version, samples, firstSeen, lastSeen }
  let totalSamples = 0;
  let filesRead = 0;

  let files;
  try {
    files = readdirSync(telemetryDir)
      .filter((f) => f.startsWith("chat-metrics-") && f.endsWith(".jsonl"))
      .sort();
  } catch {
    console.error(`No telemetry data at ${telemetryDir}`);
    process.exit(1);
  }

  for (const file of files) {
    const text = readFileSync(join(telemetryDir, file), "utf8");
    filesRead += 1;

    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }

      const build = record.buildNumber || "unknown";
      const version = record.appVersion || "?";

      for (const sample of record.samples ?? []) {
        if (typeof sample.ts !== "number" || sample.ts < cutoffMs) continue;
        if (typeof sample.value !== "number" || !Number.isFinite(sample.value)) continue;

        const metric = sample.metric;
        const unit = sample.unit ?? "ms";

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

// ─── Stats ───

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(Math.floor(sorted.length * p / 100), sorted.length - 1);
  return sorted[idx];
}

function computeStats(vals) {
  const sorted = [...vals].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
    max: sorted[sorted.length - 1],
  };
}

// ─── Main ───

const { values, byBuild, buildSummary, totalSamples, filesRead } = loadSamples();

if (jsonOutput) {
  const results = {};
  for (const [metric, { vals, unit }] of Object.entries(values)) {
    const stats = computeStats(vals);
    const slo = SLO_THRESHOLDS[metric];
    results[metric] = {
      ...stats,
      unit,
      slo_p95: slo?.p95 ?? null,
      group: slo?.group ?? "other",
      status: slo ? (stats.p95 <= slo.p95 ? "pass" : "over") : "no_slo",
    };
  }
  const builds = {};
  for (const [build, metrics] of Object.entries(byBuild)) {
    builds[build] = { ...buildSummary[build] };
    builds[build].metrics = {};
    for (const [metric, { vals, unit }] of Object.entries(metrics)) {
      builds[build].metrics[metric] = { ...computeStats(vals), unit };
    }
  }
  console.log(JSON.stringify({ days: daysBack, totalSamples, filesRead, metrics: results, builds }, null, 2));
  process.exit(0);
}

// ─── Human Output ───

console.log();
console.log(`${c.bold}Oppi Telemetry Review${c.reset}  ${c.dim}(last ${daysBack} days, ${totalSamples.toLocaleString()} samples from ${filesRead} files)${c.reset}`);
console.log();

// Group by SLO group
const groups = {};
for (const [metric, slo] of Object.entries(SLO_THRESHOLDS)) {
  const group = slo.group;
  if (!groups[group]) groups[group] = [];
  groups[group].push(metric);
}

let violations = 0;

for (const [groupName, metrics] of Object.entries(groups)) {
  console.log(`${c.bold}${c.cyan}${groupName}${c.reset}`);

  const header = `  ${"Metric".padEnd(30)} ${"Count".padStart(8)} ${"p50".padStart(8)} ${"p95".padStart(8)} ${"p99".padStart(8)} ${"max".padStart(8)} ${"SLO p95".padStart(8)} Status`;
  console.log(`${c.dim}${header}${c.reset}`);

  for (const metric of metrics) {
    const entry = values[metric];
    if (!entry || entry.vals.length === 0) {
      console.log(`  ${metric.padEnd(30)} ${c.dim}no data${c.reset}`);
      continue;
    }

    const stats = computeStats(entry.vals);
    const slo = SLO_THRESHOLDS[metric];
    const f = (n) => fmt(n, entry.unit);
    const over = stats.p95 > slo.p95;
    if (over) violations += 1;

    const statusIcon = over ? `${c.red}OVER${c.reset}` : `${c.green}ok${c.reset}`;
    const p95Color = over ? c.red : "";

    console.log(
      `  ${metric.padEnd(30)} ${stats.count.toLocaleString().padStart(8)} ${f(stats.p50).padStart(8)} ${p95Color}${f(stats.p95).padStart(8)}${c.reset} ${f(stats.p99).padStart(8)} ${f(stats.max).padStart(8)} ${f(slo.p95).padStart(8)} ${statusIcon}`,
    );
  }
  console.log();
}

// Show informational metrics (no SLO)
const informational = Object.entries(values)
  .filter(([metric]) => !SLO_THRESHOLDS[metric])
  .sort(([, a], [, b]) => b.vals.length - a.vals.length);

if (informational.length > 0) {
  console.log(`${c.bold}${c.cyan}Informational (no SLO)${c.reset}`);
  const header = `  ${"Metric".padEnd(40)} ${"Count".padStart(8)} ${"p50".padStart(10)} ${"p95".padStart(10)} ${"max".padStart(10)}`;
  console.log(`${c.dim}${header}${c.reset}`);

  for (const [metric, entry] of informational) {
    const stats = computeStats(entry.vals);
    const f = (n) => fmt(n, entry.unit);
    console.log(
      `  ${metric.padEnd(40)} ${stats.count.toLocaleString().padStart(8)} ${f(stats.p50).padStart(10)} ${f(stats.p95).padStart(10)} ${f(stats.max).padStart(10)}`,
    );
  }
  console.log();
}

// Build breakdown — compare SLO metrics across builds
const buildKeys = Object.keys(buildSummary).sort((a, b) => {
  return (buildSummary[a].firstSeen ?? 0) - (buildSummary[b].firstSeen ?? 0);
});

if (buildKeys.length > 1) {
  console.log(`${c.bold}${c.cyan}Build Comparison (SLO metrics, p95)${c.reset}`);

  // Pick key SLO metrics for comparison (one per group, most important)
  const compareMetrics = [
    "chat.ttft_ms",
    "chat.fresh_content_lag_ms",
    "chat.full_reload_ms",
    "chat.subscribe_ack_ms",
    "chat.cell_configure_ms",
    "chat.timeline_apply_ms",
  ];

  // Header
  const buildLabels = buildKeys.map((b) => `b${b}`);
  const header = `  ${"Metric".padEnd(30)} ${buildLabels.map((l) => l.padStart(10)).join(" ")}`;
  console.log(`${c.dim}${header}${c.reset}`);

  for (const metric of compareMetrics) {
    const entry = values[metric];
    if (!entry) continue;
    const unit = entry.unit;
    const f = (n) => fmt(n, unit);

    const cells = buildKeys.map((build) => {
      const bm = byBuild[build]?.[metric];
      if (!bm || bm.vals.length === 0) return "—".padStart(10);
      const stats = computeStats(bm.vals);
      return f(stats.p95).padStart(10);
    });

    console.log(`  ${metric.padEnd(30)} ${cells.join(" ")}`);
  }
  console.log();

  // Build legend
  console.log(`${c.dim}  Builds:${c.reset}`);
  for (const build of buildKeys) {
    const info = buildSummary[build];
    const first = new Date(info.firstSeen).toLocaleDateString();
    const last = new Date(info.lastSeen).toLocaleDateString();
    const range = first === last ? first : `${first} – ${last}`;
    console.log(`${c.dim}    b${build} = v${info.version} (${info.samples.toLocaleString()} samples, ${range})${c.reset}`);
  }
  console.log();
}

// Summary
if (violations > 0) {
  console.log(`${c.yellow}${violations} metric(s) over SLO reference threshold${c.reset}`);
  if (gateMode) process.exit(1);
} else {
  console.log(`${c.green}All metrics within SLO reference thresholds${c.reset}`);
}

function fmt(n, unit = "ms") {
  if (unit === "ms") {
    if (n >= 10_000) return `${(n / 1_000).toFixed(1)}s`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(2)}s`;
    if (n >= 100) return `${Math.round(n)}ms`;
    if (n >= 10) return `${n.toFixed(1)}ms`;
    return `${n.toFixed(0)}ms`;
  }
  // count, ratio, etc.
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  if (Number.isInteger(n)) return `${n}`;
  return `${n.toFixed(1)}`;
}
