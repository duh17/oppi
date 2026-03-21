# Autoresearch: Insert Stability (Bounce Reduction)

## Objective

Reduce the visual bounciness/stutter when new structural items (tool calls, permission rows, system events) are inserted into the chat timeline during streaming. The user is typically attached to the bottom, watching content appear. New items currently cause a visible jump because UICollectionViewCompositionalLayout uses `estimated(100)` heights — when the actual height differs (e.g. 35pt for a permission row), UIKit adjusts contentOffset mid-frame, creating a bounce.

## Metrics

- **Primary**: `insert_stability_score` (dimensionless, lower is better)
  - Weighted sum: `tool_insert_drift_pt * 3 + permission_insert_drift_pt * 3 + system_insert_drift_pt * 2 + multi_insert_drift_pt * 2`
  - Measures the maximum contentOffset delta between snapshot apply and settled layout for each insert type.
- **Secondary**: `tool_insert_drift_pt`, `permission_insert_drift_pt`, `system_insert_drift_pt`, `multi_insert_drift_pt`, `total_insert_ms`

## How to Run

```bash
cd /Users/chenda/workspace/oppi-autoresearch/autoresearch/insert-stability-20260321
./autoresearch.sh
```

Outputs `METRIC name=number` and `INVARIANT name=pass|FAIL` lines.

## Files in Scope

### Benchmark
- `ios/OppiTests/Perf/InsertStabilityBench.swift` — the insertion stability bench

### Core Pipeline (optimization targets)
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineCollectionView.swift` — coordinator apply cycle + makeLayout()
- `ios/Oppi/Features/Chat/Timeline/Collection/TimelineSnapshotApplier.swift` — snapshot diff + apply
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineCollectionView+DataSource.swift` — SafeSizingCell + cell registration
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineCollectionView+ScrollDelegate.swift` — scroll state + bottom-pinning
- `ios/Oppi/Features/Chat/Timeline/AnchoredCollectionView.swift` — scroll anchoring
- `ios/Oppi/Features/Chat/Timeline/Collection/ChatTimelineApplyPlan.swift` — apply plan builder
- `ios/Oppi/Core/Runtime/TimelineReducer.swift` — event → ChatItem state machine
- `ios/Oppi/Core/Runtime/ChatItem.swift` — timeline item model

## Off Limits

- UI appearance, colors, themes, fonts
- Server-side code
- Test files other than the insert stability bench
- The bench harness setup itself
- ChatScrollController (scroll policy)
- Tool row content rendering (ToolTimelineRowContent and children)

## Constraints

- All invariants must pass
- Existing tests must compile (no API-breaking changes to public types)
- No new dependencies
- Scroll anchoring for detached users must still work
- Auto-scroll (bottom-pinning) during streaming must still work

## What's Been Tried

(none yet — fresh session)

## Key Insights

The root cause of bounciness is the gap between `estimated(100)` and actual cell heights:
- Permission rows: ~25-35pt actual (75pt overestimate → viewport jumps up)
- Tool rows (collapsed): ~35-45pt actual (55-65pt overestimate)
- System events: ~30-40pt actual (60-70pt overestimate)
- Assistant messages: 50-500pt+ (can be underestimate for long messages)

When the user is attached to bottom and a new item is inserted above the viewport bottom:
1. UIKit allocates 100pt for the new cell
2. contentSize grows by 100pt
3. Auto-scroll pushes to new bottom
4. Self-sizing resolves to actual height (e.g. 35pt)
5. contentSize shrinks by 65pt
6. Another contentOffset adjustment
7. Visual result: bounce/jitter

Potential approaches:
1. **Better estimated heights per item type** — provide different estimates for different cell registrations
2. **Pre-calculate heights** — compute actual height before snapshot apply
3. **Custom layout** — replace compositional layout with one that supports per-item estimates
4. **Suppress layout during insert** — batch the insert + self-sizing into one frame
5. **UIView.performWithoutAnimation** around the critical path
