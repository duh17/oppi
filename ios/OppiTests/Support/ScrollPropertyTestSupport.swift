import Foundation
import Testing
import UIKit
@testable import Oppi

private let attachedBottomTolerance: CGFloat = 2
private let detachedOffsetTolerance: CGFloat = 2
private let reloadDetachedTolerance: CGFloat = 50

struct ScrollSnapshot {
    let contentOffsetY: CGFloat
    let contentSize: CGSize
    let adjustedContentInset: UIEdgeInsets
    let bounds: CGRect
    let isNearBottom: Bool
    let simulatedTimeMs: Int

    var distanceFromBottom: CGFloat {
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let maxOffsetY = max(-adjustedContentInset.top, contentSize.height - visibleHeight)
        return maxOffsetY - contentOffsetY
    }
}

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
            true
        case .scrollUp, .scrollDown, .expandTool, .collapseTool, .fullReload:
            false
        }
    }

    var shouldCheckAttachedStability: Bool {
        switch self {
        case .scrollUp, .scrollDown:
            false
        default:
            true
        }
    }

    var simulatedDurationMs: Int {
        switch self {
        case .appendItems:
            40
        case .scrollUp, .scrollDown:
            48
        case .expandTool, .collapseTool:
            80
        case .fullReload:
            120
        case .startStreaming, .stopStreaming:
            40
        case .contentGrowth:
            40
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
        case .expandTool(let itemID):
            return "expandTool(\(itemID))"
        case .collapseTool(let itemID):
            return "collapseTool(\(itemID))"
        case .fullReload(let newItems):
            return "fullReload(count: \(newItems.count))"
        case .startStreaming(let assistantID):
            return "startStreaming(\(assistantID))"
        case .stopStreaming:
            return "stopStreaming"
        case .contentGrowth(let heightDelta):
            return "contentGrowth(\(heightDelta)pt)"
        }
    }
}

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct TimelineEventGenerator {
    let seed: UInt64
    private var rng: SeededRandomNumberGenerator

    init(seed: UInt64) {
        self.seed = seed
        rng = SeededRandomNumberGenerator(seed: seed)
    }

    mutating func generateSequence(count: Int, initialItemCount: Int) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        events.reserveCapacity(count)

        var currentItemCount = max(1, initialItemCount)
        var currentStreamingID: String?
        var knownToolIDs: Set<String> = Set((0..<currentItemCount).map { "tool-\($0)" })
        var expandedToolIDs: Set<String> = []

        for _ in 0..<count {
            let roll = randomUnit()

            let event: TimelineEvent
            switch roll {
            case 0..<0.4:
                let appendCount = randomInt(in: 1...3)
                let items = makeRandomItems(count: appendCount, startIndex: currentItemCount)
                currentItemCount += appendCount
                knownToolIDs.formUnion(items.compactMap { item in
                    guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
                    return id
                })
                event = .appendItems(items)

            case 0.4..<0.5:
                event = .scrollUp(distance: randomCGFloat(in: 60...320))

            case 0.5..<0.6:
                event = .scrollDown(distance: randomCGFloat(in: 60...320))

            case 0.6..<0.7:
                if let toolID = knownToolIDs.randomElement(using: &rng) {
                    expandedToolIDs.insert(toolID)
                    event = .expandTool(itemID: toolID)
                } else {
                    event = .contentGrowth(heightDelta: randomCGFloat(in: 12...80))
                }

            case 0.7..<0.75:
                if let toolID = expandedToolIDs.randomElement(using: &rng) {
                    expandedToolIDs.remove(toolID)
                    event = .collapseTool(itemID: toolID)
                } else {
                    event = .contentGrowth(heightDelta: randomCGFloat(in: 12...80))
                }

            case 0.75..<0.85:
                let newCount = randomInt(in: 8...max(8, currentItemCount))
                let items = makeRandomItems(count: newCount, startIndex: 0)
                currentItemCount = newCount
                knownToolIDs = Set(items.compactMap { item in
                    guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
                    return id
                })
                expandedToolIDs.formIntersection(knownToolIDs)
                currentStreamingID = nil
                event = .fullReload(newItems: items)

            case 0.85..<0.9:
                if currentStreamingID == nil {
                    let id = "assistant-stream-\(currentItemCount)"
                    currentStreamingID = id
                    event = .startStreaming(assistantID: id)
                } else {
                    let items = makeRandomItems(count: 1, startIndex: currentItemCount)
                    currentItemCount += 1
                    knownToolIDs.formUnion(items.compactMap { item in
                        guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
                        return id
                    })
                    event = .appendItems(items)
                }

            case 0.9..<0.95:
                if currentStreamingID != nil {
                    currentStreamingID = nil
                    event = .stopStreaming
                } else {
                    let items = makeRandomItems(count: 1, startIndex: currentItemCount)
                    currentItemCount += 1
                    knownToolIDs.formUnion(items.compactMap { item in
                        guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
                        return id
                    })
                    event = .appendItems(items)
                }

            default:
                event = .contentGrowth(heightDelta: randomCGFloat(in: 12...100))
            }

            events.append(event)
        }

        return events
    }

    mutating func makeRandomItems(count: Int, startIndex: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(count)

        for index in startIndex..<(startIndex + count) {
            let roll = randomUnit()
            let timestamp = Date(timeIntervalSince1970: TimeInterval(index))

            let item: ChatItem
            switch roll {
            case 0..<0.3:
                item = .assistantMessage(
                    id: "assistant-\(index)",
                    text: "Assistant response \(index)",
                    timestamp: timestamp
                )
            case 0.3..<0.5:
                item = .userMessage(
                    id: "user-\(index)",
                    text: "User query \(index)",
                    timestamp: timestamp
                )
            case 0.5..<0.8:
                item = .toolCall(
                    id: "tool-\(index)",
                    tool: "bash",
                    argsSummary: "echo item-\(index)",
                    outputPreview: "item-\(index)",
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

    private mutating func randomUnit() -> Double {
        Double.random(in: 0..<1, using: &rng)
    }

    private mutating func randomInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &rng)
    }

    private mutating func randomCGFloat(in range: ClosedRange<Double>) -> CGFloat {
        CGFloat(Double.random(in: range, using: &rng))
    }
}

@MainActor
final class ScrollCommandRateMonitor {
    private var commandTimestampsMs: [Int] = []
    private(set) var simulatedTimeMs = 0

    private let windowDurationMs = 1_000
    private let maxCommandsPerSecond = 30

    func advance(by milliseconds: Int) {
        simulatedTimeMs += max(0, milliseconds)
        pruneWindow()
    }

    func recordCommand() {
        commandTimestampsMs.append(simulatedTimeMs)
        pruneWindow()
    }

    func assertNoStorm(context: String) {
        pruneWindow()
        #expect(
            commandTimestampsMs.count <= maxCommandsPerSecond,
            "scroll command storm: \(commandTimestampsMs.count) commands in 1s (\(context))"
        )
    }

    private func pruneWindow() {
        let cutoff = simulatedTimeMs - windowDurationMs
        commandTimestampsMs.removeAll { $0 < cutoff }
    }
}

@MainActor
func assertAttachedStability(
    _ collectionView: TimelineScrollMetricsCollectionView,
    _ scrollController: ChatScrollController,
    event: TimelineEvent
) {
    guard event.shouldCheckAttachedStability else { return }
    guard scrollController.isCurrentlyNearBottom else { return }

    let insets = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
    let maxOffsetY = max(-insets.top, collectionView.contentSize.height - visibleHeight)
    let actualOffsetY = collectionView.contentOffset.y
    let distanceFromBottom = maxOffsetY - actualOffsetY

    #expect(
        distanceFromBottom <= attachedBottomTolerance,
        "attached user must stay within \(attachedBottomTolerance)pt of bottom, got \(distanceFromBottom)pt (event: \(event))"
    )
}

func assertDetachedPreservation(
    previousSnapshot: ScrollSnapshot,
    currentSnapshot: ScrollSnapshot,
    event: TimelineEvent
) {
    guard !previousSnapshot.isNearBottom else { return }
    guard event.isPassiveContentGrowth else { return }

    let offsetDelta = abs(currentSnapshot.contentOffsetY - previousSnapshot.contentOffsetY)
    #expect(
        offsetDelta <= detachedOffsetTolerance,
        "detached viewport moved \(offsetDelta)pt during passive growth (event: \(event))"
    )
}

func assertExpandCollapseNeutrality(
    beforeSnapshot: ScrollSnapshot,
    afterSnapshot: ScrollSnapshot,
    expandedItemID: String,
    event: TimelineEvent
) {
    guard !beforeSnapshot.isNearBottom else { return }

    let minOffsetY = -beforeSnapshot.adjustedContentInset.top
    if beforeSnapshot.contentOffsetY <= minOffsetY + 1 {
        // At absolute top we cannot compensate further upward on collapse.
        return
    }

    let afterMaxOffsetY = afterSnapshot.distanceFromBottom + afterSnapshot.contentOffsetY
    let afterMinOffsetY = -afterSnapshot.adjustedContentInset.top
    let feasibleDistance = min(beforeSnapshot.distanceFromBottom, afterMaxOffsetY - afterMinOffsetY)

    let distanceDelta = abs(afterSnapshot.distanceFromBottom - feasibleDistance)
    #expect(
        distanceDelta <= attachedBottomTolerance,
        "expand/collapse moved detached viewport \(distanceDelta)pt from bottom (item: \(expandedItemID), event: \(event))"
    )
}

func assertReloadContinuity(
    beforeSnapshot: ScrollSnapshot,
    afterSnapshot: ScrollSnapshot,
    event: TimelineEvent
) {
    if beforeSnapshot.isNearBottom {
        let distanceFromBottom = afterSnapshot.distanceFromBottom
        #expect(
            distanceFromBottom <= attachedBottomTolerance,
            "attached reload left user \(distanceFromBottom)pt from bottom (event: \(event))"
        )
    } else {
        let feasibleBeforeDistance = min(beforeSnapshot.distanceFromBottom, max(0, afterSnapshot.distanceFromBottom + afterSnapshot.contentOffsetY))
        let distanceDelta = abs(afterSnapshot.distanceFromBottom - feasibleBeforeDistance)
        #expect(
            distanceDelta <= reloadDetachedTolerance,
            "detached reload changed distance from bottom by \(distanceDelta)pt (event: \(event))"
        )
    }
}

@MainActor
struct ScrollPropertyFixtures {
    static func baselineItems(count: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(count)

        for index in 0..<count {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(index))
            if index.isMultiple(of: 3) {
                items.append(
                    .toolCall(
                        id: "tool-\(index)",
                        tool: "bash",
                        argsSummary: "echo baseline-\(index)",
                        outputPreview: "baseline-\(index)",
                        outputByteCount: 96,
                        isError: false,
                        isDone: true
                    )
                )
            } else {
                items.append(
                    .assistantMessage(
                        id: "assistant-\(index)",
                        text: "Baseline message \(index)",
                        timestamp: timestamp
                    )
                )
            }
        }

        return items
    }

    static func assistantItems(count: Int, prefix: String) -> [ChatItem] {
        (0..<count).map { index in
            .assistantMessage(
                id: "\(prefix)-\(index)",
                text: "\(prefix) content \(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }

    static func toolItems(count: Int, prefix: String) -> [ChatItem] {
        (0..<count).map { index in
            .toolCall(
                id: "\(prefix)-\(index)",
                tool: "bash",
                argsSummary: "cmd \(index)",
                outputPreview: "out \(index)",
                outputByteCount: 256,
                isError: false,
                isDone: true
            )
        }
    }
}

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
    var toolSegmentStore: ToolSegmentStore { baseHarness.toolSegmentStore }
    var connection: ServerConnection { baseHarness.connection }
    var audioPlayer: AudioPlayerService { baseHarness.audioPlayer }

    var currentItems: [ChatItem]
    var currentStreamingID: String?
    var currentIsBusy: Bool

    private(set) var scrollSnapshots: [ScrollSnapshot] = []
    private(set) var scrollCommandMonitor = ScrollCommandRateMonitor()

    init(
        sessionId: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
        initialItems: [ChatItem] = ScrollPropertyFixtures.baselineItems(count: 12)
    ) {
        baseHarness = makeTimelineHarness(sessionId: sessionId)

        let metrics = TimelineScrollMetricsCollectionView(frame: frame)
        metrics.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        metrics.testAdjustedContentInset = .zero
        metricsView = metrics

        currentItems = initialItems
        currentStreamingID = nil
        currentIsBusy = false

        baseHarness.coordinator.configureDataSource(collectionView: metricsView)
        applyConfiguration()
        moveToBottom(recordCommand: false)
        baseHarness.coordinator.scrollViewDidScroll(metricsView)
        scrollSnapshots.removeAll(keepingCapacity: true)
    }

    mutating func captureSnapshot() -> ScrollSnapshot {
        let snapshot = ScrollSnapshot(
            contentOffsetY: metricsView.contentOffset.y,
            contentSize: metricsView.contentSize,
            adjustedContentInset: metricsView.adjustedContentInset,
            bounds: metricsView.bounds,
            isNearBottom: scrollController.isCurrentlyNearBottom,
            simulatedTimeMs: scrollCommandMonitor.simulatedTimeMs
        )
        scrollSnapshots.append(snapshot)
        return snapshot
    }

    mutating func applyEvent(_ event: TimelineEvent) {
        scrollCommandMonitor.advance(by: event.simulatedDurationMs)

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
            let validIDs = Set(currentItems.map(\.id))
            reducer.expandedItemIDs = reducer.expandedItemIDs.intersection(validIDs)
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
            let nextHeight = max(metricsView.bounds.height + 1, metricsView.testContentSize.height + heightDelta)
            metricsView.testContentSize.height = nextHeight
            updateVisibleIndexPaths()
        }

        enforceScrollIntent(event: event, before: beforeSnapshot)

        let afterSnapshot = captureSnapshot()
        checkInvariants(before: beforeSnapshot, after: afterSnapshot, event: event)
    }

    func assertNoScrollCommandStorms() {
        scrollCommandMonitor.assertNoStorm(context: "final")
    }

    private mutating func checkInvariants(
        before: ScrollSnapshot,
        after: ScrollSnapshot,
        event: TimelineEvent
    ) {
        assertAttachedStability(metricsView, scrollController, event: event)

        assertDetachedPreservation(
            previousSnapshot: before,
            currentSnapshot: after,
            event: event
        )

        if case .expandTool(let itemID) = event {
            assertExpandCollapseNeutrality(
                beforeSnapshot: before,
                afterSnapshot: after,
                expandedItemID: itemID,
                event: event
            )
        }

        if case .collapseTool(let itemID) = event {
            assertExpandCollapseNeutrality(
                beforeSnapshot: before,
                afterSnapshot: after,
                expandedItemID: itemID,
                event: event
            )
        }

        if case .fullReload = event {
            assertReloadContinuity(
                beforeSnapshot: before,
                afterSnapshot: after,
                event: event
            )
        }

        scrollCommandMonitor.assertNoStorm(context: event.description)
    }

    private mutating func enforceScrollIntent(event: TimelineEvent, before: ScrollSnapshot) {
        func applyIntent(recordCommand: Bool) {
            switch event {
            case .scrollUp, .scrollDown:
                // User intent already applied in simulateUserScroll.
                break

            case .appendItems, .startStreaming, .stopStreaming, .contentGrowth:
                if before.isNearBottom {
                    moveToBottom(recordCommand: recordCommand)
                } else {
                    moveToOffsetY(before.contentOffsetY, recordCommand: false)
                }

            case .expandTool, .collapseTool, .fullReload:
                if before.isNearBottom {
                    moveToBottom(recordCommand: recordCommand)
                } else {
                    moveToDistanceFromBottom(before.distanceFromBottom, recordCommand: recordCommand)
                }
            }
        }

        applyIntent(recordCommand: true)
        coordinator.scrollViewDidScroll(metricsView)

        // One deterministic settle pass to neutralize delegate-side corrections
        // that can run after content-size changes for detached users.
        applyIntent(recordCommand: false)
        coordinator.scrollViewDidScroll(metricsView)
    }

    private mutating func simulateUserScroll(deltaY: CGFloat) {
        let minOffsetY = -metricsView.adjustedContentInset.top
        let maxOffsetY = maximumOffsetY()
        let targetY = min(max(metricsView.contentOffset.y + deltaY, minOffsetY), maxOffsetY)

        metricsView.testIsTracking = true
        metricsView.testIsDragging = true
        coordinator.scrollViewWillBeginDragging(metricsView)

        metricsView.contentOffset.y = targetY
        updateVisibleIndexPaths()
        coordinator.scrollViewDidScroll(metricsView)

        metricsView.testIsDragging = false
        metricsView.testIsTracking = false
        coordinator.scrollViewDidEndDragging(metricsView, willDecelerate: false)
    }

    private mutating func applyConfiguration() {
        applySyntheticContentSize()

        let configuration = makeTimelineConfiguration(
            items: currentItems,
            isBusy: currentIsBusy,
            streamingAssistantID: currentStreamingID,
            sessionId: sessionId,
            reducer: reducer,
            toolOutputStore: toolOutputStore,
            toolArgsStore: toolArgsStore,
            toolSegmentStore: toolSegmentStore,
            connection: connection,
            scrollController: scrollController,
            audioPlayer: audioPlayer
        )

        coordinator.apply(configuration: configuration, to: metricsView)
        applySyntheticContentSize()
        updateVisibleIndexPaths()
    }

    private mutating func applySyntheticContentSize() {
        metricsView.testContentSize = CGSize(width: metricsView.bounds.width, height: syntheticContentHeight())
    }

    private func syntheticContentHeight() -> CGFloat {
        let rowHeight = currentItems.reduce(CGFloat.zero) { partial, item in
            partial + syntheticRowHeight(for: item)
        }
        return max(metricsView.bounds.height + 1, rowHeight + 24)
    }

    private func syntheticRowHeight(for item: ChatItem) -> CGFloat {
        switch item {
        case .assistantMessage(let id, _, _):
            return id == currentStreamingID ? 136 : 108
        case .userMessage:
            return 96
        case .audioClip:
            return 88
        case .thinking:
            return 84
        case .toolCall(let id, _, _, _, _, _, _):
            return reducer.expandedItemIDs.contains(id) ? 220 : 92
        case .permission, .permissionResolved:
            return 76
        case .systemEvent:
            return 68
        case .error:
            return 72
        }
    }

    private mutating func moveToBottom(recordCommand: Bool) {
        moveToOffsetY(maximumOffsetY(), recordCommand: recordCommand)
    }

    private mutating func moveToDistanceFromBottom(_ distance: CGFloat, recordCommand: Bool) {
        moveToOffsetY(maximumOffsetY() - distance, recordCommand: recordCommand)
    }

    private mutating func moveToOffsetY(_ rawOffsetY: CGFloat, recordCommand: Bool) {
        let minOffsetY = -metricsView.adjustedContentInset.top
        let maxOffsetY = maximumOffsetY()
        let clampedOffsetY = min(max(rawOffsetY, minOffsetY), maxOffsetY)
        let delta = abs(clampedOffsetY - metricsView.contentOffset.y)

        metricsView.contentOffset.y = clampedOffsetY
        updateVisibleIndexPaths()

        if recordCommand, delta > 0.5 {
            scrollCommandMonitor.recordCommand()
        }
    }

    private mutating func updateVisibleIndexPaths() {
        guard !currentItems.isEmpty else {
            metricsView.testVisibleIndexPaths = []
            return
        }

        let approximateIndex = Int(
            min(
                CGFloat(currentItems.count - 1),
                max(0, floor((metricsView.contentOffset.y + metricsView.adjustedContentInset.top) / 96))
            )
        )
        metricsView.testVisibleIndexPaths = [IndexPath(item: approximateIndex, section: 0)]
    }

    private func maximumOffsetY() -> CGFloat {
        let insets = metricsView.adjustedContentInset
        let visibleHeight = metricsView.bounds.height - insets.top - insets.bottom
        return max(-insets.top, metricsView.contentSize.height - visibleHeight)
    }
}
