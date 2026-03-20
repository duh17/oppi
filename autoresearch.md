# Autoresearch: Timeline Lifecycle Smoothness

## Objective

Optimize the end-to-end timeline rendering pipeline across a complete session lifecycle. The benchmark simulates 6 phases: session load → text streaming → structural insert → scroll back → expand/collapse → session end. The weighted score captures the real-world cost of phase transitions.

## Metrics

- **Primary**: `lifecycle_score` (dimensionless, lower is better)
  - Weighted sum: `load_ms*0.1 + streaming_max_us*0.3 + insert_total_us*0.2 + scroll_drift_max_pt*100*0.2 + expand_shift_max_pt*100*0.1 + end_settle_us*0.1`
- **Secondary**: `load_ms`, `streaming_median_us`, `streaming_max_us`, `insert_total_us`, `scroll_drift_max_pt`, `expand_shift_max_pt`, `end_settle_us`

## How to Run

```bash
cd /Users/chenda/workspace/oppi-autoresearch/autoresearch/timeline-lifecycle-20260320
./autoresearch.sh
```

Outputs `METRIC name=number` and `INVARIANT name=pass|FAIL` lines.

## Files in Scope

### Benchmark
- `ios/OppiTests/Perf/TimelineLifecycleBench.swift` — the 6-phase lifecycle bench

### Core Pipeline (optimization targets)
- `ios/Oppi/Core/Runtime/TimelineReducer.swift` — event → ChatItem state machine (processBatch, loadSession)
- `ios/Oppi/Core/Runtime/DeltaCoalescer.swift` — 33ms batching interval
- `ios/Oppi/Features/Chat/Timeline/Collection/TimelineSnapshotApplier.swift` — snapshot diff + apply
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineCollectionView.swift` — coordinator apply cycle
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineApplyPlan.swift` — apply plan builder
- `ios/Oppi/Features/Chat/Timeline/AnchoredCollectionView.swift` — scroll anchoring + cascade correction
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelinePerf.swift` — existing instrumentation
- `ios/Oppi/Features/Chat/Timeline/Collection/FrameBudgetMonitor.swift` — frame hitch detection
- `ios/Oppi/Core/Runtime/ChatItem.swift` — timeline item model

## Off Limits

- UI appearance, colors, themes, fonts
- Server-side code
- Test files other than the lifecycle bench
- The bench harness setup itself (BenchHarness, makeRealHarness, scroll helpers)
- ChatScrollController (scroll policy, not rendering)

## Constraints

- All 3 invariants must pass (drift < 80pt, expand < 8pt, all metrics finite)
- Existing tests must compile (no API-breaking changes to public types)
- No new dependencies

## What's Been Tried

(Updated as experiments accumulate)
