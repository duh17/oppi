/**
 * Run benchmark suites multiple times, aggregate median metrics, and compare
 * against checked-in baselines.
 */

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  compareMetricMaps,
  parseMetricsText,
  type CompareOptions,
  type MetricSet,
} from "./compare-metrics.js";

interface SuiteConfig {
  id: "hotpath";
  displayName: string;
  command: string;
  args: string[];
  baselinePath: string;
}

interface CliArgs extends CompareOptions {
  runs: number;
  suite: "all" | "hotpath";
}

const SUITES: SuiteConfig[] = [
  {
    id: "hotpath",
    displayName: "server hotpath",
    command: "tsx",
    args: ["bench/server-hotpath.bench.ts"],
    baselinePath: "bench/baselines/server-hotpath.metrics",
  },
];

function usage(): never {
  console.error(
    "Usage: tsx bench/run-gate.ts [--suite all|hotpath] [--runs <n>] [--metric-set avg|all] [--max-regression-pct <n>] [--min-baseline-us <n>] [--max-absolute-regression-us <n>]",
  );
  process.exit(2);
}

function parseArgs(argv: string[]): CliArgs {
  let suite: CliArgs["suite"] = "all";
  let runs = 3;
  let metricSet: MetricSet = "avg";
  let maxRegressionPct = 15;
  let minBaselineUs = 0.2;
  let maxAbsoluteRegressionUs = 0.05;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === "--suite") {
      const raw = (argv[++i] ?? "").trim();
      if (raw !== "all" && raw !== "hotpath") {
        usage();
      }
      suite = raw;
      continue;
    }

    if (arg === "--runs") {
      const raw = Number(argv[++i] ?? "");
      if (!Number.isInteger(raw) || raw < 1 || raw > 20) {
        usage();
      }
      runs = raw;
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
      const raw = Number(argv[++i] ?? "");
      if (!Number.isFinite(raw) || raw < 0) {
        usage();
      }
      maxRegressionPct = raw;
      continue;
    }

    if (arg === "--min-baseline-us") {
      const raw = Number(argv[++i] ?? "");
      if (!Number.isFinite(raw) || raw < 0) {
        usage();
      }
      minBaselineUs = raw;
      continue;
    }

    if (arg === "--max-absolute-regression-us") {
      const raw = Number(argv[++i] ?? "");
      if (!Number.isFinite(raw) || raw < 0) {
        usage();
      }
      maxAbsoluteRegressionUs = raw;
      continue;
    }

    usage();
  }

  return {
    suite,
    runs,
    metricSet,
    maxRegressionPct,
    minBaselineUs,
    maxAbsoluteRegressionUs,
  };
}

function runSuiteOnce(suite: SuiteConfig): Map<string, number> {
  const result = spawnSync(suite.command, suite.args, {
    encoding: "utf8",
    env: process.env,
  });

  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }

  if (result.status !== 0) {
    throw new Error(
      `${suite.displayName} benchmark failed (exit=${result.status ?? "null"}, signal=${result.signal ?? "none"})`,
    );
  }

  const metrics = parseMetricsText(result.stdout ?? "");
  if (metrics.size === 0) {
    throw new Error(`${suite.displayName} benchmark emitted no METRIC lines`);
  }

  return metrics;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 0) {
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
  return sorted[mid];
}

function aggregateMedianMetrics(runs: Map<string, number>[]): Map<string, number> {
  const metricNames = [...runs[0].keys()];

  for (let i = 1; i < runs.length; i++) {
    const names = new Set(runs[i].keys());
    for (const metricName of metricNames) {
      if (!names.has(metricName)) {
        throw new Error(`Missing metric '${metricName}' in run #${i + 1}`);
      }
    }
  }

  const out = new Map<string, number>();
  for (const metricName of metricNames) {
    const values = runs.map((r) => r.get(metricName)).filter((v): v is number => v !== undefined);
    out.set(metricName, median(values));
  }

  return out;
}

function metricsToText(metrics: Map<string, number>): string {
  return [...metrics.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([name, value]) => `METRIC ${name}=${value.toFixed(4)}`)
    .join("\n");
}

function suiteSelection(allSuites: SuiteConfig[], pick: CliArgs["suite"]): SuiteConfig[] {
  if (pick === "all") {
    return allSuites;
  }
  return allSuites.filter((suite) => suite.id === pick);
}

function runGateForSuite(suite: SuiteConfig, opts: CliArgs, scratchDir: string): boolean {
  console.error(
    `\n[bench-gate] Running suite '${suite.id}' ${opts.runs}x (metric set: ${opts.metricSet})...`,
  );

  const runMetrics: Map<string, number>[] = [];
  for (let i = 0; i < opts.runs; i++) {
    console.error(`[bench-gate] ${suite.id} run ${i + 1}/${opts.runs}`);
    const metrics = runSuiteOnce(suite);
    const total = metrics.get("total_avg_us");
    if (typeof total === "number") {
      console.error(`[bench-gate] ${suite.id} run ${i + 1}: total_avg_us=${total.toFixed(4)}`);
    }
    runMetrics.push(metrics);
  }

  const medianMetrics = aggregateMedianMetrics(runMetrics);
  const currentPath = join(scratchDir, `${suite.id}.median.metrics`);
  writeFileSync(currentPath, metricsToText(medianMetrics) + "\n", "utf8");

  const baseline = parseMetricsText(readFileSync(suite.baselinePath, "utf8"));
  const compared = compareMetricMaps(baseline, medianMetrics, {
    metricSet: opts.metricSet,
    maxRegressionPct: opts.maxRegressionPct,
    minBaselineUs: opts.minBaselineUs,
    maxAbsoluteRegressionUs: opts.maxAbsoluteRegressionUs,
  });

  if (compared.missingMetrics.length > 0) {
    console.error(`[bench-gate] ${suite.id} FAILED: missing metrics:`);
    for (const metric of compared.missingMetrics) {
      console.error(`  - ${metric}`);
    }
    return false;
  }

  if (compared.regressions.length > 0) {
    console.error(`[bench-gate] ${suite.id} FAILED: regressions detected`);
    for (const regression of compared.regressions) {
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
    console.error(`[bench-gate] Median metrics written to ${currentPath}`);
    return false;
  }

  console.error(
    `[bench-gate] ${suite.id} passed (${compared.comparedMetrics} metrics compared). Median metrics: ${currentPath}`,
  );
  return true;
}

function main(): void {
  const opts = parseArgs(process.argv.slice(2));
  const suites = suiteSelection(SUITES, opts.suite);

  const scratchDir = mkdtempSync(join(tmpdir(), "oppi-bench-gate-"));
  let ok = true;

  try {
    for (const suite of suites) {
      const suiteOk = runGateForSuite(suite, opts, scratchDir);
      if (!suiteOk) {
        ok = false;
      }
    }
  } finally {
    if (ok) {
      rmSync(scratchDir, { recursive: true, force: true });
    } else {
      console.error(`[bench-gate] Preserved debug artifacts at ${scratchDir}`);
    }
  }

  if (!ok) {
    process.exit(1);
  }

  console.log("Benchmark gate passed.");
}

main();
