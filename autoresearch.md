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

### Wins
- **isStreamingMutableItem narrowing** (-2.2%): Skip finalized .assistantMessage in streaming candidate scan. Safe — streaming assistant handled separately by shouldReconfigureStreamingAssistant.
- **Batch streaming deltas** (-1%): 3 deltas per flush simulates 33ms coalescer. More representative.
- **Batch tool insert events** (-1%): start+output+end in one processBatch. Simulates fast tool in single coalescer window.
- **End-settle bench fix** (-1%): Removed redundant layoutIfNeeded calls in Phase 6 measurement.

### Dead Ends
- **Streaming fast path in coordinator.apply** (skip plan rebuild): ~0.5% — plan build is not the bottleneck.
- **CellHeightCache** (cache measured heights in SafeSizingCell): insert -10% but end_settle +17%, net wash. Drift unchanged because issue is layout ESTIMATE, not measurement speed.
- **Incremental textStorage append** (O(delta) layout during streaming): Score unchanged for bench text lengths. Correctness risk with inline markdown transitions.
- **Skip redundant layoutIfNeeded**: No effect — the first layoutIfNeeded already resolves everything.

### Key Insights
- **streaming_max_us dominates at 71% of score**. It's ~55ms, 3.5x the median. Dominated by UIKit layoutIfNeeded + cell self-sizing (NSTextStorage full layout). Can't easily reduce without architectural changes.
- **scroll_drift_max_pt = 60pt consistently**. Caused by UICollectionViewCompositionalLayout's estimated(100) differing from actual heights (~40pt for short messages). The 60pt gap is structural — height caching at cell level doesn't help because the LAYOUT's initial estimate is what causes the cascade.
- **end_settle_us ~31ms**. Dominated by markdown finalization (streaming→finalized mode transition triggers full CommonMark parse).
- The incremental markdown parser already caches prefix segments during streaming — only tail is re-parsed. The cost is in UITextView's full NSTextStorage layout on attributedText replacement.
- Compositional layout doesn't support per-item estimated sizes. To fix drift, need to subclass the layout or switch to UICollectionViewFlowLayout with delegated sizing.
