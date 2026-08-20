import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Session timeline navigation")
@MainActor
struct SessionTimelineNavigationTests {
    @Test func detachedNavigationExpandsHistoryAndLandsOnSelectedAssistantMessage() async throws {
        let result = await navigateFromDetachedTail(to: "msg-20")
        #expect(
            result.reachedTarget,
            "Expected timeline navigation to land on msg-20; top=\(result.topVisible), visible=\(result.visibleIDs)"
        )
        #expect(result.didHighlightTarget, "Expected assistant target row to flash after navigation")
        #expect(result.highlightOverlayFrontmost, "Expected assistant highlight overlay to render above row content")
    }

    @Test func detachedNavigationExpandsHistoryAndLandsOnSelectedToolRow() async throws {
        let result = await navigateFromDetachedTail(to: "tool-21")
        #expect(
            result.reachedTarget,
            "Expected timeline navigation to land on tool-21; top=\(result.topVisible), visible=\(result.visibleIDs)"
        )
        #expect(result.didHighlightTarget, "Expected tool target row to flash after navigation")
        #expect(result.highlightOverlayFrontmost, "Expected tool highlight overlay to render above row content")
    }

    @Test func navigationReentryRestoresStableItemAtExactRelativeViewportPosition() async throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-document-reentry",
            useAnchoredCollectionView: true
        )
        let originalItems = makeMixedTimelineItems(count: 50)
        applyTimelineItems(originalItems, hiddenCount: 0, nonce: nil, to: harness)

        let anchorID = "msg-20"
        let anchorIndex = try #require(harness.coordinator.currentIDs.firstIndex(of: anchorID))
        let anchorPath = IndexPath(item: anchorIndex, section: 0)
        settleTimelineLayout(harness.collectionView, passes: 3)
        let anchorAttrs = try #require(
            harness.collectionView.layoutAttributesForItem(at: anchorPath)
        )
        harness.scrollController.detachFromBottomForUserScroll()
        if let anchoredCV = harness.collectionView as? AnchoredCollectionView {
            anchoredCV.isDetachedFromBottom = true
        }
        setTimelineUserScrollOffsetY(
            harness.collectionView,
            anchorAttrs.frame.minY - harness.collectionView.adjustedContentInset.top + 37
        )
        harness.coordinator.updateScrollState(
            harness.collectionView,
            preserveDetachedState: true
        )

        let before = try #require(
            harness.collectionView.layoutAttributesForItem(
                at: IndexPath(item: anchorIndex, section: 0)
            )
        ).frame.minY - harness.collectionView.contentOffset.y
        #expect(
            abs(before + 37) < 8,
            "setup should place \(anchorID) near -37pt, got relativeY=\(before) offset=\(harness.collectionView.contentOffset.y) minY=\(anchorAttrs.frame.minY)"
        )
        harness.scrollController.suspendForNavigation()

        let changedItems: [ChatItem] = [
            .assistantMessage(id: "new-prefix", text: "New context while reading the document", timestamp: Date()),
        ] + originalItems + [
            .assistantMessage(id: "new-tail", text: "New live-tail context", timestamp: Date()),
        ]
        harness.scrollController.needsInitialScroll = true
        let changedIDs = changedItems.map(\.id)
        let placement = try #require(harness.scrollController.initialPlacement(
            availableFullTimelineItemIDs: changedIDs,
            bottomItemID: "new-tail"
        ))
        guard case .viewport(let restoration) = placement else {
            Issue.record("Expected detached viewport restoration, got \(placement)")
            return
        }

        let command = ChatTimelineScrollCommand(
            id: restoration.itemID,
            anchor: .viewport(relativeY: restoration.relativeY),
            animated: false,
            nonce: 7
        )
        let config = makeTimelineConfiguration(
            items: changedItems,
            isBusy: false,
            scrollCommand: command,
            sessionId: harness.sessionId,
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            toolSegmentStore: harness.toolSegmentStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let restored = await waitForTimelineCondition(timeoutMs: 500) {
            await MainActor.run {
                settleTimelineLayout(harness.collectionView, passes: 3)
                guard let index = harness.coordinator.currentIDs.firstIndex(of: anchorID),
                      let attributes = harness.collectionView.layoutAttributesForItem(
                          at: IndexPath(item: index, section: 0)
                      ) else {
                    return false
                }
                let after = attributes.frame.minY - harness.collectionView.contentOffset.y
                return abs(after - before) < 2
            }
        }

        #expect(restored, "Expected \(anchorID) to return to relativeY=\(before)")
    }

    @Test func viewportCorrectionDoesNotReattachDuringEstimatedLayout() {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-document-estimated-layout",
            useAnchoredCollectionView: true
        )
        applyTimelineItems(
            makeMixedTimelineItems(count: 2),
            hiddenCount: 0,
            nonce: nil,
            to: harness
        )
        harness.scrollController.detachFromBottomForUserScroll()

        harness.coordinator.updateScrollState(
            harness.collectionView,
            preserveDetachedState: true
        )

        #expect(!harness.scrollController.isCurrentlyNearBottom)

        // The same geometry would normally enter near-bottom hysteresis; only
        // navigation restoration suppresses that transient reattachment.
        harness.coordinator.updateScrollState(harness.collectionView)
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @Test func windowedReentryUsesAbsoluteFullTimelineOrdinalForFallback() throws {
        let harness = makeWindowedTimelineHarness(
            sessionId: "session-windowed-document-reentry",
            useAnchoredCollectionView: true
        )
        let allItems = makeMixedTimelineItems(count: 240)
        let visibleItems = Array(allItems.suffix(80))
        applyTimelineItems(
            visibleItems,
            hiddenCount: allItems.count - visibleItems.count,
            nonce: nil,
            to: harness
        )

        // `currentIDs` is the rendered suffix, but viewport restoration must
        // retain the absolute ordinal from the complete timeline.
        harness.scrollController.updateTimelineItemOrder(allItems.map(\.id))
        let anchorID = "msg-180"
        let anchorIndex = try #require(harness.coordinator.currentIDs.firstIndex(of: anchorID))
        harness.collectionView.scrollToItem(
            at: IndexPath(item: anchorIndex, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(harness.collectionView, passes: 3)
        setTimelineUserScrollOffsetY(
            harness.collectionView,
            harness.collectionView.contentOffset.y + 37
        )
        harness.scrollController.detachFromBottomForUserScroll()
        // Pin the known anchor explicitly: the collection is windowed, while
        // the controller's saved ordinal comes from the full timeline order.
        harness.scrollController.updateViewportAnchor(itemID: anchorID, relativeY: -37)
        harness.scrollController.suspendForNavigation()

        let availableFullTimelineItemIDs = (0..<240).map { "replacement-\($0)" }
        let placement = try #require(harness.scrollController.initialPlacement(
            availableFullTimelineItemIDs: availableFullTimelineItemIDs,
            bottomItemID: "replacement-239"
        ))
        guard case .viewport(let restoration) = placement else {
            Issue.record("Expected detached viewport restoration, got \(placement)")
            return
        }

        #expect(restoration.itemID == "replacement-180")
        #expect(restoration.relativeY == -37)
    }
}

private struct NavigationResult {
    let reachedTarget: Bool
    let didHighlightTarget: Bool
    let highlightOverlayFrontmost: Bool
    let topVisible: String
    let visibleIDs: [String]
}

@MainActor
private func navigateFromDetachedTail(to targetID: String) async -> NavigationResult {
    let harness = makeWindowedTimelineHarness(
        sessionId: "session-outline-navigation-\(targetID)",
        useAnchoredCollectionView: true
    )
    let allItems = makeMixedTimelineItems(count: 120)
    let visibleTail = Array(allItems.suffix(40))

    applyTimelineItems(
        visibleTail,
        hiddenCount: allItems.count - visibleTail.count,
        nonce: nil,
        to: harness
    )

    harness.collectionView.scrollToItem(at: IndexPath(item: 15, section: 0), at: .top, animated: false)
    settleTimelineLayout(harness.collectionView, passes: 2)
    harness.coordinator.updateScrollState(harness.collectionView)
    harness.scrollController.detachFromBottomForUserScroll()

    harness.scrollController.requestNavigationHighlight(for: targetID)
    applyTimelineItems(
        allItems,
        hiddenCount: 0,
        nonce: 2,
        scrollTargetID: targetID,
        to: harness
    )

    let reachedTarget = await waitForTimelineCondition(timeoutMs: 500) {
        await MainActor.run {
            settleTimelineLayout(harness.collectionView, passes: 3)
            harness.coordinator.updateScrollState(harness.collectionView)
            return harness.scrollController.currentTopVisibleItemId == targetID
        }
    }

    let didHighlightTarget = await waitForTimelineCondition(timeoutMs: 400) {
        await MainActor.run {
            guard let highlightedCell = timelineCell(for: targetID, in: harness) else { return false }
            return highlightedCell.isShowingNavigationHighlightForTesting
        }
    }

    let highlightOverlayFrontmost = await MainActor.run {
        timelineCell(for: targetID, in: harness)?.isNavigationHighlightOverlayFrontmostForTesting ?? false
    }

    return NavigationResult(
        reachedTarget: reachedTarget,
        didHighlightTarget: didHighlightTarget,
        highlightOverlayFrontmost: highlightOverlayFrontmost,
        topVisible: harness.scrollController.currentTopVisibleItemId ?? "nil",
        visibleIDs: visibleTimelineIDs(in: harness)
    )
}

@MainActor
private func applyTimelineItems(
    _ items: [ChatItem],
    hiddenCount: Int,
    nonce: Int?,
    scrollTargetID: String? = nil,
    to harness: WindowedTimelineHarness
) {
    let scrollCommand: ChatTimelineScrollCommand? = if let nonce, let scrollTargetID {
        ChatTimelineScrollCommand(
            id: scrollTargetID,
            anchor: .top,
            animated: false,
            nonce: nonce
        )
    } else {
        nil
    }

    let config = makeTimelineConfiguration(
        items: items,
        hiddenCount: hiddenCount,
        isBusy: false,
        scrollCommand: scrollCommand,
        sessionId: harness.sessionId,
        reducer: harness.reducer,
        toolOutputStore: harness.toolOutputStore,
        toolArgsStore: harness.toolArgsStore,
        toolSegmentStore: harness.toolSegmentStore,
        connection: harness.connection,
        scrollController: harness.scrollController,
        audioPlayer: harness.audioPlayer
    )
    harness.coordinator.apply(configuration: config, to: harness.collectionView)
    settleTimelineLayout(harness.collectionView, passes: 2)
}

private func makeMixedTimelineItems(count: Int) -> [ChatItem] {
    (0..<count).map { index in
        if index.isMultiple(of: 2) {
            let text = Array(repeating: "Message \(index) line with enough text to wrap across the cell.", count: 4)
                .joined(separator: "\n")
            return .assistantMessage(
                id: "msg-\(index)",
                text: text,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let output = Array(repeating: "output \(index)", count: 6).joined(separator: "\n")
        return .toolCall(
            id: "tool-\(index)",
            tool: "bash",
            argsSummary: "printf 'row \(index)'",
            outputPreview: output,
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: true
        )
    }
}

@MainActor
private func visibleTimelineIDs(in harness: WindowedTimelineHarness) -> [String] {
    harness.collectionView.indexPathsForVisibleItems
        .sorted { $0.item < $1.item }
        .compactMap { indexPath in
            guard indexPath.item < harness.coordinator.currentIDs.count else { return nil }
            return harness.coordinator.currentIDs[indexPath.item]
        }
}

@MainActor
private func timelineCell(for itemID: String, in harness: WindowedTimelineHarness) -> SafeSizingCell? {
    guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID) else { return nil }
    return harness.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SafeSizingCell
}
