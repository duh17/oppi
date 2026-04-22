# Benchmark baselines

Store checked-in baseline snapshots here as plain text files containing `METRIC` lines.

Suggested naming:

- `server-hotpath.metrics`

Generate a snapshot (after correctness gate passes):

```bash
npm run bench:correctness
npm run bench:hotpath > bench/baselines/server-hotpath.metrics
```

Validate with multi-run median gating:

```bash
npm run bench:perf:gate
```

Re-record baselines only after intentional performance changes or benchmark methodology changes.
