# Benchmark baselines

Store checked-in baseline snapshots here as plain-text files with `METRIC` lines.

Suggested naming:

- `server-hotpath.metrics`

After the correctness gate passes, generate a snapshot:

```bash
npm run bench:correctness
npm run bench:hotpath > bench/baselines/server-hotpath.metrics
```

Validate with multi-run median gating:

```bash
npm run bench:perf:gate
```

Re-record baselines only after an intentional performance or benchmark-methodology change.
