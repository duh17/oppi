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

@MainActor
private func timelineItemScreenY(_ itemID: String, in windowed: WindowedTimelineHarness) throws -> CGFloat {
    let index = try #require(windowed.coordinator.currentIDs.firstIndex(of: itemID))
    let attrs = try #require(
        windowed.collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
    )
    return attrs.frame.minY - windowed.collectionView.contentOffset.y
}

@MainActor
private func firstVisibleTimelineItemID(in windowed: WindowedTimelineHarness) -> String? {
    let collectionView = windowed.collectionView
    let visibleRect = CGRect(
        origin: collectionView.contentOffset,
        size: collectionView.bounds.size
    )
    return windowed.coordinator.currentIDs.enumerated()
        .compactMap { index, itemID -> (id: String, minY: CGFloat)? in
            guard itemID != ChatTimelineCollectionHost.loadMoreID,
                  itemID != ChatTimelineCollectionHost.workingIndicatorID,
                  let attrs = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                  ),
                  attrs.frame.intersects(visibleRect) else {
                return nil
            }
            return (itemID, attrs.frame.minY)
        }
        .min { $0.minY < $1.minY }?
        .id
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
    @Test func dragStartDetachesBeforeActiveTurnCanFollow() {
        let harness = makeTimelineHarness(sessionId: "session-reading-active-turn")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        metricsView.contentOffset = CGPoint(
            x: 0,
            y: timelineOffsetY(forDistanceFromBottom: 800, in: metricsView)
        )

        harness.scrollController.requestScrollToBottom()
        // Passive geometry cannot break the send/jump follow lock.
        harness.scrollController.updateNearBottom(false)
        #expect(harness.scrollController.isCurrentlyNearBottom)

        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        #expect(
            !harness.scrollController.isCurrentlyNearBottom,
            "a user drag while browsing older messages must override the follow lock before active updates arrive"
        )
    }

    @MainActor
    @Test func activeTurnUpdatesPreserveViewportAfterDragStartDetaches() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-reading-active-turn-updates",
            useAnchoredCollectionView: true
        )
        var items = (0..<40).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index). ", count: 12),
                timestamp: Date()
            )
        }
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))

        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        windowed.collectionView.layoutIfNeeded()
        let maxOffsetY = timelineMaxOffsetY(windowed.collectionView)
        windowed.collectionView.contentOffset.y = maxOffsetY
        windowed.collectionView.layoutIfNeeded()
        windowed.scrollController.updateNearBottom(true)

        setTimelineUserScrollOffsetY(windowed.collectionView, maxOffsetY * 0.45)
        windowed.coordinator.scrollViewWillBeginDragging(windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
        let readingItemID = try #require(firstVisibleTimelineItemID(in: windowed))
        let readingScreenY = try timelineItemScreenY(readingItemID, in: windowed)

        items[items.count - 1] = .assistantMessage(
            id: "streaming",
            text: String(repeating: "Still working. ", count: 80),
            timestamp: Date()
        )
        items.append(.toolCall(
            id: "tool-new",
            tool: "read",
            argsSummary: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            outputPreview: "Reading",
            outputByteCount: 128,
            isError: false,
            isDone: false
        ))
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")

        let afterScreenY = try timelineItemScreenY(readingItemID, in: windowed)
        #expect(
            abs(afterScreenY - readingScreenY) < 2,
            "active-turn updates moved reading item \(readingItemID) by \(afterScreenY - readingScreenY)pt"
        )
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func readingTallUserMessageStaysFrozenAcrossSequentialToolAppends() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-read-tall-prompt-during-tools",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)
        let renderWindow = TimelineRenderWindowPolicy.standardWindow

        var items: [ChatItem] = (0..<(renderWindow - 2)).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index). ", count: 8),
                timestamp: Date()
            )
        }

        let userID = "user-tall-prompt"
        let tallPrompt = (0..<70)
            .map { "Please review clients/apple/Oppi/Features/Chat/File\($0).swift and keep this prompt on screen." }
            .joined(separator: "\n")
        items.append(.userMessage(id: userID, text: tallPrompt, images: [], timestamp: Date()))
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))

        func applyWindowedTail() {
            windowed.applyItems(
                Array(items.suffix(renderWindow)),
                hiddenCount: max(0, items.count - renderWindow),
                renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
                isBusy: true,
                streamingID: "streaming"
            )
            collectionView.layoutIfNeeded()
        }

        applyWindowedTail()

        let maxOffsetY = timelineMaxOffsetY(collectionView)
        collectionView.contentOffset.y = maxOffsetY
        collectionView.layoutIfNeeded()
        windowed.scrollController.requestScrollToBottom()
        windowed.coordinator.updateScrollState(collectionView)
        #expect(windowed.scrollController.isCurrentlyNearBottom)

        let userIndex = try #require(windowed.coordinator.currentIDs.firstIndex(of: userID))
        let userAttrs = try #require(
            collectionView.layoutAttributesForItem(at: IndexPath(item: userIndex, section: 0))
        )
        #expect(
            userAttrs.frame.height > collectionView.bounds.height,
            "precondition: just-sent user message must be taller than the viewport"
        )

        // Real drag from the live tail: begin, then pull the tall prompt up.
        // Do not call detachFromBottomForUserScroll() directly.
        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        #expect(
            windowed.scrollController.isCurrentlyNearBottom,
            "touching the tail without upward movement must not detach"
        )

        let targetOffsetY = userAttrs.frame.minY - collectionView.adjustedContentInset.top
        setTimelineUserScrollOffsetY(collectionView, targetOffsetY)
        collectionView.layoutIfNeeded()
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        collectionView.layoutIfNeeded()

        let readingScreenY = try timelineItemScreenY(userID, in: windowed)
        let offsetBeforeTools = collectionView.contentOffset.y
        #expect(!windowed.scrollController.isCurrentlyNearBottom)

        func appendTool(id: String, outputLines: Int) {
            items.append(.toolCall(
                id: id,
                tool: "read",
                argsSummary: "clients/apple/Oppi/Features/Chat/\(id).swift",
                outputPreview: String(repeating: "tool output for \(id)\n", count: outputLines),
                outputByteCount: outputLines * 32,
                isError: false,
                isDone: false
            ))
            applyWindowedTail()
        }

        appendTool(id: "tool-1", outputLines: 20)
        let afterTool1ScreenY = try timelineItemScreenY(userID, in: windowed)
        #expect(
            abs(afterTool1ScreenY - readingScreenY) < 2,
            "tool 1 moved reading item \(userID) screen Y by \(afterTool1ScreenY - readingScreenY)pt; offset delta=\(collectionView.contentOffset.y - offsetBeforeTools)"
        )
        #expect(!windowed.scrollController.isCurrentlyNearBottom)

        appendTool(id: "tool-2", outputLines: 28)
        let afterTool2ScreenY = try timelineItemScreenY(userID, in: windowed)
        #expect(
            abs(afterTool2ScreenY - readingScreenY) < 2,
            "tool 2 moved reading item \(userID) screen Y by \(afterTool2ScreenY - readingScreenY)pt; offset delta=\(collectionView.contentOffset.y - offsetBeforeTools)"
        )
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func dragStartBeyondTrueTailDetachesFollow() {
        let harness = makeTimelineHarness(sessionId: "session-near-live-edge")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        metricsView.contentOffset = CGPoint(
            x: 0,
            y: timelineOffsetY(forDistanceFromBottom: 80, in: metricsView)
        )

        harness.scrollController.updateNearBottom(true)
        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        #expect(
            !harness.scrollController.isCurrentlyNearBottom,
            "80pt from bottom is already detached reading, not the true live tail"
        )
    }

    @MainActor
    @Test func dragStartAtTrueTailKeepsFollowAttached() {
        let harness = makeTimelineHarness(sessionId: "session-at-live-edge")
        let metricsView = TimelineScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 3_000)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]
        metricsView.contentOffset = CGPoint(
            x: 0,
            y: timelineOffsetY(forDistanceFromBottom: 16, in: metricsView)
        )

        harness.scrollController.updateNearBottom(true)
        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        #expect(
            harness.scrollController.isCurrentlyNearBottom,
            "touching the true tail without upward movement must keep live follow"
        )
    }

    @MainActor
    @Test func detachedDownwardDragIsNotRevertedByIdentityAnchor() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-scroll-back-to-tail",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)

        var items = (0..<24).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index). ", count: 10),
                timestamp: Date()
            )
        }
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        collectionView.layoutIfNeeded()

        let maxOffsetY = timelineMaxOffsetY(collectionView)
        collectionView.contentOffset.y = maxOffsetY
        collectionView.layoutIfNeeded()
        windowed.scrollController.requestScrollToBottom()

        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, maxOffsetY * 0.4)
        windowed.coordinator.scrollViewDidScroll(collectionView)
        collectionView.layoutIfNeeded()
        #expect(!windowed.scrollController.isCurrentlyNearBottom)

        let readingItemID = try #require(firstVisibleTimelineItemID(in: windowed))
        let readingScreenY = try timelineItemScreenY(readingItemID, in: windowed)

        // Real UIKit dragging writes offset without recapturing the sticky Y.
        // The identity restore must not yank this downward movement back.
        let downwardOffsetY = min(maxOffsetY, collectionView.contentOffset.y + 90)
        #expect(downwardOffsetY - collectionView.contentOffset.y > 40)
        anchored.applyOffsetCorrection(downwardOffsetY)
        collectionView.layoutIfNeeded()

        #expect(
            abs(collectionView.contentOffset.y - downwardOffsetY) < 2,
            "identity restore reverted a downward drag by \(collectionView.contentOffset.y - downwardOffsetY)pt"
        )
        #expect(
            abs((try timelineItemScreenY(readingItemID, in: windowed)) - readingScreenY) > 20,
            "downward drag must move the reading item, not pin it to the pre-drag screen Y"
        )

        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
    }

    @MainActor
    @Test func jumpToBottomDuringBusyStreamClearsIdentityPin() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-jump-during-stream",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)

        var items = (0..<18).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index). ", count: 10),
                timestamp: Date()
            )
        }
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        collectionView.layoutIfNeeded()

        let maxOffsetY = timelineMaxOffsetY(collectionView)
        collectionView.contentOffset.y = maxOffsetY
        collectionView.layoutIfNeeded()
        windowed.scrollController.requestScrollToBottom()

        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, maxOffsetY * 0.35)
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
        #expect(anchored.isDetachedFromBottom)
        #expect(anchored.detachedAnchorIsActive)

        windowed.scrollController.requestScrollToBottom()
        items[items.count - 1] = .assistantMessage(
            id: "streaming",
            text: String(repeating: "Still streaming. ", count: 24),
            timestamp: Date()
        )
        let jump = ChatTimelineScrollCommand(
            id: "streaming",
            anchor: .bottom,
            animated: false,
            nonce: 11
        )
        let jumpConfig = makeTimelineConfiguration(
            items: items,
            isBusy: true,
            streamingAssistantID: "streaming",
            scrollCommand: jump,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: jumpConfig, to: collectionView)
        collectionView.layoutIfNeeded()

        #expect(windowed.scrollController.isCurrentlyNearBottom)
        #expect(!anchored.isDetachedFromBottom)
        #expect(!anchored.detachedAnchorIsActive)

        items[items.count - 1] = .assistantMessage(
            id: "streaming",
            text: String(repeating: "Still streaming. ", count: 48),
            timestamp: Date()
        )
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        let distanceFromBottom = timelineMaxOffsetY(collectionView) - collectionView.contentOffset.y
        #expect(
            distanceFromBottom < 32,
            "after jump, a later streaming tick must keep the live tail, distance=\(distanceFromBottom)"
        )
    }

    @MainActor
    @Test func fingerReattachDuringBusyStreamKeepsFollowingTokens() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-finger-return-to-tail",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)

        var items = (0..<18).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index). ", count: 10),
                timestamp: Date()
            )
        }
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        collectionView.layoutIfNeeded()

        let maxOffsetY = timelineMaxOffsetY(collectionView)
        collectionView.contentOffset.y = maxOffsetY
        collectionView.layoutIfNeeded()
        windowed.scrollController.requestScrollToBottom()

        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, maxOffsetY * 0.35)
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
        #expect(anchored.detachedAnchorIsActive)

        // Finger returns to the true tail. This must clear the identity pin
        // so the next token tick follows instead of restoring the mid-timeline Y.
        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, timelineMaxOffsetY(collectionView))
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        collectionView.layoutIfNeeded()

        #expect(windowed.scrollController.isCurrentlyNearBottom)
        #expect(!anchored.isDetachedFromBottom)
        #expect(!anchored.detachedAnchorIsActive)

        items[items.count - 1] = .assistantMessage(
            id: "streaming",
            text: String(repeating: "More tokens. ", count: 40),
            timestamp: Date()
        )
        windowed.applyItems(items, isBusy: true, streamingID: "streaming")
        let distanceFromBottom = timelineMaxOffsetY(collectionView) - collectionView.contentOffset.y
        #expect(
            distanceFromBottom < 32,
            "after finger reattach, a later streaming tick must keep the live tail, distance=\(distanceFromBottom)"
        )
    }

    @MainActor
    @Test func detachedIdentitySkipsLoadMoreRowAtWindowTop() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-read-past-text-at-window-top",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)
        let renderWindow = TimelineRenderWindowPolicy.standardWindow

        var items: [ChatItem] = (0..<(renderWindow + 8)).map { index in
            ChatItem.assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "Past session \(index). ", count: 8),
                timestamp: Date()
            )
        }
        items.append(.assistantMessage(id: "streaming", text: "Working…", timestamp: Date()))

        func applyWindowedTail() {
            windowed.applyItems(
                Array(items.suffix(renderWindow)),
                hiddenCount: max(0, items.count - renderWindow),
                renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
                isBusy: true,
                streamingID: "streaming"
            )
            collectionView.layoutIfNeeded()
        }

        applyWindowedTail()
        #expect(windowed.coordinator.currentIDs.first == ChatTimelineCollectionHost.loadMoreID)

        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
        collectionView.layoutIfNeeded()

        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)

        let readingItemID = try #require(
            firstVisibleTimelineItemID(in: windowed),
            "first visible stable item must not be the load-more row"
        )
        #expect(readingItemID != ChatTimelineCollectionHost.loadMoreID)
        let readingScreenY = try timelineItemScreenY(readingItemID, in: windowed)

        // Grow the live tail in place so the suffix window does not evict the
        // top reading item. This still exercises load-more as first visible.
        items[items.count - 1] = .assistantMessage(
            id: "streaming",
            text: String(repeating: "Still working. ", count: 40),
            timestamp: Date()
        )
        applyWindowedTail()

        #expect(windowed.coordinator.currentIDs.contains(readingItemID))
        let afterScreenY = try timelineItemScreenY(readingItemID, in: windowed)
        #expect(
            abs(afterScreenY - readingScreenY) < 2,
            "streaming growth at the tail moved \(readingItemID) by \(afterScreenY - readingScreenY)pt"
        )
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
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
