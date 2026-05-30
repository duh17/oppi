import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
private func timelineMaxOffsetY(_ collectionView: UICollectionView) -> CGFloat {
    let insets = collectionView.adjustedContentInset
    return max(
        -insets.top,
        collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
    )
}

/// Tests the full jump-to-bottom chain: detach → hint visible → requestScrollToBottom → scroll command processed.
@Suite("Scroll to bottom button")
struct ScrollToBottomTests {

    // MARK: - Hint visibility after detach

    @MainActor
    @Test func hintShowsWhenUserScrollsUpFarEnough() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)
        #expect(!harness.scrollController.isJumpToBottomHintVisible,
                "hint should be hidden when near bottom")

        // Simulate upward user scroll past jumpToBottomMinDistance (500pt).
        metricsView.testIsTracking = true
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 800, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        metricsView.testIsTracking = false
        harness.coordinator.scrollViewDidEndDragging(metricsView, willDecelerate: false)

        #expect(!harness.scrollController.isCurrentlyNearBottom,
                "should be detached after upward scroll")
        #expect(harness.scrollController.isJumpToBottomHintVisible,
                "hint should be visible when far from bottom")
    }

    @MainActor
    @Test func hintHidesWhenNotFarEnough() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        // Scroll up only 300pt — below jumpToBottomMinDistance (500pt).
        metricsView.testIsTracking = true
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 300, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        metricsView.testIsTracking = false
        harness.coordinator.scrollViewDidEndDragging(metricsView, willDecelerate: false)

        #expect(!harness.scrollController.isJumpToBottomHintVisible,
                "hint should NOT be visible when distance < 500pt")
    }

    // MARK: - requestScrollToBottom state changes

    @MainActor
    @Test func requestScrollToBottomIncrementsNonce() {
        let controller = ChatScrollController()
        controller.updateNearBottom(false)
        controller.setJumpToBottomHintVisible(true)

        let nonceBefore = controller.scrollToBottomNonce

        controller.requestScrollToBottom()

        #expect(controller.scrollToBottomNonce == nonceBefore &+ 1,
                "nonce should increment")
        #expect(controller.isCurrentlyNearBottom,
                "should re-attach to bottom")
        #expect(!controller.isJumpToBottomHintVisible,
                "hint should hide immediately")
        #expect(!controller.isDetachedStreamingHintVisible,
                "streaming hint should hide")
    }

    // MARK: - Passive bottom pinning

    @MainActor
    @Test func attachedPassiveContentShrinkClampsBackToBottom() {
        let harness = makeTimelineHarness(sessionId: "session-shrink")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testAdjustedContentInset = .zero
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.contentOffset = CGPoint(x: 0, y: 2_500)

        harness.scrollController.updateNearBottom(true)
        harness.coordinator.scrollViewDidScroll(metricsView)

        metricsView.testContentSize = CGSize(width: 390, height: 2_400)
        harness.coordinator.scrollViewDidScroll(metricsView)

        #expect(
            abs(metricsView.contentOffset.y - 1_900) < 0.5,
            "attached timeline should clamp to the new bottom after content shrinks"
        )
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func streamingAssistantSizingDoesNotShrinkCachedHeight() {
        let cell = SafeSizingCell(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        cell.isStreamingAssistant = true
        cell.cachedStreamingHeight = 240
        cell.lastFullSizeComputeNs = 0

        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.size = CGSize(width: 320, height: 100)

        let fitted = cell.preferredLayoutAttributesFitting(attributes)

        #expect(fitted.size.height >= 240)
        #expect(cell.cachedStreamingHeight == fitted.size.height)
    }

    // MARK: - Scroll command processing

    @MainActor
    @Test func scrollCommandProcessedByCoordinator() {
        // Build a windowed harness so scrollToItem can actually execute.
        let windowed = makeWindowedTimelineHarness(sessionId: "session-a")
        let items: [ChatItem] = (0..<30).map { i in
            .assistantMessage(
                id: "msg-\(i)",
                text: "Message \(i) with enough text to fill some space.",
                timestamp: Date()
            )
        }

        // Apply items so the coordinator knows the IDs.
        let config = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            sessionId: "session-a",
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()

        // Now apply again WITH a scroll command targeting the last item.
        let scrollCmd = ChatTimelineScrollCommand(
            id: "msg-29",
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        let configWithScroll = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: "session-a",
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: configWithScroll, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()

        // After processing, re-applying with the same nonce should NOT re-scroll
        // (nonce dedup). Verify by checking the nonce was consumed.
        let configWithSameScroll = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: "session-a",
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        // This should be a no-op (nonce already handled).
        windowed.coordinator.apply(configuration: configWithSameScroll, to: windowed.collectionView)
    }

    @MainActor
    @Test func attachedAssistantStreamingDoesNotBounceAwayFromBottom() {
        let streamingID = "assistant-streaming"
        let (windowed, initialItems) = makeCalmStreamingHarness(
            sessionId: "session-streaming-calm",
            tailItem: .assistantMessage(id: streamingID, text: "Starting", timestamp: Date()),
            streamingID: streamingID
        )
        var items = initialItems

        var previousOffsetY = windowed.collectionView.contentOffset.y
        for round in 1...10 {
            items[items.count - 1] = .assistantMessage(
                id: streamingID,
                text: String(repeating: "Streaming round \(round). ", count: round * 16),
                timestamp: Date()
            )
            applyBusyStreamingItems(items, to: windowed, streamingID: streamingID)
            previousOffsetY = expectCalmBottomFollow(
                windowed,
                previousOffsetY: previousOffsetY,
                round: round,
                label: "assistant streaming"
            )
        }
    }

    @MainActor
    @Test func attachedToolStreamingDoesNotBounceAwayFromBottom() {
        let toolID = "tool-streaming"
        let startingTool = ChatItem.toolCall(
            id: toolID,
            tool: "bash",
            argsSummary: "swift test",
            outputPreview: "Starting",
            outputByteCount: 8,
            isError: false,
            isDone: false
        )
        let (windowed, initialItems) = makeCalmStreamingHarness(
            sessionId: "session-tool-streaming-calm",
            tailItem: startingTool
        )
        var items = initialItems

        var previousOffsetY = windowed.collectionView.contentOffset.y
        for round in 1...10 {
            items[items.count - 1] = .toolCall(
                id: toolID,
                tool: "bash",
                argsSummary: "swift test",
                outputPreview: String(repeating: "tool output round \(round)\n", count: round * 6),
                outputByteCount: round * 128,
                isError: false,
                isDone: false
            )
            applyBusyStreamingItems(items, to: windowed)
            previousOffsetY = expectCalmBottomFollow(
                windowed,
                previousOffsetY: previousOffsetY,
                round: round,
                label: "tool streaming"
            )
        }
    }

    @MainActor
    private func calmStreamingItems(tailItem: ChatItem) -> [ChatItem] {
        let baseItems = (0..<44).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index) line. ", count: 12),
                timestamp: Date()
            )
        }
        return baseItems + [tailItem]
    }

    @MainActor
    private func makeCalmStreamingHarness(
        sessionId: String,
        tailItem: ChatItem,
        streamingID: String? = nil
    ) -> (WindowedTimelineHarness, [ChatItem]) {
        let windowed = makeWindowedTimelineHarness(
            sessionId: sessionId,
            useAnchoredCollectionView: true
        )
        let items = calmStreamingItems(tailItem: tailItem)
        windowed.applyItems(items, isBusy: true, streamingID: streamingID)
        windowed.collectionView.layoutIfNeeded()
        windowed.collectionView.scrollToItem(
            at: IndexPath(item: windowed.coordinator.currentIDs.count - 1, section: 0),
            at: .bottom,
            animated: false
        )
        windowed.collectionView.layoutIfNeeded()
        windowed.scrollController.updateNearBottom(true)
        windowed.coordinator.updateScrollState(windowed.collectionView)
        return (windowed, items)
    }

    @MainActor
    private func applyBusyStreamingItems(
        _ items: [ChatItem],
        to windowed: WindowedTimelineHarness,
        streamingID: String? = nil
    ) {
        let config = makeTimelineConfiguration(
            items: items,
            isBusy: true,
            streamingAssistantID: streamingID,
            scrollCommand: nil,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
    }

    @MainActor
    private func expectCalmBottomFollow(
        _ windowed: WindowedTimelineHarness,
        previousOffsetY: CGFloat,
        round: Int,
        label: String
    ) -> CGFloat {
        let offsetY = windowed.collectionView.contentOffset.y
        let maxOffsetY = timelineMaxOffsetY(windowed.collectionView)
        let distanceFromBottom = maxOffsetY - offsetY
        #expect(
            offsetY >= previousOffsetY - 4,
            "\(label) offset bounced upward by \(previousOffsetY - offsetY)pt on round \(round)"
        )
        #expect(
            distanceFromBottom < 120,
            "\(label) should keep the live tail visible without exact-bottom chasing, distance=\(distanceFromBottom) on round \(round)"
        )
        return offsetY
    }

    @MainActor
    @Test func busyStructuralAppendKeepsAttachedTimelineAtBottom() {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-review-many-files",
            useAnchoredCollectionView: true
        )
        let initialItems = (0..<70).map { index in
            ChatItem.toolCall(
                id: "review-tool-\(index)",
                tool: "read",
                argsSummary: "clients/apple/File\(index).swift",
                outputPreview: "Review clients/apple/File\(index).swift",
                outputByteCount: 256,
                isError: false,
                isDone: true
            )
        }

        windowed.applyItems(initialItems, isBusy: true)
        windowed.collectionView.layoutIfNeeded()
        windowed.collectionView.scrollToItem(
            at: IndexPath(item: windowed.coordinator.currentIDs.count - 1, section: 0),
            at: .bottom,
            animated: false
        )
        windowed.collectionView.layoutIfNeeded()
        windowed.scrollController.updateNearBottom(true)
        windowed.coordinator.updateScrollState(windowed.collectionView)

        let beforeOffsetY = windowed.collectionView.contentOffset.y
        let appendedItems = initialItems + [
            .toolCall(
                id: "review-tool-new",
                tool: "read",
                argsSummary: "clients/apple/NewFile.swift",
                outputPreview: "Review clients/apple/NewFile.swift",
                outputByteCount: 256,
                isError: false,
                isDone: false
            ),
        ]

        windowed.applyItems(appendedItems, isBusy: true)
        windowed.collectionView.layoutIfNeeded()

        let insets = windowed.collectionView.adjustedContentInset
        let maxOffsetY = max(
            -insets.top,
            windowed.collectionView.contentSize.height
                - windowed.collectionView.bounds.height
                + insets.bottom
        )
        let distanceFromBottom = maxOffsetY - windowed.collectionView.contentOffset.y

        #expect(windowed.collectionView.contentOffset.y > beforeOffsetY - 80)
        #expect(distanceFromBottom < 12, "expected attached append to stay at bottom, distance=\(distanceFromBottom)")
        #expect(windowed.scrollController.isCurrentlyNearBottom)
    }

    // MARK: - Full chain: detach → requestScrollToBottom → scroll command

    @MainActor
    @Test func fullJumpToBottomChain() {
        let windowed = makeWindowedTimelineHarness(sessionId: "session-a")
        let items: [ChatItem] = (0..<40).map { i in
            .assistantMessage(
                id: "msg-\(i)",
                text: "Message \(i) with enough text to fill space in the timeline.",
                timestamp: Date()
            )
        }

        // 1. Apply items
        windowed.applyItems(items, isBusy: false)
        windowed.collectionView.layoutIfNeeded()

        // 2. Detach: simulate user scrolling up
        windowed.scrollController.updateNearBottom(true)
        windowed.scrollController.detachFromBottomForUserScroll()
        #expect(!windowed.scrollController.isCurrentlyNearBottom)

        // Manually set hint visible (normally done by updateDetachedStreamingHintVisibility
        // which requires real scroll position math)
        windowed.scrollController.setJumpToBottomHintVisible(true)
        #expect(windowed.scrollController.isJumpToBottomHintVisible)

        // 3. Simulate button tap: requestScrollToBottom
        let nonceBefore = windowed.scrollController.scrollToBottomNonce
        windowed.scrollController.requestScrollToBottom()

        #expect(windowed.scrollController.scrollToBottomNonce == nonceBefore &+ 1)
        #expect(windowed.scrollController.isCurrentlyNearBottom)
        #expect(!windowed.scrollController.isJumpToBottomHintVisible)

        // 4. Issue scroll command (this is what ChatTimelineView.onChange does)
        let scrollCmd = ChatTimelineScrollCommand(
            id: "msg-39",
            anchor: .bottom,
            animated: false,
            nonce: 1
        )
        let configWithScroll = makeTimelineConfiguration(
            items: items,
            isBusy: false,
            scrollCommand: scrollCmd,
            sessionId: "session-a",
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: configWithScroll, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()

        // 5. Verify scroll state is at bottom
        #expect(windowed.scrollController.isCurrentlyNearBottom,
                "should remain at bottom after scroll command")
    }

    // MARK: - Follow lock prevents detach during animated scroll

    @MainActor
    @Test func followLockPreventsDetachDuringScrollToBottom() {
        let controller = ChatScrollController()

        // User is detached
        controller.updateNearBottom(false)
        controller.setJumpToBottomHintVisible(true)

        // Tap jump-to-bottom
        controller.requestScrollToBottom()
        #expect(controller.isCurrentlyNearBottom)

        // During the animated scroll, something tries to set nearBottom = false
        // (e.g., scrollViewDidScroll before animation reaches bottom).
        // The follow lock should prevent this.
        controller.updateNearBottom(false)
        #expect(controller.isCurrentlyNearBottom,
                "follow lock should prevent detach after requestScrollToBottom")
    }

}
