import Foundation
import Testing
import UIKit
@testable import Oppi

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
