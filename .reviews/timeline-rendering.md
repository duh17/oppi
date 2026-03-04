# Timeline + Rendering Review (since `testflight/19`)

## Architecture Assessment

Overall: **good direction, still a hot-path complexity hotspot**.

### What got materially cleaner

1. **Reducer decomposition is significantly better**
   - `TimelineReducer` now delegates ID lookup and turn assembly to helpers:
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:60` (`TimelineItemIndex`)
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:600`, `610`, `838`, `854`, `903`, `975`, `991`, `1009` (`TimelineTurnAssembler` usage)
   - Explicit history load modes are a win for readability/testability:
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:419-437` (`HistoryLoadMode` + `loadSessionMode`)

2. **Timeline host rendering pipeline is now split by concern**
   - Cell dispatch: `ios/Oppi/Features/Chat/Timeline/TimelineCellFactory.swift`
   - Snapshot application: `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift`
   - Scroll behavior: `ios/Oppi/Features/Chat/Timeline/TimelineScrollCoordinator.swift`
   - Data source/row/scroll split out of primary file:
     - `ChatTimelineCollectionView+DataSource.swift`
     - `ChatTimelineCollectionView+RowBuilders.swift`
     - `ChatTimelineCollectionView+ScrollDelegate.swift`

3. **Tool expanded rendering is now policy-driven, not boolean-spaghetti**
   - Routing: `ToolTimelineRowExpandedModeRouter`
   - Interaction matrix: `ToolTimelineRowInteractionPolicy.swift`
   - Mode renderers: `ToolTimelineRowExpandedRenderer.swift`

### What is still too coupled

- `ChatTimelineCollectionHost.Controller` is still a “god object” across diffing, scrolling, selection behavior, async tool output loading, and theme/session transitions:
  - `ios/Oppi/Features/Chat/Timeline/ChatTimelineCollectionView.swift:258-761`
- `ToolTimelineRowContentView` remains very large and multi-responsibility (layout, media decoding, gestures, context menus, fullscreen routing, viewport math, markdown invalidation):
  - `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowContent.swift:841` (`apply(configuration:)`)

## Risk Areas

1. **Incremental history no-op can miss payload changes with stable IDs**
   - `loadSessionMode` only checks prefix event IDs (`events[index].id == loadedID`), not payload equality:
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:425-437`
   - If server trace content mutates without ID changes, reducer can incorrectly choose `.noOp` and keep stale UI.

2. **Unconditional render bump for all non-delta events in `processBatch`**
   - In the default branch, any non-delta event sets `didMutate = true` after `processInternal(event)` regardless of whether state actually changed:
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:532-533`
   - This can generate avoidable snapshot/layout churn for idempotent/replayed events.

3. **Index cache staleness path in whitespace finalize branch**
   - `finalizeAssistantMessage()` removes current assistant row via `items.removeAll` without rebuilding index cache:
     - `ios/Oppi/Core/Runtime/TimelineReducer.swift:933-936`
   - Correctness is mostly preserved by fallback scans, but this can silently degrade lookup behavior/perf.

4. **Deferred layout invalidation may silently drop after timeout**
   - Interaction-gated invalidation retries for up to 180 frames, then gives up:
     - `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowPresentationHelpers.swift:158-186`
   - In pathological long interaction sequences, row size correction can be skipped.

5. **No direct unit tests for helper correctness boundaries**
   - `TimelineItemIndex` and `TimelineTurnAssembler` have strong integration coverage, but no direct focused unit suites found.
   - Integration tests are great, but helper-level regressions may be harder to localize quickly.

## Performance Concerns

1. **Snapshot change detection does extra work per apply**
   - Full `nextItemByID` scan each cycle:
     - `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift:93-103`
   - Dedup + filter uses `Array(Set(...)).filter { nextIDs.contains($0) }`:
     - `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift:49`
   - `nextIDs.contains` is linear; this gets expensive as timeline grows.

2. **Layout forced frequently on hot path**
   - Main apply path forces `collectionView.layoutIfNeeded()`:
     - `ios/Oppi/Features/Chat/Timeline/ChatTimelineCollectionView.swift:469`
   - Reconfigure path also forces layout:
     - `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift:89`

3. **Large-text signatures hash full payload repeatedly**
   - Render signatures combine full output text directly:
     - `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowRenderMetrics.swift:38`, `73`, `118`
   - For large outputs, this is non-trivial CPU in repeated apply/reconfigure cycles.

4. **Thinking markdown parse is on main path**
   - `ThinkingTimelineRowContentView` parses markdown in `makeThinkingAttributedText`:
     - `ios/Oppi/Features/Chat/Timeline/ThinkingTimelineRowContent.swift:342-350`
   - This can be expensive during high-frequency thinking updates.

5. **Viewport measurement is heavy and frequent**
   - Repeated measurement via `systemLayoutSizeFitting` for dynamic viewport heights:
     - `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowContent.swift:271-459`

## The Reverted Feature (staged inline expansion)

### What was implemented

- `eff4d75` introduced `ToolTimelineInlineExpansion` with hard line caps and synthetic truncation notes:
  - `compactTextLineLimit = 24`, `expandedTextLineLimit = 120`, `compactCodeLineLimit = 40`, `expandedCodeLineLimit = 220`
  - Truncation markers like `“… [N lines hidden. Tap Show more.]”`
  - Source: `eff4d75:ios/Oppi/Features/Chat/Timeline/ToolTimelineInlineExpansion.swift:21-57,80-93`

### Why it likely failed (and was quickly reverted in `303f101`)

1. **It mutated user-visible output content** (not just viewport behavior) by injecting synthetic notes and truncation text.
2. **It added another expansion state machine in coordinator state** (`toolInlineExpansionLevelByID`) with lifecycle/reset logic across selection/session/removal.
3. **It was bundled with unrelated scroll behavior changes** (bottom anchoring logic in the same commit), increasing blast radius.
4. **Coverage focused on toggle state**, not full interaction matrix under scroll/stream/reuse pressure.

### Should it come back?

**Not in the previous form.**

If revived, it should be:
- **non-destructive** (no synthetic truncation text in output payload rendering),
- **isolated** (separate PR from scroll behavior changes),
- **measured** (perf + scroll-stability + fullscreen parity tests),
- **state-owned in one place** (prefer reducer/state model over ad-hoc controller map where possible).

## Suggestions (ordered by impact)

1. **Harden incremental load correctness**
   - Extend `loadSessionMode` beyond ID-prefix checks (e.g., compare tail event digest or `(id,type,timestamp,textHash)` for appended range).
   - Target: `TimelineReducer.swift:425-437`.

2. **Make renderVersion bumps mutation-aware for non-delta events**
   - Return mutation flags from `processInternal` and only bump when state changed.
   - Target: `TimelineReducer.swift:532-533`.

3. **Reduce snapshot apply complexity on large timelines**
   - Replace `nextIDs.contains` filtering with set-backed membership, preserve stable order without `Array(Set(...))` randomness.
   - Target: `TimelineSnapshotApplier.swift:49,93-103`.

4. **Move thinking markdown parse off critical path**
   - Reuse `AssistantMarkdownContentView` pipeline or cached parse strategy for thinking rows, especially streaming updates.
   - Target: `ThinkingTimelineRowContent.swift:342-350`.

5. **Add direct helper unit suites**
   - Add focused tests for `TimelineItemIndex` cache invalidation and `TimelineTurnAssembler` edge behavior.
   - This complements existing excellent integration coverage (`TimelineReducer*`, `Scroll*`, `Tool*` test suites).
