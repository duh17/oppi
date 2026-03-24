# Test Support Code Audit

Audited 2026-03-23 after consolidation refactors (themeID removal, isReentry removal,
anotherSessionTookOver removal, TimelineInteractionContext introduction, TestEventPipeline extraction).

## Dead Code (0 external references — safe to delete)

### ScrollPropertyTestSupport.swift

| Symbol | Lines | Notes |
|--------|-------|-------|
| `ScrollSnapshot` | 7-19 | Only referenced internally by `ScrollPropertyTestHarness` |
| `SeededRandomNumberGenerator` | 102-112 | Only referenced internally by `TimelineEventGenerator` |
| `ScrollCommandRateMonitor` | 239-261 | Only referenced internally by `ScrollPropertyTestHarness` |
| `assertAttachedStability()` | 263-278 | Only called from `ScrollPropertyTestHarness.checkInvariants()` |
| `assertDetachedPreservation()` | 280-293 | Only called from `ScrollPropertyTestHarness.checkInvariants()` |
| `assertExpandCollapseNeutrality()` | 295-316 | Only called from `ScrollPropertyTestHarness.checkInvariants()` |
| `assertReloadContinuity()` | 318-339 | Only called from `ScrollPropertyTestHarness.checkInvariants()` |

> These are all **internal** to `ScrollPropertyTestHarness` — no test file calls them directly.
> They are transitively live through the harness. Marking as **internally used, not independently dead**.
> Reclassified below under Healthy.

### ServerConnectionScenarioSupport.swift

| Symbol | Lines | Notes |
|--------|-------|-------|
| `AckCommand` (private enum) | 188-213 | Private, never called within the file. Duplicated in `ServerConnectionTests.swift` and `ServerConnectionRoutingTests.swift`. Dead. |
| `AckRequest` (private struct) | 214-219 | Private, never called within the file. Dead. |
| `extractAckRequest()` (private) | 220-231 | Private, never called within the file. Dead. |
| `makeAckTestConnection()` (private) | 234-244 | Private, never called within the file. Dead. |
| `AckStageRecorder` (private actor) | 246-260 | Private, never called within the file. Dead. |
| `ScenarioTimelineItemKind` | 180-186 | Not referenced outside this file. Only used by `ServerConnectionScenario.timelineItemCount(of:)`. Tests use it via the scenario but import the enum indirectly. See note below. |

> `ScenarioTimelineItemKind` **is** used: tests call `scenario.timelineItemCount(of: .assistantMessage)` etc.
> The enum must be visible for those call sites. Reclassified under Healthy.
>
> The 5 private `Ack*` symbols (55 lines) are genuinely dead. They were likely left behind when
> ack tests moved to `ServerConnectionTests.swift` / `ServerConnectionSendAckTests.swift` with
> their own local copies.

**Total dead lines: ~55 (private Ack helpers in ServerConnectionScenarioSupport.swift)**

## Rarely Used (1 external reference — candidates for inlining)

| Symbol | File | Refs | Used by |
|--------|------|------|---------|
| `TimelineFetchProbe` | TimelineTestSupport.swift | 2 | `ToolOutputFetchTests.swift` only |
| `timelineOffsetY(forDistanceFromBottom:in:)` | TimelineTestSupport.swift | 10 | `ScrollFollowBehaviorTests.swift` only |
| `fittedTimelineSizeWithoutPrelayout()` | TimelineTestSupport.swift | 2 | `ToolRowContentViewTests.swift` only |
| `waitForMainActorConditionToStayTrue()` | TestWaiters.swift | 1 | `ScrollFollowBehaviorTests.swift` only |
| `MessageCounter` | TestDoubles.swift | 2 | `ServerConnectionReconnectTests.swift` only |
| `timelineDuplicateIDs()` | TimelineTestSupport.swift | 1 | `ToolExpandScrollMatrixTests.swift` (also used internally by streaming matrix support) |
| `timelineToolRowCount()` | TimelineTestSupport.swift | 0 direct | Only used internally by `TimelineStreamingScrollMatrixSupport.swift` |

> None of these are urgent inlining candidates — each is small and supports a specific test domain.
> `timelineToolRowCount` is used only transitively through `TimelineStreamingScrollScenarioRunner`.

## Stale Patterns (reference removed or migrating concepts)

### `makeTimelineToolConfiguration()` — selectedTextPiRouter/selectedTextSessionId params

**File:** `TimelineTestSupport.swift` lines 551-593

The factory still accepts `selectedTextPiRouter` and `selectedTextSessionId` as direct parameters
and threads them into `ToolTimelineRowConfiguration`. Production code still carries these fields
on `ToolTimelineRowConfiguration`, so the factory is **not broken**. However, the broader migration
toward `TimelineInteractionContext` (which now holds `selectedTextPiRouter` on the collection
controller context) means this threading pattern is on borrowed time.

**12 call sites** still pass `selectedTextPiRouter:` through the factory across 6 test files.
These will need updating when the remaining row configurations drop the direct params.

**Action:** No change now. When `ToolTimelineRowConfiguration` drops `selectedTextPiRouter`/
`selectedTextSessionId`, update this factory and all 12 call sites simultaneously.

### No stale references found for:
- `themeID` — already fully removed from support files
- `isReentry` — not present in any support file
- `anotherSessionTookOver` — not present in any support file

## Healthy (widely used — leave alone)

### TimelineTestSupport.swift (648 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `timelineAllLabels()` | 4 refs, 2 files | Healthy |
| `timelineAllViews()` | 5 refs, 2 files | Healthy |
| `timelineAllTextViews()` | 20+ refs, 6 files | Core utility |
| `timelineAllTextRenderViews()` | 5 refs, 2 files | Healthy |
| `timelineFirstTextView()` | 6 refs, 2 files | Healthy |
| `timelineFirstView(ofType:in:)` | 19+ refs, 5 files | Core utility |
| `timelineAllImageViews()` | 5 refs, 1 file | Healthy |
| `timelineAllGestureRecognizers()` | 5 refs, 3 files | Healthy |
| `assertHasDoubleTapGesture()` | 1 ref, 1 file | Low use but clean |
| `timelineAllScrollViews()` | 8 refs, 5 files | Healthy |
| `timelineRenderedText()` | 30+ refs, 7 files | Core utility |
| `timelineActionTitles()` | 10 refs, 3 files | Healthy |
| `TimelineScrollMetricsCollectionView` | 7 refs, 1 file (+internal) | Healthy |
| `TimelineTestHarness` | 1 ref + internal | Structural (used by harness factories) |
| `WindowedTimelineHarness` | 37 refs, 6+ files | Core harness |
| `makeTimelineHarness()` | 20+ refs, 2 files | Core factory |
| `makeWindowedTimelineHarness()` | 20+ refs, 6 files | Core factory |
| `makeTimelineConfiguration()` | 48 refs, 4+ files | Core factory |
| `configuredTimelineCell()` | 14 refs, 1 file | Healthy |
| `expectTimelineRowsUseConfigurationType()` | 3 refs, 1 file | Healthy |
| `settleTimelineLayout()` | 10+ refs, 1 file (+internal) | Healthy |
| `waitForTimelineCondition()` | 10 refs, 2 files | Healthy |
| `makeTimelineToolConfiguration()` | 87 refs, 7 files | Core factory (see stale note) |
| `makeTimelineAssistantConfiguration()` | 8 refs, 1 file | Healthy |
| `fittedTimelineSize()` | 20+ refs, 2 files | Healthy |

### ScrollPropertyTestSupport.swift (749 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `TimelineEvent` | 0 direct, internal | Structural (event type for harness) |
| `TimelineEventGenerator` | 2 refs, 1 file | Healthy |
| `ScrollPropertyFixtures` | 9 refs, 2 files | Healthy |
| `ScrollPropertyTestHarness` | 5 refs, 2 files | Healthy |

> All internal helpers (`ScrollSnapshot`, `SeededRandomNumberGenerator`, `ScrollCommandRateMonitor`,
> assert functions) are transitively live through `ScrollPropertyTestHarness`. Not dead.

### TimelineStreamingScrollMatrixSupport.swift (517 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `TimelineStreamingScrollMatrixCase` | 2 refs, 1 file | Healthy (parameterized test) |
| `TimelineStreamingScrollScenarioRunner` | 2 refs, 1 file | Healthy |
| `TimelineStreamingContentKind` | 2 refs, 1 file | Healthy |
| `TimelineStreamingPhase` | 2 refs, 1 file | Healthy |

### ToolExpandScrollMatrixSupport.swift (512 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `ToolExpandScrollMatrixCase` | 7 refs, 1 file | Healthy (parameterized test) |
| `ToolExpandScrollMatrixFixture` | 5 refs, 1 file | Healthy |

### ServerConnectionScenarioSupport.swift (260 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `ServerConnectionScenario` | 7 refs, 3 files | Healthy |
| `ScenarioTimelineItemKind` | (used via scenario methods) | Healthy |

### VoiceTestDoubles.swift (193 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `MockVoiceInputSystemAccess` | 10+ refs, 2 files | Healthy |
| `MockVoiceProvider` | 10+ refs, 2 files | Healthy |
| `MockVoiceSession` | 10+ refs, 2 files | Healthy |
| `AsyncGate` | 3 refs, 3 files | Healthy |
| `TestVoiceError` | 4 refs, 2 files | Healthy |

### TestEventPipeline.swift (158 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `TestEventPipeline` | 20+ refs, 5+ files | Core infrastructure |

### TestFactories.swift (110 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `makeTestSession()` | 30+ refs, 5+ files | Core factory |
| `makeTestConnection()` | 30+ refs, 5+ files | Core factory |
| `makeTestCredentials()` | 20+ refs, 8+ files | Core factory |
| `makeTestPermission()` | 10 refs, 1 file | Healthy |
| `makeTestWorkspace()` | 20+ refs, 4 files | Core factory |

### TestDoubles.swift (80 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `TestURLProtocol` | 6 refs, 4 files | Healthy |
| `ScriptedStreamFactory` | 15+ refs, 5 files | Healthy |

### TestWaiters.swift (69 lines)

| Symbol | External refs | Verdict |
|--------|--------------|---------|
| `waitForTestCondition()` | 30+ refs, 6+ files | Core utility |
| `waitForMainActorCondition()` | 12 refs, 4 files | Healthy |

## Summary

| Category | Lines | Action |
|----------|-------|--------|
| Dead (private Ack helpers) | ~55 | Delete from `ServerConnectionScenarioSupport.swift` |
| Stale pattern (selectedTextPiRouter threading) | ~40 | Update when production drops the fields |
| Rarely used | ~50 | Leave; small and domain-specific |
| Healthy | ~3,150 | Leave alone |

The test support codebase is in good shape. The only dead code is 5 private helper types
in `ServerConnectionScenarioSupport.swift` (~55 lines) that are orphaned copies of ack-test
infrastructure now defined locally in the actual test files.
