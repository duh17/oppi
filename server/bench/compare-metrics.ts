/**
 * Compare benchmark METRIC outputs against a baseline.
 *
 * Usage:
 *   tsx bench/compare-metrics.ts \
 *     --baseline bench/baselines/server-hotpath.metrics \
 *     --current /tmp/server-hotpath.metrics \
 *     --metric-set avg \
 *     --max-regression-pct 15
 */

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export type MetricSet = "avg" | "all";

export interface CompareOptions {
  metricSet: MetricSet;
  maxRegressionPct: number;
  minBaselineUs: number;
  maxAbsoluteRegressionUs: number;
}

interface CliArgs extends CompareOptions {
  baselinePath: string;
  currentPath: string;
}

export interface Regression {
  metric: string;
  baseline: number;
  current: number;
  kind: "pct" | "abs";
  deltaPct?: number;
  deltaUs?: number;
}

export interface CompareResult {
  comparedMetrics: number;
  missingMetrics: string[];
  regressions: Regression[];
}

function usage(): never {
  console.error(
    "Usage: tsx bench/compare-metrics.ts --baseline <file> --current <file> [--metric-set avg|all] [--max-regression-pct <number>] [--min-baseline-us <number>] [--max-absolute-regression-us <number>]",
  );
  process.exit(2);
}

function parseArgs(argv: string[]): CliArgs {
  let baselinePath = "";
  let currentPath = "";
  let metricSet: MetricSet = "avg";
  let maxRegressionPct = 15;
  let minBaselineUs = 0.2;
  let maxAbsoluteRegressionUs = 0.05;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === "--baseline") {
      baselinePath = argv[++i] ?? "";
      continue;
    }

    if (arg === "--current") {
      currentPath = argv[++i] ?? "";
      continue;
    }

    if (arg === "--metric-set") {
      const raw = (argv[++i] ?? "").trim();
      if (raw !== "avg" && raw !== "all") {
        usage();
      }
      metricSet = raw;
      continue;
    }

    if (arg === "--max-regression-pct") {
      const parsed = Number(argv[++i] ?? "");
      if (!Number.isFinite(parsed) || parsed < 0) {
        usage();
      }
      maxRegressionPct = parsed;
      continue;
    }

    if (arg === "--min-baseline-us") {
      const parsed = Number(argv[++i] ?? "");
      if (!Number.isFinite(parsed) || parsed < 0) {
        usage();
      }
      minBaselineUs = parsed;
      continue;
    }

    if (arg === "--max-absolute-regression-us") {
      const parsed = Number(argv[++i] ?? "");
      if (!Number.isFinite(parsed) || parsed < 0) {
        usage();
      }
      maxAbsoluteRegressionUs = parsed;
      continue;
    }

    usage();
  }

  if (!baselinePath || !currentPath) {
    usage();
  }

  return {
    baselinePath,
    currentPath,
    metricSet,
    maxRegressionPct,
    minBaselineUs,
    maxAbsoluteRegressionUs,
  };
}

function shouldCompareMetric(metric: string, metricSet: MetricSet): boolean {
  if (metricSet === "all") {
    return true;
  }

  if (metric === "total_avg_us") {
    return true;
  }

  if (metric.endsWith("_avg_us")) {
    return true;
  }

  // Category totals like translate_us / sanitize_us.
  if (metric.endsWith("_us") && !metric.includes("_avg_") && !metric.includes("_p99_")) {
    return true;
  }

  return false;
}

export function parseMetricsText(text: string): Map<string, number> {
  const metrics = new Map<string, number>();

  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith("METRIC ")) {
      continue;
    }

    const body = line.slice("METRIC ".length).trim();
    const eq = body.indexOf("=");
    if (eq <= 0) {
      continue;
    }

    const name = body.slice(0, eq).trim();
    const value = Number(body.slice(eq + 1).trim());
    if (!name || !Number.isFinite(value)) {
      continue;
    }

    metrics.set(name, value);
  }

  return metrics;
}

export function parseMetricsFile(path: string): Map<string, number> {
  return parseMetricsText(readFileSync(path, "utf8"));
}

function pctDelta(baseline: number, current: number): number {
  if (baseline === 0) {
    return current === 0 ? 0 : Number.POSITIVE_INFINITY;
  }
  return ((current - baseline) / baseline) * 100;
}

export function compareMetricMaps(
  baseline: Map<string, number>,
  current: Map<string, number>,
  opts: CompareOptions,
): CompareResult {
  const missingMetrics: string[] = [];
  const regressions: Regression[] = [];
  let comparedMetrics = 0;

  for (const [metric, baselineValue] of baseline) {
    if (!shouldCompareMetric(metric, opts.metricSet)) {
      continue;
    }

    const currentValue = current.get(metric);
    if (currentValue === undefined) {
      missingMetrics.push(metric);
      continue;
    }

    comparedMetrics++;

    const deltaUs = currentValue - baselineValue;
    if (baselineValue <= opts.minBaselineUs) {
      if (deltaUs > opts.maxAbsoluteRegressionUs) {
        regressions.push({
          metric,
          baseline: baselineValue,
          current: currentValue,
          kind: "abs",
          deltaUs,
        });
      }
      continue;
    }

    const deltaPct = pctDelta(baselineValue, currentValue);
    if (deltaPct > opts.maxRegressionPct) {
      regressions.push({
        metric,
        baseline: baselineValue,
        current: currentValue,
        kind: "pct",
        deltaPct,
      });
    }
  }

  return {
    comparedMetrics,
    missingMetrics,
    regressions,
  };
}

function runCli(): void {
  const args = parseArgs(process.argv.slice(2));

  const baseline = parseMetricsFile(args.baselinePath);
  const current = parseMetricsFile(args.currentPath);

  if (baseline.size === 0) {
    console.error(`No METRIC lines found in baseline: ${args.baselinePath}`);
    process.exit(2);
  }

  if (current.size === 0) {
    console.error(`No METRIC lines found in current: ${args.currentPath}`);
    process.exit(2);
  }

  const result = compareMetricMaps(baseline, current, {
    metricSet: args.metricSet,
    maxRegressionPct: args.maxRegressionPct,
    minBaselineUs: args.minBaselineUs,
    maxAbsoluteRegressionUs: args.maxAbsoluteRegressionUs,
  });

  if (result.missingMetrics.length > 0) {
    console.error("Missing metrics in current output:");
    for (const metric of result.missingMetrics) {
      console.error(`  - ${metric}`);
    }
    process.exit(1);
  }

  if (result.regressions.length > 0) {
    console.error(
      `Benchmark regression check FAILED (metric set: ${args.metricSet}, max +${args.maxRegressionPct.toFixed(2)}%, min baseline ${args.minBaselineUs.toFixed(4)}us, abs guard +${args.maxAbsoluteRegressionUs.toFixed(4)}us).`,
    );

    for (const regression of result.regressions.sort((a, b) => {
      if (a.kind === "pct" && b.kind === "pct") {
        return (b.deltaPct ?? 0) - (a.deltaPct ?? 0);
      }
      if (a.kind === "abs" && b.kind === "abs") {
        return (b.deltaUs ?? 0) - (a.deltaUs ?? 0);
      }
      return a.kind === "pct" ? -1 : 1;
    })) {
      if (regression.kind === "pct") {
        console.error(
          `  - ${regression.metric}: baseline=${regression.baseline.toFixed(4)} current=${regression.current.toFixed(4)} delta=+${(regression.deltaPct ?? 0).toFixed(2)}%`,
        );
      } else {
        console.error(
          `  - ${regression.metric}: baseline=${regression.baseline.toFixed(4)} current=${regression.current.toFixed(4)} abs_delta=+${(regression.deltaUs ?? 0).toFixed(4)}us`,
        );
      }
    }

    process.exit(1);
  }

  console.log(
    `Benchmark regression check passed (${result.comparedMetrics} metrics compared, metric set: ${args.metricSet}, max +${args.maxRegressionPct.toFixed(2)}%).`,
  );
}

const entrypoint = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === entrypoint) {
  runCli();
}
