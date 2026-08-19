import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Timeline scroll behavior conformance")
@MainActor
struct TimelineScrollConformanceTests {
    @Test func attachedTimelineFollowsStreamingThenSettlesAtBottomWhenIdle() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-attached")
        harness.startAttachedAtBottom(isBusy: true)

        for round in 1...4 {
            harness.growStreamingText(round: round)
            harness.apply(isBusy: true)
            harness.assertTailVisible()
            #expect(
                timelineConformanceDistanceFromBottom(harness.collectionView) <= 24,
                "attached streaming must stay on the live tail"
            )
        }

        harness.apply(isBusy: false, streamingID: nil)
        harness.assertExactBottom()
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @Test func userScrollUpDetachesAndStreamingPlusToolAppendsDoNotMoveReadingAnchor() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-detached")
        harness.startAttachedAtBottom(isBusy: true)
        let anchorID = "message-10"
        harness.userScrollsUpToRead(itemID: anchorID)
        let anchorBefore = harness.screenY(of: anchorID, edge: .top)

        harness.growStreamingText(round: 5)
        harness.appendToolRows(count: 3)
        harness.apply(isBusy: true)

        harness.assertAnchorStable(itemID: anchorID, edge: .top, before: anchorBefore)
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @Test func detachedToolHeightGrowthBelowViewportDoesNotMoveReadingAnchor() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-tool-growth")
        harness.startAttachedAtBottom(isBusy: true)
        let anchorID = "message-8"
        harness.userScrollsUpToRead(itemID: anchorID)
        let anchorBefore = harness.screenY(of: anchorID, edge: .top)

        harness.growToolOutput(id: "tool-22", lineCount: 80)
        harness.apply(isBusy: true)

        harness.assertAnchorStable(itemID: anchorID, edge: .top, before: anchorBefore)
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @Test func toolExpandAndCollapseKeepTappedHeaderStable() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-expand-collapse")
        harness.startAttachedAtBottom(isBusy: false)
        let toolID = "tool-12"
        harness.userScrollsUpToRead(itemID: toolID)

        let topBeforeExpand = harness.screenY(of: toolID, edge: .top)
        harness.expandTool(id: toolID)
        harness.assertAnchorStable(itemID: toolID, edge: .top, before: topBeforeExpand)

        let topBeforeCollapse = harness.screenY(of: toolID, edge: .top)
        harness.collapseTool(id: toolID)
        harness.assertAnchorStable(itemID: toolID, edge: .top, before: topBeforeCollapse)
    }

    @Test func expandedToolInnerScrollViewsDoNotOwnVerticalScroll() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-inner-scroll")
        harness.startAttachedAtBottom(isBusy: false)
        let toolID = "tool-12"
        harness.userScrollsUpToRead(itemID: toolID)
        harness.expandTool(id: toolID)

        let innerScrollViews = harness.expandedInnerScrollViews(for: toolID)
        #expect(!innerScrollViews.isEmpty, "expanded tool should contain inner scroll surfaces")
        for inner in innerScrollViews {
            #expect(!inner.alwaysBounceVertical, "inner tool scroll view must not force vertical bouncing")
            if inner.isScrollEnabled {
                #expect(!inner.bounces, "inner tool scroll view must not vertically bounce against the outer timeline")
                let verticalOverflow = inner.contentSize.height - inner.bounds.height
                #expect(verticalOverflow <= 16, "inner tool scroll view can consume vertical drags, overflow=\(verticalOverflow)")
            }
        }
    }

    @Test func jumpToBottomReattachesAndRestoresTailVisibility() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-jump-bottom")
        harness.startAttachedAtBottom(isBusy: false)
        harness.userScrollsUpToRead(itemID: "message-6")
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        harness.scrollController.setJumpToBottomHintVisible(true)
        harness.scrollController.requestScrollToBottom()
        let command = ChatTimelineScrollCommand(
            id: harness.streamingID,
            anchor: .bottom,
            animated: false,
            nonce: Int(harness.scrollController.scrollToBottomNonce)
        )
        let config = makeTimelineConfiguration(
            items: harness.items,
            isBusy: false,
            scrollCommand: command,
            sessionId: harness.windowed.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.windowed.toolOutputStore,
            toolArgsStore: harness.windowed.toolArgsStore,
            toolSegmentStore: harness.windowed.toolSegmentStore,
            connection: harness.windowed.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.windowed.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)
        settleTimelineLayout(harness.collectionView, passes: 3)

        #expect(harness.scrollController.isCurrentlyNearBottom)
        #expect(!harness.scrollController.isJumpToBottomHintVisible)
        harness.assertTailVisible()
    }
}
