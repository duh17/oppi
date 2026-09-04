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

    @Test func streamingTailGrowthDoesNotRemeasureSettledRowsAbove() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-height-cache")
        harness.startAttachedAtBottom(isBusy: true)
        measureEveryTimelineRow(harness.collectionView)
        pinConformanceHarnessToBottom(harness)

        let settledID = "message-2"
        guard let settledIndex = harness.coordinator.currentIDs.firstIndex(of: settledID),
              let before = harness.collectionView.layoutAttributesForItem(
                  at: IndexPath(item: settledIndex, section: 0)
              ) else {
            Issue.record("Missing settled row \(settledID)")
            return
        }
        let beforeFrame = before.frame
        let beforeContentHeight = harness.collectionView.contentSize.height

        for round in 1...4 {
            harness.growStreamingText(round: round)
            harness.apply(isBusy: true)
        }

        guard let after = harness.collectionView.layoutAttributesForItem(
            at: IndexPath(item: settledIndex, section: 0)
        ) else {
            Issue.record("Missing settled row after streaming")
            return
        }
        #expect(abs(after.frame.minY - beforeFrame.minY) < 0.5)
        #expect(abs(after.frame.height - beforeFrame.height) < 0.5)
        #expect(harness.collectionView.contentSize.height >= beforeContentHeight - 0.5)

        let layout = harness.collectionView.collectionViewLayout as? ChatTimelineCachedHeightLayout
        #expect(layout != nil, "timeline must use the cached-height layout")
        #expect(layout?.cachedHeightForTesting(itemID: settledID) != nil)
        harness.assertTailVisible()
    }

    @Test func fullLayoutInvalidationKeepsOffscreenCachedHeights() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-height-cache-invalidate")
        harness.startAttachedAtBottom(isBusy: true)
        measureEveryTimelineRow(harness.collectionView)
        pinConformanceHarnessToBottom(harness)

        let offscreenID = "message-0"
        guard let index = harness.coordinator.currentIDs.firstIndex(of: offscreenID),
              let before = harness.collectionView.layoutAttributesForItem(
                  at: IndexPath(item: index, section: 0)
              ) else {
            Issue.record("Missing off-screen row \(offscreenID)")
            return
        }
        #expect(
            before.frame.height > ChatTimelineCachedHeightLayout.estimatedHeight + 1,
            "off-screen row should already be measured, height=\(before.frame.height)"
        )

        harness.collectionView.collectionViewLayout.invalidateLayout()
        harness.collectionView.layoutIfNeeded()

        guard let after = harness.collectionView.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
        ) else {
            Issue.record("Missing off-screen row after invalidateLayout")
            return
        }
        #expect(abs(after.frame.height - before.frame.height) < 0.5)
        #expect(abs(after.frame.minY - before.frame.minY) < 0.5)
        #expect(after.frame.height > ChatTimelineCachedHeightLayout.estimatedHeight + 1)
    }

    @Test func inFlightToolCollapseShrinksRowHeight() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-inflight-collapse")
        let toolID = "tool-12"
        let inFlightItems = makeInFlightToolItems(from: harness, toolID: toolID, lineCount: 80)
        applyInFlightToolItems(harness, items: inFlightItems)
        harness.userScrollsUpToRead(itemID: toolID)

        guard let collapsedHeight = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing collapsed in-flight tool \(toolID)")
            return
        }

        harness.expandTool(id: toolID)
        applyInFlightToolItems(harness, items: inFlightItems)
        guard let expandedHeight = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing expanded in-flight tool \(toolID)")
            return
        }
        #expect(
            expandedHeight > collapsedHeight + 40,
            "expanded in-flight tool should grow, collapsed=\(collapsedHeight) expanded=\(expandedHeight)"
        )

        harness.collapseTool(id: toolID)
        guard let afterCollapse = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing collapsed in-flight tool after collapse")
            return
        }
        #expect(
            afterCollapse < expandedHeight - 40,
            "collapsing a live tool must shrink the row, expanded=\(expandedHeight) after=\(afterCollapse)"
        )
    }

    @Test func inFlightToolCollapseViaAnchoredReconfigureShrinksRowHeight() {
        let harness = TimelineScrollConformanceHarness(
            sessionId: "scroll-conformance-inflight-keybinding-collapse"
        )
        let toolID = "tool-12"
        let inFlightItems = makeInFlightToolItems(from: harness, toolID: toolID, lineCount: 80)
        applyInFlightToolItems(harness, items: inFlightItems)
        harness.userScrollsUpToRead(itemID: toolID)

        guard let collapsedHeight = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing collapsed in-flight tool \(toolID)")
            return
        }

        harness.expandTool(id: toolID)
        applyInFlightToolItems(harness, items: inFlightItems)
        guard let expandedHeight = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing expanded in-flight tool \(toolID)")
            return
        }
        #expect(
            expandedHeight > collapsedHeight + 40,
            "expanded in-flight tool should grow, collapsed=\(collapsedHeight) expanded=\(expandedHeight)"
        )

        // Hardware keybinding mutates expansion, then remesures through
        // anchoredReconfigureToolRow without didSelect's live-tail refresh.
        harness.reducer.expandedItemIDs.remove(toolID)
        guard let index = harness.coordinator.currentIDs.firstIndex(of: toolID) else {
            Issue.record("Missing tool \(toolID) after expand")
            return
        }
        harness.coordinator.anchoredReconfigureToolRow(
            itemID: toolID,
            anchorIndexPath: IndexPath(item: index, section: 0),
            in: harness.collectionView,
            preserveTopEdge: true
        )
        settleTimelineLayout(harness.collectionView, passes: 4)

        guard let afterCollapse = timelineRowHeight(harness, itemID: toolID) else {
            Issue.record("Missing collapsed in-flight tool after remesure collapse")
            return
        }
        #expect(
            afterCollapse < expandedHeight - 40,
            "collapsing a live tool via anchored remesure must shrink the row, expanded=\(expandedHeight) after=\(afterCollapse)"
        )
    }

    @Test func dynamicTypeChangeDoesNotResetCachedHeightsToEstimate() {
        let harness = TimelineScrollConformanceHarness(sessionId: "scroll-conformance-dynamic-type-cache")
        harness.startAttachedAtBottom(isBusy: true)
        measureEveryTimelineRow(harness.collectionView)
        pinConformanceHarnessToBottom(harness)

        let offscreenID = "message-0"
        guard let index = harness.coordinator.currentIDs.firstIndex(of: offscreenID),
              let before = harness.collectionView.layoutAttributesForItem(
                  at: IndexPath(item: index, section: 0)
              ) else {
            Issue.record("Missing off-screen row \(offscreenID)")
            return
        }
        let beforeHeight = before.frame.height
        let beforeContentHeight = harness.collectionView.contentSize.height
        #expect(
            beforeHeight > ChatTimelineCachedHeightLayout.estimatedHeight + 1,
            "off-screen row should already be measured, height=\(beforeHeight)"
        )

        harness.collectionView.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        harness.collectionView.collectionViewLayout.invalidateLayout()
        harness.collectionView.layoutIfNeeded()

        guard let after = harness.collectionView.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
        ) else {
            Issue.record("Missing off-screen row after Dynamic Type change")
            return
        }
        let layout = harness.collectionView.collectionViewLayout as? ChatTimelineCachedHeightLayout
        let cached = layout?.cachedHeightForTesting(itemID: offscreenID)
        #expect(cached != nil, "Dynamic Type must not drop the height cache in one shot")
        #expect(
            (cached ?? 0) > ChatTimelineCachedHeightLayout.estimatedHeight + 1,
            "cached off-screen height must survive category change, cached=\(String(describing: cached))"
        )
        #expect(
            after.frame.height > ChatTimelineCachedHeightLayout.estimatedHeight + 1,
            "off-screen row must not snap to the 100pt estimate before remesure, height=\(after.frame.height)"
        )
        #expect(
            abs(after.frame.height - beforeHeight) < 0.5,
            "off-screen measured height must survive category change before remesure, before=\(beforeHeight) after=\(after.frame.height)"
        )
        #expect(
            abs(harness.collectionView.contentSize.height - beforeContentHeight) < 1
                || harness.collectionView.contentSize.height > ChatTimelineCachedHeightLayout.estimatedHeight * 2,
            "contentSize must not collapse to the 100pt estimate, content=\(harness.collectionView.contentSize.height)"
        )
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

@MainActor
private func measureEveryTimelineRow(_ collectionView: UICollectionView) {
    let step = max(collectionView.bounds.height * 0.8, 1)
    var offset: CGFloat = 0
    let maxY = max(collectionView.contentSize.height, collectionView.bounds.height)
    while offset < maxY {
        collectionView.contentOffset.y = offset
        collectionView.layoutIfNeeded()
        offset += step
    }
    collectionView.contentOffset.y = maxY
    collectionView.layoutIfNeeded()
}

@MainActor
private func timelineRowHeight(
    _ harness: TimelineScrollConformanceHarness,
    itemID: String
) -> CGFloat? {
    guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID),
          let attrs = harness.collectionView.layoutAttributesForItem(
              at: IndexPath(item: index, section: 0)
          ) else {
        return nil
    }
    return attrs.frame.height
}

@MainActor
private func makeInFlightToolItems(
    from harness: TimelineScrollConformanceHarness,
    toolID: String,
    lineCount: Int
) -> [ChatItem] {
    var items = harness.items
    harness.windowed.toolOutputStore.replace(
        String(repeating: "grown output line\n", count: lineCount),
        for: toolID
    )
    guard let index = items.firstIndex(where: { $0.id == toolID }) else {
        Issue.record("Missing tool \(toolID)")
        return items
    }
    items[index] = .toolCall(
        id: toolID,
        tool: "bash",
        argsSummary: "echo grown",
        outputPreview: String(repeating: "grown output line\n", count: min(lineCount, 8)),
        outputByteCount: lineCount * 18,
        isError: false,
        isDone: false
    )
    return items
}

@MainActor
private func applyInFlightToolItems(
    _ harness: TimelineScrollConformanceHarness,
    items: [ChatItem]
) {
    harness.windowed.applyItems(
        items,
        isBusy: true,
        streamingID: harness.streamingID
    )
    settleTimelineLayout(harness.collectionView, passes: 3)
}

@MainActor
private func pinConformanceHarnessToBottom(_ harness: TimelineScrollConformanceHarness) {
    let lastIndex = max(harness.coordinator.currentIDs.count - 1, 0)
    harness.collectionView.scrollToItem(
        at: IndexPath(item: lastIndex, section: 0),
        at: .bottom,
        animated: false
    )
    settleTimelineLayout(harness.collectionView, passes: 3)
    harness.scrollController.updateNearBottom(true)
    harness.coordinator.updateScrollState(harness.collectionView)
}
