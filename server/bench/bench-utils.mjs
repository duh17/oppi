#!/usr/bin/env node

/**
 * Lightweight benchmark harness for server-side perf tests.
 * Outputs METRIC lines compatible with the autoresearch loop.
 *
 * Usage:
 *   import { bench, metric, stats } from './bench-utils.mjs';
 *   await bench('my_op', () => { doStuff(); });
 */

/**
 * Print a single METRIC line to stdout.
 * @param {string} name
 * @param {number} value
 */
export function metric(name, value) {
  console.log(`METRIC ${name}=${value}`);
}

/**
 * Compute descriptive statistics from an array of BigInt durations (nanoseconds).
 * Returns numbers in nanoseconds (as regular Number).
 * @param {BigInt[]} durations - Array of nanosecond BigInt values
 * @returns {{ mean: number, median: number, p95: number, p99: number, min: number, max: number, stddev: number }}
 */
export function stats(durations) {
  const n = durations.length;
  if (n === 0) throw new Error("stats() requires at least one duration");

  // Convert to regular numbers for arithmetic (safe up to ~9007 seconds in ns)
  const nums = durations.map(Number).sort((a, b) => a - b);

  const sum = nums.reduce((a, b) => a + b, 0);
  const mean = sum / n;

  const median = n % 2 === 1
    ? nums[(n - 1) / 2]
    : (nums[n / 2 - 1] + nums[n / 2]) / 2;

  const p95 = nums[Math.min(Math.ceil(n * 0.95) - 1, n - 1)];
  const p99 = nums[Math.min(Math.ceil(n * 0.99) - 1, n - 1)];
  const min = nums[0];
  const max = nums[n - 1];

  const variance = nums.reduce((acc, v) => acc + (v - mean) ** 2, 0) / n;
  const stddev = Math.sqrt(variance);

  return { mean, median, p95, p99, min, max, stddev };
}

/**
 * Run a benchmark function N times after warmup, compute stats, print METRIC lines.
 *
 * @param {string} name - Metric name prefix (e.g. "event_ring_push")
 * @param {() => void | () => Promise<void>} fn - Function to benchmark
 * @param {object} [opts]
 * @param {number} [opts.iterations=100] - Measured iterations
 * @param {number} [opts.warmup=10] - Warmup iterations (not measured)
 */
export async function bench(name, fn, opts = {}) {
  const iterations = opts.iterations ?? 100;
  const warmup = opts.warmup ?? 10;

  // Warmup — let V8 JIT optimize
  for (let i = 0; i < warmup; i++) {
    await fn();
  }

  // Measured runs
  const durations = new Array(iterations);
  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    await fn();
    durations[i] = process.hrtime.bigint() - start;
  }

  const s = stats(durations);
  const nsToUs = (ns) => +(ns / 1000).toFixed(2);

  metric(`${name}_mean_us`, nsToUs(s.mean));
  metric(`${name}_p50_us`, nsToUs(s.median));
  metric(`${name}_p95_us`, nsToUs(s.p95));
  metric(`${name}_p99_us`, nsToUs(s.p99));
  metric(`${name}_min_us`, nsToUs(s.min));
  metric(`${name}_max_us`, nsToUs(s.max));
}
