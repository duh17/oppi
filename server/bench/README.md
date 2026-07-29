# Server benchmarks

This directory contains the canonical server microbenchmarks and performance-regression checks. The containerized Iroh network benchmark lives under `e2e/` because it exercises production HTTP routes, WebSocket muxes, uploads, downloads, Docker topology, and selected Iroh paths—not an in-process hot path.

## Layout

- `*.bench.ts` — executable benchmark scripts (run with `tsx`)
- `compare-metrics.ts` — compares two benchmark outputs using `METRIC` lines
- `baselines/` — checked-in baseline metric snapshots (`.metrics` files)

## Output contract

Each benchmark must write machine-readable lines to **stdout**:

```text
METRIC <name>=<number>
```

Human-readable tables should go to **stderr**.

This keeps CI output parseable and local reports readable.

## Standards (correctness first, then perf)

This repository uses the same order as its autoresearch loops:

1. **Correctness gate first** (`npm run bench:correctness`):
   - `npm run check` (types + lint + formatting + knip)
   - `npm test` (unit/integration suite)
2. **Benchmark only a correctness-clean commit.**
3. Track and compare `total_avg_us`, category `*_us`, and per-case `*_avg_us` metrics for gating.
4. Keep `*_p99_us` metrics for diagnostics, but do not gate on p99 by default (too noisy).
5. Compare against the corresponding baseline file in `bench/baselines/`.
6. Fail if median metrics regress by more than **15%**.
7. For tiny metrics (baseline `<=0.2us`), use an absolute guard (`+0.05us`) instead of percentage deltas.
8. Run each benchmark multiple times and gate on the **median metric value**.

Use:

```bash
npm run bench:correctness
npm run bench:perf:gate

# one-suite gate
npm run bench:hotpath:gate
```

## Commands

```bash
npm run bench:correctness # correctness gate (check + tests)
npm run bench             # correctness gate + median perf regression gate
npm run bench:gate        # alias of `npm run bench`
npm run bench:perf        # run hotpath benchmark once (no compare)
npm run bench:perf:gate   # run hotpath multi-run + compare to baseline
npm run bench:hotpath     # critical event pipeline benchmark
npm run bench:hotpath:gate
npm run bench:compare -- --baseline <file> --current <file>

# Separate evidence lane; not part of the flaky-sensitive unit/perf gate
npm run bench:iroh-network
```

`bench:iroh-network` uses fixed sample counts. It writes durable raw JSON and a Markdown comparison to `.internal/reports/iroh-benchmark-<timestamp>.{json,md}`. It fails when samples are missing or an Iroh `Connection.paths()` selection does not match the requested direct or relay path.
