import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Regression tests for initial scroll-to-bottom on chat re-entry.
///
/// Bug shape:
/// - `ChatSessionManager.connect()` can preload `reducer.items` and set
///   `needsInitialScroll = true` before `ChatTimelineView` attaches its
///   `.onChange` handlers.
/// - `.onChange(of: sessionManager.needsInitialScroll)` does not fire for the
///   initial value that already exists at mount time.
/// - Without an explicit post-mount retry, a re-entered session can start at
///   the top instead of the bottom.
@Suite("Ready Session Scroll to Bottom")
struct ReadySessionScrollToBottomTests {

    @MainActor
    @Test func pendingInitialScrollAlreadyTrueBeforeMountShouldScrollToBottom() async throws {
        let fixture = try await makeHostedTimeline(
            itemCount: 40,
            isBusy: false,
            preloadNeedsInitialScroll: true
        )

        let becameScrollable = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.controller.view.setNeedsLayout()
                fixture.controller.view.layoutIfNeeded()
                let metrics = scrollMetrics(in: fixture.collectionView)
                return metrics.contentHeight > metrics.visibleHeight + 50
            }
        }
        #expect(becameScrollable)

        try? await Task.sleep(for: .milliseconds(120))
        fixture.controller.view.setNeedsLayout()
        fixture.controller.view.layoutIfNeeded()

        let metrics = scrollMetrics(in: fixture.collectionView)

        // Intended behavior: ready-session re-entry should land at the bottom.
        // Current buggy behavior leaves the timeline near the top, so this
        // expectation should fail until the bug is fixed.
        #expect(
            metrics.distanceFromBottom < metrics.distanceFromTop,
            "Expected ready re-entry to start near bottom. distTop=\(metrics.distanceFromTop), distBottom=\(metrics.distanceFromBottom), contentH=\(metrics.contentHeight), visibleH=\(metrics.visibleHeight)"
        )
    }

    @MainActor
    @Test func togglingInitialScrollAfterMountScrollsToBottom() async throws {
        let fixture = try await makeHostedTimeline(
            itemCount: 40,
            isBusy: false,
            preloadNeedsInitialScroll: false
        )

        let becameScrollable = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.controller.view.setNeedsLayout()
                fixture.controller.view.layoutIfNeeded()
                let metrics = scrollMetrics(in: fixture.collectionView)
                return metrics.contentHeight > metrics.visibleHeight + 50
            }
        }
        #expect(becameScrollable)

        // Fire the same signal AFTER the view has mounted.
        fixture.sessionManager.needsInitialScroll = true

        let scrolled = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.controller.view.setNeedsLayout()
                fixture.controller.view.layoutIfNeeded()
                let metrics = scrollMetrics(in: fixture.collectionView)
                return metrics.distanceFromBottom < metrics.distanceFromTop
            }
        }
        #expect(scrolled, "Expected post-mount initial-scroll signal to reach bottom")
    }

    @MainActor
    @Test func busySessionWithPendingInitialScrollAlsoStartsAtBottom() async throws {
        let fixture = try await makeHostedTimeline(
            itemCount: 40,
            isBusy: true,
            preloadNeedsInitialScroll: true
        )

        let scrolled = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.controller.view.setNeedsLayout()
                fixture.controller.view.layoutIfNeeded()
                let metrics = scrollMetrics(in: fixture.collectionView)
                return metrics.contentHeight > metrics.visibleHeight + 50
                    && metrics.distanceFromBottom < metrics.distanceFromTop
            }
        }
        #expect(scrolled, "Expected busy re-entry with pending initial scroll to start near bottom")
    }

    @MainActor
    @Test func pendingInitialScrollOverridesStaleDetachedStateOnReentry() async throws {
        let fixture = try await makeHostedTimeline(
            itemCount: 40,
            isBusy: false,
            preloadNeedsInitialScroll: true,
            preloadDetachedState: true
        )

        let scrolled = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                fixture.controller.view.setNeedsLayout()
                fixture.controller.view.layoutIfNeeded()
                let metrics = scrollMetrics(in: fixture.collectionView)
                return metrics.contentHeight > metrics.visibleHeight + 50
                    && metrics.distanceFromBottom < metrics.distanceFromTop
            }
        }
        #expect(scrolled, "Expected pending initial scroll to beat stale detached state on re-entry")
    }

    // MARK: - Helpers

    @MainActor
    private func makeHostedTimeline(
        itemCount: Int,
        isBusy: Bool,
        preloadNeedsInitialScroll: Bool,
        preloadDetachedState: Bool = false
    ) async throws -> HostedTimelineFixture {
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let audioPlayer = AudioPlayerService()
        let scrollController = ChatScrollController()
        let sessionManager = ChatSessionManager(sessionId: "session-\(UUID().uuidString)")

        let events = (0..<itemCount).map { i in
            makeTraceEvent(
                id: "evt-\(i)",
                type: i.isMultiple(of: 2) ? .user : .assistant,
                text: longMessage(index: i)
            )
        }
        reducer.loadSession(events)
        sessionManager.needsInitialScroll = preloadNeedsInitialScroll
        if preloadDetachedState {
            scrollController.updateNearBottom(false)
            scrollController.updateTopVisibleItemId("evt-0")
            scrollController.updateContentOffsetY(0)
        }

        let root = AnyView(
            ChatTimelineView(
                sessionId: sessionManager.sessionId,
                workspaceId: "ws-test",
                isBusy: isBusy,
                scrollController: scrollController,
                sessionManager: sessionManager,
                onFork: { _ in },
                selectedTextPiRouter: nil,
                topOverlap: 0,
                bottomOverlap: 0
            )
            .environment(reducer)
            .environment(connection)
            .environment(audioPlayer)
            .environment(connection.permissionStore)
        )

        let controller = UIHostingController(rootView: root)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let collectionViewReady = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                timelineFirstView(ofType: UICollectionView.self, in: controller.view) != nil
            }
        }
        #expect(collectionViewReady, "Expected hosted ChatTimelineView to create UICollectionView")

        let collectionView = try #require(timelineFirstView(ofType: UICollectionView.self, in: controller.view))
        return HostedTimelineFixture(
            window: window,
            controller: controller,
            collectionView: collectionView,
            reducer: reducer,
            sessionManager: sessionManager
        )
    }

    @MainActor
    private func scrollMetrics(in collectionView: UICollectionView) -> ScrollMetrics {
        let insets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
        let offsetY = collectionView.contentOffset.y + insets.top
        let contentHeight = collectionView.contentSize.height
        let distanceFromTop = max(0, offsetY)
        let distanceFromBottom = max(0, contentHeight - (offsetY + visibleHeight))
        return ScrollMetrics(
            distanceFromTop: distanceFromTop,
            distanceFromBottom: distanceFromBottom,
            contentHeight: contentHeight,
            visibleHeight: visibleHeight
        )
    }

    private func makeTraceEvent(
        id: String,
        type: TraceEventType = .assistant,
        text: String,
        timestamp: String = "2026-03-17T10:00:00Z"
    ) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: timestamp,
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }

    private func longMessage(index: Int) -> String {
        """
        Message \(index)

        This is a longer piece of chat content designed to give the timeline
        enough vertical height to require scrolling. It has multiple sentences
        and enough body text to create a realistically tall row in the chat UI.
        """
    }
}

private struct HostedTimelineFixture {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    let collectionView: UICollectionView
    let reducer: TimelineReducer
    let sessionManager: ChatSessionManager
}

private struct ScrollMetrics {
    let distanceFromTop: CGFloat
    let distanceFromBottom: CGFloat
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
}
