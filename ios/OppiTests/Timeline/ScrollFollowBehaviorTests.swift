import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Scroll follow behavior")
struct ScrollFollowBehaviorTests {
    @MainActor
    @Test func nearBottomHysteresisKeepsFollowStableForSmallTailGrowth() {
        // Thresholds: enter=120, exit=200.
        // When already near-bottom, distances ≤ 200 keep follow stable.
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        // Distance 150 — within exit threshold (200), stays near-bottom.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isCurrentlyNearBottom)

        // Distance 250 — exceeds exit threshold (200), detaches.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 250, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func upwardUserScrollDetachesFollowBeforeExitThreshold() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        // Move up 150pt from bottom — past the enter threshold (120pt) so
        // the detach sticks even after updateScrollState re-evaluates.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)

        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func smallUpwardScrollDetachSticksUntilDragEnds() async {
        // User scrolls up just a little (50pt from bottom), within the enter
        // threshold (120pt). The detach must still stick — the user clearly
        // intends to scroll away. Re-attach should only happen when the user
        // scrolls back *down* near the bottom.
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        // Start at the bottom.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        // Small scroll up: only 50pt from bottom (within enter threshold 120pt).
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 50, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)

        // Must stay detached — the user is actively scrolling up.
        #expect(!harness.scrollController.isCurrentlyNearBottom,
                "detach should stick even within enter threshold during upward scroll")

        // Auto-scroll must not fire while detached.
        var scrollCount = 0
        harness.scrollController.handleContentChange(
            isBusy: true,
            streamingAssistantID: "stream-1",
            bottomItemID: "bottom-1"
        ) { _ in scrollCount += 1 }

        let stayedDetached = await waitForMainActorConditionToStayTrue(
            for: .milliseconds(160),
            poll: .milliseconds(10)
        ) {
            scrollCount == 0
        }
        #expect(stayedDetached,
                "auto-scroll must not fire while user is scrolled up")
    }

    @MainActor
    @Test func busyToIdleTransitionDoesNotReattachDetachedUser() {
        // When isBusy transitions false between tool calls, the apply method's
        // updateScrollState must not re-attach a detached user — even if the
        // user's scroll position is within the enter threshold.
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 2_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        // User is attached, at the bottom.
        harness.scrollController.updateNearBottom(true)

        // Simulate upward scroll → detach (user scrolls up).
        metricsView.testIsTracking = true
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        harness.coordinator.scrollViewWillBeginDragging(metricsView)
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 80, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        metricsView.testIsTracking = false
        harness.coordinator.scrollViewDidEndDragging(metricsView, willDecelerate: false)

        #expect(!harness.scrollController.isCurrentlyNearBottom,
                "user should be detached after upward scroll")

        // Now apply a configuration with isBusy=false (agent idle between tools).
        // The apply method's updateScrollState runs when !isBusy. It must not
        // re-attach a user who explicitly detached, even though 80pt is within
        // the 120pt enter threshold.
        let idleConfig = makeTimelineConfiguration(
            isBusy: false,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: idleConfig, to: harness.collectionView)

        #expect(!harness.scrollController.isCurrentlyNearBottom,
                "busy->idle apply re-attached a detached user")
    }

    @MainActor
    @Test func nearBottomHysteresisRequiresCloserReentryAfterDetach() {
        // Thresholds: enter=120, exit=200.
        // When detached, must get within enter threshold (120) to re-attach.
        // Re-attach only happens during user-driven scrolls (back toward bottom).
        let harness = makeTimelineHarness(sessionId: "session-a")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(false)

        // Simulate user-driven scroll (e.g., scrolling back down toward bottom).
        metricsView.testIsDecelerating = true

        // Distance 150 — beyond enter threshold (120), stays detached.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        // Distance 80 — within enter threshold (120), re-attaches.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 80, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func detachedStreamingHintTracksOffscreenStreamingState() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let streamingConfig = makeTimelineConfiguration(
            items: [
                .assistantMessage(id: "assistant-stream", text: "token", timestamp: Date()),
            ],
            streamingAssistantID: "assistant-stream",
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: streamingConfig, to: harness.collectionView)

        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        // Distance 800 — well past the 500pt minimum for showing the button.
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 800, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isDetachedStreamingHintVisible)

        let nonStreamingConfig = makeTimelineConfiguration(
            items: [
                .assistantMessage(id: "assistant-stream", text: "done", timestamp: Date()),
            ],
            streamingAssistantID: nil,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: nonStreamingConfig, to: harness.collectionView)
        #expect(!harness.scrollController.isDetachedStreamingHintVisible)

        harness.coordinator.apply(configuration: streamingConfig, to: harness.collectionView)
        // Simulate user scrolling back to bottom (user-driven scroll).
        metricsView.testIsDecelerating = true
        metricsView.contentOffset = CGPoint(x: 0, y: timelineOffsetY(forDistanceFromBottom: 0, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        metricsView.testIsDecelerating = false
        #expect(!harness.scrollController.isDetachedStreamingHintVisible)
    }

}
