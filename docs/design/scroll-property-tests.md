# Scroll Invariant Property Tests — Design Document

**Status:** Design  
**Author:** Agent  
**Date:** 2026-03-02  
**Related:** TODO-ff1daa98

## Background

Scroll coordination in `ChatTimelineCollectionView` has had 3 bug fixes in the past week, each adding new state tracking:
- `lastObservedContentHeight` — tracks content height to detect growth
- `isTimelineBusy` — gates detached correction logic during active streaming
- `updateLastDistanceFromBottom` — maintains precise distance for hint visibility

The state space grows with each fix because scroll behaviors interact during edge cases (reloads during streaming, expand/collapse during scroll, background content growth while detached). Current tests validate specific behaviors but don't protect against invariant violations from future changes.

**Goal:** Define scroll invariants as testable properties, then write randomized/stress tests that verify them across many event sequences. Turn "did I break something?" from a manual exercise into a CI gate.

---

## Scroll Invariants (P1-P5)

### P1: Attached Stability
**Definition:**  
If the user has not scrolled away from the bottom (`isCurrentlyNearBottom == true`), they always see the latest content. Content growth (new messages, streaming deltas, tool output expansion) keeps them pinned to the bottom.

**Precise Assertion:**
```swift
func assertAttachedStability(
    _ collectionView: TimelineScrollMetricsCollectionView,
    _ scrollController: ChatScrollController
) {
    guard scrollController.isCurrentlyNearBottom else { return }
    
    let insets = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
    let maxOffsetY = max(-insets.top, collectionView.contentSize.height - visibleHeight)
    let actualOffsetY = collectionView.contentOffset.y
    let distanceFromBottom = maxOffsetY - actualOffsetY
    
    #expect(distanceFromBottom <= 2.0, 
            "attached user must stay within 2pt of bottom, got \(distanceFromBottom)pt")
}
```

**Violation Conditions:**
- Content grows but offsetY doesn't track → user sees stale viewport
- Offset correction skipped due to gating logic (`isTimelineBusy` check missing)

---

### P2: Detached Preservation
**Definition:**  
If the user has scrolled up (detached, `isCurrentlyNearBottom == false`), their viewport position is never changed by new content arriving. The content they're looking at stays in place.

**Precise Assertion:**
```swift
func assertDetachedPreservation(
    previousSnapshot: ScrollSnapshot,
    currentSnapshot: ScrollSnapshot,
    scrollController: ChatScrollController,
    event: TimelineEvent
) {
    guard !scrollController.isCurrentlyNearBottom else { return }
    guard event.isPassiveContentGrowth else { return }  // user scroll is allowed
    
    // For detached users, passive content growth must not move the viewport.
    // Allow 2pt tolerance for rounding (self-sizing height estimation).
    let offsetDelta = abs(currentSnapshot.contentOffsetY - previousSnapshot.contentOffsetY)
    
    #expect(offsetDelta <= 2.0,
            "detached user viewport moved \(offsetDelta)pt during passive growth (event: \(event))")
}
```

**Violation Conditions:**
- Streaming append increases contentSize → naive UIKit scrolls viewport up
- Detached correction logic bypassed due to collection view type checks
- Large programmatic jumps (>100pt) not corrected

---

### P3: Expand/Collapse Neutrality
**Definition:**  
Expanding or collapsing a tool row never moves the user's viewport when detached. The expansion/collapse adjusts the content offset to compensate for the height delta, keeping the user's relative scroll position stable.

**Precise Assertion:**
```swift
func assertExpandCollapseNeutrality(
    beforeSnapshot: ScrollSnapshot,
    afterSnapshot: ScrollSnapshot,
    expandedItemID: String,
    scrollController: ChatScrollController
) {
    guard !scrollController.isCurrentlyNearBottom else { return }
    
    // For detached users, expand/collapse must preserve distance from bottom.
    // The content size will change, but the viewport position relative to the
    // bottom of the content must stay stable (within 2pt tolerance for rounding).
    let beforeDistanceFromBottom = beforeSnapshot.contentSize.height - beforeSnapshot.contentOffsetY
    let afterDistanceFromBottom = afterSnapshot.contentSize.height - afterSnapshot.contentOffsetY
    let distanceDelta = abs(afterDistanceFromBottom - beforeDistanceFromBottom)
    
    #expect(distanceDelta <= 2.0,
            "expand/collapse moved detached viewport \(distanceDelta)pt from bottom (item: \(expandedItemID))")
}
```

**Rationale:**  
TimelineScrollMetricsCollectionView does not run real UIKit layout, so `layoutAttributesForItem(at:)` returns nil without a layout pass. Instead of comparing cell frames, we validate that the user's relative position in the scroll content stays stable by checking distance-from-bottom. This is the same metric existing scroll tests use (see `ScrollFollowBehaviorTests`).

**Violation Conditions:**
- Expand triggers snapshot reconfigure without offset compensation
- Detached correction fires but uses wrong previous offset baseline

---

### P4: Reload Continuity
**Definition:**  
A full timeline reload (history load, catch-up rebuild) preserves the user's scroll intent — attached stays attached at bottom, detached maintains distance from bottom.

**Precise Assertion:**
```swift
func assertReloadContinuity(
    beforeSnapshot: ScrollSnapshot,
    afterSnapshot: ScrollSnapshot,
    scrollController: ChatScrollController
) {
    let wasAttached = scrollController.isCurrentlyNearBottom
    
    if wasAttached {
        // Attached user must stay pinned to bottom after reload.
        let insets = afterSnapshot.adjustedContentInset
        let visibleHeight = afterSnapshot.bounds.height - insets.top - insets.bottom
        let maxOffsetY = max(-insets.top, afterSnapshot.contentSize.height - visibleHeight)
        let distanceFromBottom = maxOffsetY - afterSnapshot.contentOffsetY
        
        #expect(distanceFromBottom <= 2.0,
                "attached reload left user \(distanceFromBottom)pt from bottom")
    } else {
        // Detached user: preserve distance from bottom (allow up to 50pt drift
        // for content structure changes during reload).
        let beforeDistanceFromBottom = beforeSnapshot.contentSize.height - beforeSnapshot.contentOffsetY
        let afterDistanceFromBottom = afterSnapshot.contentSize.height - afterSnapshot.contentOffsetY
        let distanceDelta = abs(afterDistanceFromBottom - beforeDistanceFromBottom)
        
        #expect(distanceDelta <= 50.0,
                "detached reload changed distance from bottom by \(distanceDelta)pt")
    }
}
```

**Rationale:**  
Same as P3 — we use distance-from-bottom instead of cell frames because TimelineScrollMetricsCollectionView doesn't support real layout. For reloads, we allow a larger tolerance (50pt) because content structure can change (different item heights, hidden count changes).

**Violation Conditions:**
- Reload applies without triggering scroll command for attached users
- Detached user's offset not adjusted for new content structure

---

### P5: No Scroll Command Storms
**Definition:**  
The scroll command rate stays below 30/second. No infinite feedback loops between content size observation and scroll commands.

**Precise Assertion:**
```swift
final class ScrollCommandRateMonitor {
    private var commandTimestamps: [ContinuousClock.Instant] = []
    private let windowDuration: Duration = .seconds(1)
    private let maxCommandsPerSecond = 30
    
    func recordCommand() {
        commandTimestamps.append(ContinuousClock.now)
    }
    
    func assertNoStorm() {
        let now = ContinuousClock.now
        let cutoff = now.advanced(by: -windowDuration)
        commandTimestamps.removeAll { $0 < cutoff }
        
        #expect(commandTimestamps.count <= maxCommandsPerSecond,
                "scroll command storm: \(commandTimestamps.count) commands in 1s")
    }
}
```

**Violation Conditions:**
- `scrollViewDidScroll` triggers content apply → snapshot diff → more scroll events
- Throttle task cancellation/restart loop (debounce pattern instead of first-wins)

---

## Test Harness Architecture

### Core Infrastructure

```swift
@MainActor
struct ScrollPropertyTestHarness {
    let baseHarness: TimelineTestHarness
    let metricsView: TimelineScrollMetricsCollectionView
    
    var sessionId: String { baseHarness.sessionId }
    var coordinator: ChatTimelineCollectionHost.Controller { baseHarness.coordinator }
    var scrollController: ChatScrollController { baseHarness.scrollController }
    var reducer: TimelineReducer { baseHarness.reducer }
    var toolOutputStore: ToolOutputStore { baseHarness.toolOutputStore }
    var toolArgsStore: ToolArgsStore { baseHarness.toolArgsStore }
    var connection: ServerConnection { baseHarness.connection }
    var audioPlayer: AudioPlayerService { baseHarness.audioPlayer }
    
    var currentItems: [ChatItem]
    var currentStreamingID: String?
    var currentIsBusy: Bool
    
    // State tracking for invariant checks
    private(set) var scrollSnapshots: [ScrollSnapshot] = []
    private(set) var scrollCommandMonitor = ScrollCommandRateMonitor()
    
    init(sessionId: String, frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844)) {
        // Use existing makeTimelineHarness infrastructure for correct wiring
        self.baseHarness = makeTimelineHarness(sessionId: sessionId)
        
        // Wrap in TimelineScrollMetricsCollectionView for programmatic scroll control
        self.metricsView = TimelineScrollMetricsCollectionView(frame: frame)
        self.metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        
        self.currentItems = []
        self.currentStreamingID = nil
        self.currentIsBusy = false
    }
    
    mutating func captureSnapshot() -> ScrollSnapshot {
        let snapshot = ScrollSnapshot(
            contentOffsetY: metricsView.contentOffset.y,
            contentSize: metricsView.contentSize,
            adjustedContentInset: metricsView.adjustedContentInset,
            bounds: metricsView.bounds,
            isNearBottom: scrollController.isCurrentlyNearBottom,
            timestamp: ContinuousClock.now
        )
        scrollSnapshots.append(snapshot)
        return snapshot
    }
    
    mutating func applyEvent(_ event: TimelineEvent) {
        let beforeSnapshot = captureSnapshot()
        
        switch event {
        case .appendItems(let items):
            currentItems.append(contentsOf: items)
            applyConfiguration()
            
        case .scrollUp(let distance):
            simulateUserScroll(deltaY: -distance)
            
        case .scrollDown(let distance):
            simulateUserScroll(deltaY: distance)
            
        case .expandTool(let itemID):
            reducer.expandedItemIDs.insert(itemID)
            applyConfiguration()
            
        case .collapseTool(let itemID):
            reducer.expandedItemIDs.remove(itemID)
            applyConfiguration()
            
        case .fullReload(let newItems):
            currentItems = newItems
            applyConfiguration()
            
        case .startStreaming(let assistantID):
            currentStreamingID = assistantID
            currentIsBusy = true
            applyConfiguration()
            
        case .stopStreaming:
            currentStreamingID = nil
            currentIsBusy = false
            applyConfiguration()
            
        case .contentGrowth(let heightDelta):
            // Simulate passive layout growth (markdown reflow, image load)
            metricsView.testContentSize.height += heightDelta
            coordinator.scrollViewDidScroll(metricsView)
        }
        
        let afterSnapshot = captureSnapshot()
        
        // Run invariant checks
        checkInvariants(before: beforeSnapshot, after: afterSnapshot, event: event)
    }
    
    private func checkInvariants(
        before: ScrollSnapshot,
        after: ScrollSnapshot,
        event: TimelineEvent
    ) {
        // P1: Attached stability
        assertAttachedStability(metricsView, scrollController)
        
        // P2: Detached preservation
        assertDetachedPreservation(
            previousSnapshot: before,
            currentSnapshot: after,
            scrollController: scrollController,
            event: event
        )
        
        // P3: Expand/collapse neutrality
        if case .expandTool(let itemID) = event {
            assertExpandCollapseNeutrality(
                beforeSnapshot: before,
                afterSnapshot: after,
                expandedItemID: itemID,
                scrollController: scrollController
            )
        }
        if case .collapseTool(let itemID) = event {
            assertExpandCollapseNeutrality(
                beforeSnapshot: before,
                afterSnapshot: after,
                expandedItemID: itemID,
                scrollController: scrollController
            )
        }
        
        // P4: Reload continuity
        if case .fullReload = event {
            assertReloadContinuity(
                beforeSnapshot: before,
                afterSnapshot: after,
                scrollController: scrollController
            )
        }
        
        // P5: No scroll command storms
        scrollCommandMonitor.assertNoStorm()
    }
    
    private func simulateUserScroll(deltaY: CGFloat) {
        let beforeOffsetY = metricsView.contentOffset.y
        metricsView.testIsTracking = true
        coordinator.scrollViewWillBeginDragging(metricsView)
        
        metricsView.contentOffset.y = beforeOffsetY + deltaY
        coordinator.scrollViewDidScroll(metricsView)
        
        metricsView.testIsTracking = false
        coordinator.scrollViewDidEndDragging(metricsView, willDecelerate: false)
    }
    
    private func applyConfiguration() {
        let config = makeTimelineConfiguration(
            items: currentItems,
            isBusy: currentIsBusy,
            streamingAssistantID: currentStreamingID,
            sessionId: sessionId,
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )
        coordinator.apply(configuration: config, to: baseHarness.collectionView)
        scrollCommandMonitor.recordCommand()
    }
}
```

### Scroll State Snapshot

```swift
struct ScrollSnapshot {
    let contentOffsetY: CGFloat
    let contentSize: CGSize
    let adjustedContentInset: UIEdgeInsets
    let bounds: CGRect
    let isNearBottom: Bool
    let timestamp: ContinuousClock.Instant
}
```

### Timeline Event Types

```swift
enum TimelineEvent: Equatable, CustomStringConvertible {
    case appendItems([ChatItem])
    case scrollUp(distance: CGFloat)
    case scrollDown(distance: CGFloat)
    case expandTool(itemID: String)
    case collapseTool(itemID: String)
    case fullReload(newItems: [ChatItem])
    case startStreaming(assistantID: String)
    case stopStreaming
    case contentGrowth(heightDelta: CGFloat)
    
    var isPassiveContentGrowth: Bool {
        switch self {
        case .appendItems, .startStreaming, .stopStreaming, .contentGrowth:
            return true
        case .scrollUp, .scrollDown, .expandTool, .collapseTool, .fullReload:
            return false
        }
    }
    
    var description: String {
        switch self {
        case .appendItems(let items):
            return "appendItems(count: \(items.count))"
        case .scrollUp(let distance):
            return "scrollUp(\(distance)pt)"
        case .scrollDown(let distance):
            return "scrollDown(\(distance)pt)"
        case .expandTool(let id):
            return "expandTool(\(id))"
        case .collapseTool(let id):
            return "collapseTool(\(id))"
        case .fullReload(let items):
            return "fullReload(count: \(items.count))"
        case .startStreaming(let id):
            return "startStreaming(\(id))"
        case .stopStreaming:
            return "stopStreaming"
        case .contentGrowth(let delta):
            return "contentGrowth(\(delta)pt)"
        }
    }
}
```

---

## Randomized Event Generator

### Generator Architecture

```swift
struct TimelineEventGenerator {
    let seed: UInt64
    private var rng: SeededRandomNumberGenerator
    
    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.seed = seed
        self.rng = SeededRandomNumberGenerator(seed: seed)
    }
    
    /// Generate a random sequence of timeline events.
    /// Distribution:
    /// - 40% append items (streaming growth)
    /// - 20% scroll up/down (user interaction)
    /// - 15% expand/collapse tool (viewport disruption)
    /// - 10% full reload (history load, catch-up)
    /// - 10% start/stop streaming (busy state transitions)
    /// - 5% content growth (passive layout changes)
    mutating func generateSequence(count: Int) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        events.reserveCapacity(count)
        
        var currentItemCount = 5
        var currentStreamingID: String? = nil
        var expandedTools: Set<String> = []
        
        for _ in 0..<count {
            let roll = Double.random(in: 0..<1, using: &rng)
            
            let event: TimelineEvent
            switch roll {
            case 0..<0.4:  // 40% append items
                let appendCount = Int.random(in: 1...3, using: &rng)
                let items = makeRandomItems(count: appendCount, startIndex: currentItemCount)
                currentItemCount += appendCount
                event = .appendItems(items)
                
            case 0.4..<0.5:  // 10% scroll up
                let distance = CGFloat.random(in: 50...300, using: &rng)
                event = .scrollUp(distance: distance)
                
            case 0.5..<0.6:  // 10% scroll down
                let distance = CGFloat.random(in: 50...300, using: &rng)
                event = .scrollDown(distance: distance)
                
            case 0.6..<0.7:  // 10% expand tool
                let toolID = "tool-\(Int.random(in: 0..<currentItemCount, using: &rng))"
                expandedTools.insert(toolID)
                event = .expandTool(itemID: toolID)
                
            case 0.7..<0.75:  // 5% collapse tool
                if let toolID = expandedTools.randomElement(using: &rng) {
                    expandedTools.remove(toolID)
                    event = .collapseTool(itemID: toolID)
                } else {
                    event = .contentGrowth(heightDelta: 10)
                }
                
            case 0.75..<0.85:  // 10% full reload
                let newCount = Int.random(in: 3...currentItemCount, using: &rng)
                let items = makeRandomItems(count: newCount, startIndex: 0)
                event = .fullReload(newItems: items)
                
            case 0.85..<0.9:  // 5% start streaming
                if currentStreamingID == nil {
                    let id = "assistant-stream-\(currentItemCount)"
                    currentStreamingID = id
                    event = .startStreaming(assistantID: id)
                } else {
                    event = .appendItems(makeRandomItems(count: 1, startIndex: currentItemCount))
                    currentItemCount += 1
                }
                
            case 0.9..<0.95:  // 5% stop streaming
                if currentStreamingID != nil {
                    currentStreamingID = nil
                    event = .stopStreaming
                } else {
                    event = .appendItems(makeRandomItems(count: 1, startIndex: currentItemCount))
                    currentItemCount += 1
                }
                
            default:  // 5% content growth
                let heightDelta = CGFloat.random(in: 10...100, using: &rng)
                event = .contentGrowth(heightDelta: heightDelta)
            }
            
            events.append(event)
        }
        
        return events
    }
    
    private mutating func makeRandomItems(count: Int, startIndex: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        for i in 0..<count {
            let index = startIndex + i
            let roll = Double.random(in: 0..<1, using: &rng)
            
            let item: ChatItem
            switch roll {
            case 0..<0.3:
                item = .assistantMessage(
                    id: "assistant-\(index)",
                    text: "Response \(index)",
                    timestamp: Date()
                )
            case 0.3..<0.5:
                item = .userMessage(
                    id: "user-\(index)",
                    text: "Query \(index)",
                    images: [],
                    timestamp: Date()
                )
            case 0.5..<0.8:
                item = .toolCall(
                    id: "tool-\(index)",
                    tool: "bash",
                    argsSummary: "echo test-\(index)",
                    outputPreview: "test-\(index)",
                    outputByteCount: 64,
                    isError: false,
                    isDone: true
                )
            default:
                item = .systemEvent(
                    id: "system-\(index)",
                    message: "Event \(index)"
                )
            }
            items.append(item)
        }
        return items
    }
}

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        // Simple LCG for reproducible sequences
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
```

### Seed Control

```swift
@MainActor
@Test(arguments: [
    UInt64(0),
    UInt64(42),
    UInt64(1337),
    UInt64(9999),
    UInt64.random(in: 0...UInt64.max),
])
func propertyTestWithSeed(seed: UInt64) {
    var generator = TimelineEventGenerator(seed: seed)
    var harness = ScrollPropertyTestHarness(sessionId: "prop-test-\(seed)")
    
    let events = generator.generateSequence(count: 100)
    
    for event in events {
        harness.applyEvent(event)
    }
    
    // All invariants checked inside applyEvent
    // Test passes if no assertions fire
}
```

**Rationale for seeded RNG:**
- Reproducible failures: if a test fails with seed `42`, re-run with seed `42` to debug
- Regression tests: add failing seed to argument list to lock in fix
- Coverage diversity: multiple seeds explore different state space regions

---

## Test Method Signatures

### Randomized Property Tests

```swift
@Suite("Scroll invariant property tests")
struct ScrollInvariantPropertyTests {
    
    /// Randomized sequence: 100 events, 5 different seeds.
    /// Verifies all 5 properties hold across diverse event sequences.
    @MainActor
    @Test(arguments: [
        UInt64(0), UInt64(42), UInt64(1337), UInt64(9999), UInt64(12345)
    ])
    func allInvariantsHoldAcrossRandomSequence(seed: UInt64) {
        var generator = TimelineEventGenerator(seed: seed)
        var harness = ScrollPropertyTestHarness(sessionId: "prop-\(seed)")
        
        let events = generator.generateSequence(count: 100)
        for event in events {
            harness.applyEvent(event)
        }
    }
    
    /// Heavy timeline: 200+ items, verify performance-gated scroll paths.
    @MainActor
    @Test(arguments: [UInt64(100), UInt64(200)])
    func heavyTimelinePreservesInvariants(seed: UInt64) {
        var generator = TimelineEventGenerator(seed: seed)
        var harness = ScrollPropertyTestHarness(sessionId: "heavy-\(seed)")
        
        // Seed with 150 items
        let initialItems = (0..<150).map { i in
            ChatItem.assistantMessage(id: "msg-\(i)", text: "Content \(i)", timestamp: Date())
        }
        harness.applyEvent(.fullReload(newItems: initialItems))
        
        let events = generator.generateSequence(count: 80)
        for event in events {
            harness.applyEvent(event)
        }
    }
}
```

### Targeted Stress Tests

```swift
@Suite("Scroll stress scenarios")
struct ScrollStressTests {
    
    /// Rapid streaming while user scrolls up.
    /// Validates P2 (detached preservation) under high-frequency content growth.
    @MainActor
    @Test
    func rapidStreamingWhileScrolledUp() async {
        var harness = ScrollPropertyTestHarness(sessionId: "stress-stream")
        
        // User scrolls up 400pt
        harness.applyEvent(.scrollUp(distance: 400))
        #expect(!harness.scrollController.isCurrentlyNearBottom)
        
        // Start streaming
        harness.applyEvent(.startStreaming(assistantID: "stream-1"))
        
        // Simulate 30 rapid streaming deltas (33ms interval)
        for i in 0..<30 {
            harness.applyEvent(.appendItems([
                .assistantMessage(id: "delta-\(i)", text: "token \(i)", timestamp: Date())
            ]))
            try? await Task.sleep(for: .milliseconds(33))
        }
        
        // User must still be detached, viewport stable
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }
    
    /// Expand tool row at visible boundary during streaming.
    /// Validates P3 (expand/collapse neutrality) + P2 (detached preservation).
    @MainActor
    @Test
    func expandToolAtVisibleBoundaryDuringStreaming() async {
        var harness = ScrollPropertyTestHarness(sessionId: "stress-expand")
        
        // Seed timeline with 20 items
        let items = (0..<20).map { i in
            ChatItem.toolCall(
                id: "tool-\(i)",
                tool: "bash",
                argsSummary: "cmd \(i)",
                outputPreview: "out \(i)",
                outputByteCount: 256,
                isError: false,
                isDone: true
            )
        }
        harness.applyEvent(.fullReload(newItems: items))
        
        // User scrolls to middle
        harness.applyEvent(.scrollUp(distance: 600))
        
        // Start streaming
        harness.applyEvent(.startStreaming(assistantID: "stream-expand"))
        
        // Expand a tool row — P3 checks that distance from bottom stays stable
        harness.applyEvent(.expandTool(itemID: "tool-10"))
        
        // Continue streaming — viewport must stay stable (P2 detached preservation)
        for i in 0..<10 {
            harness.applyEvent(.appendItems([
                .assistantMessage(id: "stream-\(i)", text: "tok \(i)", timestamp: Date())
            ]))
        }
        
        // All invariants checked inside applyEvent
    }
    
    /// Full reload while detached at a specific item.
    /// Validates P4 (reload continuity).
    @MainActor
    @Test
    func fullReloadWhileDetachedAtSpecificItem() {
        var harness = ScrollPropertyTestHarness(sessionId: "stress-reload")
        
        // Seed timeline
        let items = (0..<30).map { i in
            ChatItem.assistantMessage(id: "msg-\(i)", text: "Content \(i)", timestamp: Date())
        }
        harness.applyEvent(.fullReload(newItems: items))
        
        // User scrolls up (detached)
        harness.applyEvent(.scrollUp(distance: 500))
        
        // Trigger full reload (history load simulation)
        let newItems = (0..<40).map { i in
            ChatItem.assistantMessage(id: "msg-\(i)", text: "Updated \(i)", timestamp: Date())
        }
        harness.applyEvent(.fullReload(newItems: newItems))
        
        // P4 checks that distance from bottom stays stable (within 50pt tolerance)
        // All invariants checked inside applyEvent
    }
    
    /// Background/foreground cycle during streaming with detached scroll.
    /// Validates that lifecycle transitions don't break P2.
    @MainActor
    @Test
    func backgroundForegroundCycleDuringDetachedStreaming() {
        var harness = ScrollPropertyTestHarness(sessionId: "stress-lifecycle")
        
        // User scrolls up, streaming active
        harness.applyEvent(.scrollUp(distance: 300))
        harness.applyEvent(.startStreaming(assistantID: "stream-bg"))
        
        // Simulate background transition: stop updating UI, but content still grows
        // (In real app, catchup would fire on foreground)
        for i in 0..<20 {
            harness.currentItems.append(
                .assistantMessage(id: "bg-\(i)", text: "background token \(i)", timestamp: Date())
            )
        }
        
        // Foreground: apply accumulated content
        harness.applyEvent(.fullReload(newItems: harness.currentItems))
        
        // User must still be detached, viewport stable
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }
}
```

---

## Test Coverage Map

### Complementary Test Strategies

The property tests and existing scroll tests serve **different validation strategies**:

**Existing ScrollFollowBehaviorTests (keep all 7 tests):**
- **Fast smoke tests:** ~1ms each, deterministic, precise assertions
- **Isolated behaviors:** Each test validates one specific scroll transition
- **Regression guards:** Catch exact-scenario regressions instantly

**New Property Tests:**
- **Randomized sequences:** ~800ms each, explore state space diversity
- **Invariant validation:** Check that properties hold across many event combinations
- **Stress scenarios:** Heavy timelines, rapid streaming, background/foreground cycles

**Decision:** Keep both test suites. Existing tests provide fast, precise coverage of known-fragile behaviors. Property tests add deeper validation across randomized event sequences and stress scenarios.

### Test Coverage Summary

| Property | Property Test Coverage | Existing Test Overlap | New Coverage |
|----------|----------------------|---------------------|--------------|
| P1: Attached stability | `allInvariantsHoldAcrossRandomSequence`, `heavyTimelinePreservesInvariants` | `nearBottomHysteresisKeepsFollowStableForSmallTailGrowth`, `attachedIdleLayoutGrowthPinsViewportToBottom` | Randomized sequences |
| P2: Detached preservation | `allInvariantsHoldAcrossRandomSequence`, `rapidStreamingWhileScrolledUp` | `upwardUserScrollDetachesFollowBeforeExitThreshold`, `smallUpwardScrollDetachSticksUntilDragEnds`, `busyToIdleTransitionDoesNotReattachDetachedUser` | Randomized sequences |
| P3: Expand/collapse neutrality | `allInvariantsHoldAcrossRandomSequence`, `expandToolAtVisibleBoundaryDuringStreaming` | None | Full coverage (new) |
| P4: Reload continuity | `allInvariantsHoldAcrossRandomSequence`, `fullReloadWhileDetachedAtSpecificItem` | None | Full coverage (new) |
| P5: No scroll command storms | `allInvariantsHoldAcrossRandomSequence`, `heavyTimelinePreservesInvariants` | None | Full coverage (new) |

**Net Impact:**
- 7 existing scroll tests kept (fast smoke tests)
- 5 new property tests added (randomized validation)
- 4 new stress tests added (edge case coverage)
- Total: 16 scroll tests (was 7)

---

## Performance Budget

**Target:** <10 seconds for full scroll test suite (property + existing) on CI (Mac mini M1, GitHub Actions).

### Time Breakdown

| Test Category | Test Count | Events/Test | Est. Time/Test | Total Time |
|---------------|-----------|-------------|----------------|------------|
| Existing scroll tests | 7 tests | N/A (deterministic) | ~1ms | 0.01s |
| Randomized property tests | 5 seeds | 100 events | 0.8s | 4.0s |
| Heavy timeline tests | 2 seeds | 80 events (150 item base) | 1.2s | 2.4s |
| Stress tests | 4 scenarios | 30-50 events | 0.4s | 1.6s |
| **Total** | **18 tests** | — | — | **8.0s** |

**Actual Budget:** 8.0s (20% safety margin)

**Rationale:** Existing tests are <1ms each (~0.01s total), negligible impact on overall budget.

### Performance Optimizations

1. **Avoid real layout passes:**
   - Use `TimelineScrollMetricsCollectionView` test doubles
   - Override `layoutIfNeeded()` to skip UIKit layout when not needed

2. **Batch invariant checks:**
   - Only run P1-P4 checks when relevant events occur
   - P5 (scroll command storm) checks once per test at end

3. **Disable animations:**
   - `UIView.setAnimationsEnabled(false)` in test setup

4. **Parallelize where possible:**
   - Swift Testing runs tests in parallel by default
   - Each seed gets its own harness → no shared state

5. **Cap event sequences:**
   - 100 events for random tests (sufficient coverage)
   - 80 events for heavy timelines (avoid O(n²) layout cost)

**Failure Mode:**
If suite exceeds 10s, first mitigation is to **reduce event counts** before adding complexity.

---

## Implementation Plan

### Phase 1: Test Infrastructure (2-3 hours)
1. Create `ScrollPropertyTestHarness` in `OppiTests/Timeline/ScrollPropertyTestSupport.swift`
   - Wrap existing `TimelineTestHarness` from `TimelineTestSupport.swift`
   - Add `TimelineScrollMetricsCollectionView` for programmatic scroll control
2. Define `ScrollSnapshot`, `TimelineEvent` (test-target only)
3. Implement `TimelineEventGenerator` with seeded RNG
4. Add `ScrollCommandRateMonitor` helper

### Phase 2: Invariant Assertion Helpers (1-2 hours)
1. Implement `assertAttachedStability(_:_:)` (test-target only)
2. Implement `assertDetachedPreservation(previousSnapshot:currentSnapshot:scrollController:event:)` (test-target only)
3. Implement `assertExpandCollapseNeutrality(beforeSnapshot:afterSnapshot:expandedItemID:scrollController:)` (test-target only)
   - Use distance-from-bottom assertion instead of cell frames
4. Implement `assertReloadContinuity(beforeSnapshot:afterSnapshot:scrollController:)` (test-target only)
   - Use distance-from-bottom assertion instead of cell frames
5. Implement `ScrollCommandRateMonitor.assertNoStorm()` (test-target only)

### Phase 3: Property Tests (1 hour)
1. Create `ScrollInvariantPropertyTests.swift`
2. Implement `allInvariantsHoldAcrossRandomSequence(seed:)`
3. Implement `heavyTimelinePreservesInvariants(seed:)`

### Phase 4: Stress Tests (2 hours)
1. Create `ScrollStressTests.swift`
2. Implement `rapidStreamingWhileScrolledUp()`
3. Implement `expandToolAtVisibleBoundaryDuringStreaming()`
4. Implement `fullReloadWhileDetachedAtSpecificItem()`
5. Implement `backgroundForegroundCycleDuringDetachedStreaming()`

### Phase 5: Integration & Validation (1 hour)
1. Run full suite, measure performance
2. Adjust event counts if needed to hit <10s budget
3. Verify existing `ScrollFollowBehaviorTests` still pass (keep all 7 tests)
4. Update `ARCHITECTURE.md` with property test documentation

**Total Estimated Time:** 7-9 hours

---

## Success Criteria

1. ✅ All 5 properties (P1-P5) have test coverage
2. ✅ Randomized test with 100+ event sequences passes
3. ✅ At least 4 targeted stress scenarios for known-fragile edge cases
4. ✅ Any future scroll fix that violates a property is caught by CI before merge
5. ✅ Full suite completes in <10 seconds on CI

---

## Decisions & Constraints

### D1: Harness wraps existing makeTimelineHarness()
**Decision:** `ScrollPropertyTestHarness` wraps `TimelineTestHarness` from `TimelineTestSupport.swift` instead of recreating coordinator/reducer/stores wiring. The existing infrastructure handles non-trivial plumbing (collection view data source, scroll controller coordination, tool store integration). Wrapping ensures property tests use the same setup as existing tests.

### D2: No cell-frame assertions
**Constraint:** `TimelineScrollMetricsCollectionView` does not run real UIKit layout, so `layoutAttributesForItem(at:)` returns nil. Existing scroll tests (`ScrollFollowBehaviorTests`) validate scroll correctness using `contentOffset` and `isCurrentlyNearBottom` only — no cell-frame assertions. Property tests follow the same pattern: P3 and P4 use distance-from-bottom assertions instead of cell-frame comparisons.

### D3: Test-target only protocols
**Decision:** All test-specific protocols (`ScrollStateQueries` was proposed but removed) and helpers stay in the test target. No test-only code in production sources. Invariant assertion functions are test-target helpers, not production extensions.

### D4: Keep existing scroll tests
**Decision:** Existing `ScrollFollowBehaviorTests` (7 tests, <1ms each) provide fast, deterministic smoke tests for known-fragile behaviors. Property tests (randomized, ~800ms each) add deeper validation. Both test suites are complementary — keep all tests.

### D5: Seed-based reproducibility
**Process for property test failures:**
1. Add failing seed to `@Test(arguments:)` list as regression test
2. Debug with that seed to reproduce
3. Fix the bug
4. Verify seed now passes
5. Keep seed in argument list to prevent regression

---

## References

- **Scroll Infrastructure:**
  - `ios/Oppi/Features/Chat/Timeline/ChatTimelineCollectionView.swift`
  - `ios/Oppi/Features/Chat/Session/ChatScrollController.swift`
  - `ios/Oppi/Features/Chat/Timeline/TimelineSnapshotApplier.swift`

- **Existing Tests:**
  - `ios/OppiTests/Timeline/ScrollFollowBehaviorTests.swift`
  - `ios/OppiTests/Chat/ChatTimelineCoordinatorTests.swift`

- **Test Harness:**
  - `ios/OppiTests/Support/TimelineTestSupport.swift`

- **TODO:** `TODO-ff1daa98` (this design document implements it)
