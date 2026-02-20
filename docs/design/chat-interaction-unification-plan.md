# Chat Interaction Unification Plan (UIKit-First)

Status: **Active**  
Owner: iOS client  
Updated: 2026-02-19

## Why

Oppi currently exposes multiple interaction dialects for the same intents (copy, expand, full-screen) across chat surfaces.

This plan standardizes on a single design language and a single rendering strategy for timeline hot paths:

- **UIKit-first on hot paths** (streaming timeline + expanded tool content)
- **SwiftUI kept only as gated fallback** for emergency rollback / parity checks

## Decision

### 1) Hot-path renderer policy

For chat timeline hot paths, UIKit is the default implementation strategy.

- `HotPathRenderGates.enableSwiftUIHotPathFallbacks` controls legacy SwiftUI hosted fallbacks.
- Default is **off**.
- Debug override:
  - `OPPI_ENABLE_SWIFTUI_HOTPATH_FALLBACKS=1`

Source: `ios/Oppi/Core/AppIdentifiers.swift`

### 2) Immediate behavior under UIKit-first mode

In `ToolTimelineRowContentView`, expanded tool content uses native UIKit renderers on hot path:

- `.todoCard` → `NativeExpandedTodoView`
- `.readMedia` → `NativeExpandedReadMediaView`

Legacy SwiftUI hosted paths remain available only when
`HotPathRenderGates.enableSwiftUIHotPathFallbacks` is enabled.

Source: `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowContent.swift`

This keeps hot path deterministic while preserving rollback safety.

## Hot-path scope

In scope (must be UIKit-first):

- Timeline row rendering in `ChatTimelineCollectionView`
- Tool row expand/collapse and expanded viewport rendering
- Gesture handling in timeline rows (tap/double tap/pinch)
- Copy interactions inside timeline rows

Out of scope for now (can remain SwiftUI):

- Non-timeline file viewers and utility/detail screens
- Standalone full-screen utility views not in streaming row loop

## Unification targets (design language)

All chat surfaces should converge on:

1. **Action vocabulary**
   - `Copy`
   - `Open Full Screen`
   - `Expand` (inline row only)

2. **Interaction consistency**
   - Primary explicit affordance always visible where applicable
   - Gestures as accelerators, never the only path

3. **Feedback consistency**
   - One copy feedback language (icon state + haptic timing)

4. **Fullscreen consistency**
   - One presentation style + one toolbar/chrome pattern

## Phased rollout

### Phase 0 (done)

- Added hot-path SwiftUI fallback gate.
- Defaulted hot path to UIKit-first behavior.
- Added initial regression coverage for UIKit-first expanded tool behavior.

### Phase 1 (done)

- Implemented native UIKit expanded components for:
  - Todo card (`NativeExpandedTodoView`)
  - Read-media preview (`NativeExpandedReadMediaView`)
- Kept legacy SwiftUI implementations as gated fallback only.

### Phase 2 (done)

- Normalized timeline context-menu primary copy action labels to `Copy`.
- Tool rows use `Open Full Screen` and hide the floating full-screen affordance when expanded content does not overflow.
- Unified timeline copy feedback behavior across row types via shared UIKit helper (`TimelineCopyFeedback`).
- Added regression coverage for context-menu action title/order across tool, assistant, user, permission, error, and compaction rows.
- Added double-tap copy accelerators across timeline bubbles (assistant/user/permission/error/compaction).
- Moved compaction expand/collapse from row single-tap to explicit chevron affordance so expand and copy gestures no longer conflict.

### Phase 3 (in progress)

- Audited SwiftUI/non-hotpath tool and file output surfaces for copy/full-screen vocabulary drift.
- Normalized non-hotpath context-menu primary copy labels to `Copy` in:
  - `ios/Oppi/Features/Chat/Output/ToolOutputViews.swift`
  - `ios/Oppi/Features/Chat/Output/TodoToolOutputView.swift` (while preserving a secondary command copy action)
  - `ios/Oppi/Core/Views/FileContentView.swift`
  - `ios/Oppi/Core/Views/DiffContentView.swift`
  - `ios/Oppi/Core/Views/ImageBlobView.swift`
- Normalized non-hotpath full-screen menu action labels to `Open Full Screen` in:
  - `ios/Oppi/Core/Views/FileContentView.swift`
  - `ios/Oppi/Core/Views/DiffContentView.swift`
- Completed a broader timeline gesture consistency pass:
  - Expanded markdown tool content now disables row-level tap-copy interception across **all** tool contexts (not just `read`) so native text selection works.
  - Expanded code/diff content on full-screen-capable tools keeps double-tap/pinch full-screen accelerators.
  - Added regression coverage for the generalized markdown/code split and timeline row copy gesture/menu consistency.
- Keep SwiftUI fallback code behind gate for one release cycle, then evaluate deletion.

## Validation

Minimum checks per phase:

- `ChatTimelineCollectionViewTests` hot-path regression suite
- Tool expand/collapse reuse + sizing stability tests
- Manual device verification for:
  - long streaming sessions
  - repeated expand/collapse
  - copy and full-screen interactions under heavy timeline load

## Notes

- UIKit-first here is a performance/reliability decision, not an anti-SwiftUI stance.
- SwiftUI fallback is intentionally retained (gated) for recovery and parity validation.
