# iOS Coverage Extraction Opportunities

Last updated: 2026-03-05

Purpose: identify business logic currently embedded in SwiftUI-heavy layers that have low unit-test coverage. These are extraction candidates only (no behavior changes in this PR).

## High-priority candidates

### 1) `ios/Oppi/App/ContentView.swift`
- `crossSessionPending` filtering/sorting, `serverLabel(for:)`, and permission routing (`findConnectionForPermission`, biometric guard in `handleCrossSessionPermissionChoice`) are coordination logic.
- Candidate extraction:
  - `CrossSessionPermissionCoordinator` (pure Swift type + tests)
  - input: all pending permissions + active session + server/session indexes
  - output: banner model + target connection/server metadata + action plan
- Why: App layer remains hard to cover while this logic is deterministic and testable.

### 2) `ios/Oppi/Features/Chat/Support/SessionOutlineView.swift`
- `buildIndex()`, `applyFilter()`, `outlineSummary(for:)`, tool summary formatting, compaction classification are all non-UI transformation logic.
- Candidate extraction:
  - `SessionOutlineIndexer`
  - `SessionOutlineFilterEngine`
  - `SessionOutlineSummaryFormatter`
- Why: this file mixes rendering + indexing/search behavior; extraction would enable direct Swift Testing coverage for search/filter correctness.

### 3) `ios/Oppi/Features/Chat/Support/SessionChangesView.swift`
- `buildChangeIndex()` computes edit/write entries, diff stats, grouping, ordering, and totals.
- Candidate extraction:
  - `SessionChangeIndexer` returning immutable DTOs (`groups`, `summary totals`)
- Why: expensive logic currently runs in view state setup and is difficult to test in isolation.

## Medium-priority candidates

### 4) `ios/Oppi/Features/Chat/Composer/MessageQueueContainer.swift`
- Queue mutation logic (`moveItem`, `moveBetweenQueues`, `deleteItem`, dirty-state rules, draft apply payload mapping) is domain logic.
- Candidate extraction:
  - `MessageQueueDraftReducer` (state + actions)
- Why: deterministic reducer-style transitions are ideal for unit tests and reduce view complexity.

### 5) `ios/Oppi/Features/Chat/Composer/ChatInputBar.swift`
### 6) `ios/Oppi/Features/Chat/Composer/ExpandedComposerView.swift`
- Shared voice-input transition rules and autocomplete context handling appear in both files.
- Candidate extraction:
  - `ComposerInputStateMachine` for voice/keyboard/send transitions
  - `ComposerCommandContext` wrapper around autocomplete + suggestion query dispatch
- Why: de-duplicates behavior and enables targeted tests for tricky recording/keyboard edge cases.

### 7) `ios/Oppi/Features/Workspaces/WorkspaceHomeView.swift`
- Workspace ranking and status derivation (`sortedWorkspaces`, `activeCount`, `stoppedCount`, `hasAttention`, `latestActivity`) are pure computations.
- Candidate extraction:
  - `WorkspaceListProjection` / `WorkspaceRanker`
- Why: predictable list ordering should be locked with tests independent of SwiftUI rendering.

## Lower-priority candidate

### 8) `ios/Oppi/Core/Views/DiffContentView.swift`
- `makeNumberedLines` and per-kind style mapping are pure transformations.
- Candidate extraction:
  - `DiffPresentationModel` (line numbers + style tokens)
- Why: useful for correctness tests (line-number alignment) without requiring UI snapshot tests.

## Suggested extraction order

1. `ContentView` permission coordinator
2. `SessionOutlineView` index/filter/summary pipeline
3. `SessionChangesView` indexer
4. `MessageQueueContainer` reducer
5. Composer state machine (shared between inline + expanded composer)

These are likely to move coverage from UI-heavy folders into enforceable logic layers without forcing brittle SwiftUI view tests.
