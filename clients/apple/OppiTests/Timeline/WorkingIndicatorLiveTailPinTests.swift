import Foundation
import Testing
import UIKit
@testable import Oppi

/// Busy live-tail follow must keep the working-indicator row above the composer
/// while an existing thinking/assistant row grows in place. New-row insert
/// already exact-pins; in-place same-ID growth must not bury the indicator.
@Suite("Working indicator live tail pin")
@MainActor
struct WorkingIndicatorLiveTailPinTests {
    private let composerHeight: CGFloat = 80
    private let liveTailMinimumBottomPadding: CGFloat = 16

    @Test func attachedBusyInPlaceGrowthKeepsWorkingIndicatorAboveComposer() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-working-indicator-live-tail",
            useAnchoredCollectionView: true
        )
        let assistantID = "assistant-live"
        let thinkingID = "think-1"
        var items = historyItems() + [
            .thinking(id: thinkingID, preview: "plan", hasMore: false, isDone: false),
            .assistantMessage(id: assistantID, text: "Starting", timestamp: Date()),
        ]

        applyFullTimeline(items, to: windowed, isBusy: true)
        pinToBottom(windowed)
        try expectWorkingIndicatorAboveComposer(windowed, label: "precondition pin")

        var previousContentHeight = windowed.collectionView.contentSize.height

        for round in 1...6 {
            items[items.count - 2] = .thinking(
                id: thinkingID,
                preview: String(repeating: "Thinking round \(round). ", count: round * 12),
                hasMore: true,
                isDone: false
            )
            items[items.count - 1] = .assistantMessage(
                id: assistantID,
                text: growingAssistantText(round: round),
                timestamp: Date()
            )
            applyFullTimeline(items, to: windowed, isBusy: true)
            let contentHeight = windowed.collectionView.contentSize.height
            #expect(
                contentHeight > previousContentHeight + 20,
                "precondition: round \(round) must grow in place, \(previousContentHeight) → \(contentHeight)"
            )
            previousContentHeight = contentHeight
            try expectWorkingIndicatorAboveComposer(
                windowed,
                label: "in-place growth round \(round)"
            )
        }

        items.append(.toolCall(
            id: "bash-1",
            tool: "bash",
            argsSummary: "swift test",
            outputPreview: "ok",
            outputByteCount: 8,
            isError: false,
            isDone: false
        ))
        applyFullTimeline(items, to: windowed, isBusy: true)
        try expectWorkingIndicatorAboveComposer(windowed, label: "new-row insert")
    }

    @Test func detachedInPlaceGrowthDoesNotYankBackToTail() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-working-indicator-detached",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)
        let assistantID = "assistant-live"
        let thinkingID = "think-1"
        var items = historyItems() + [
            .thinking(id: thinkingID, preview: "plan", hasMore: false, isDone: false),
            .assistantMessage(id: assistantID, text: "Starting", timestamp: Date()),
        ]

        applyFullTimeline(items, to: windowed, isBusy: true)
        pinToBottom(windowed)

        let maxOffsetY = timelineMaxOffset(collectionView)
        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, max(0, maxOffsetY - 150))
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        #expect(!windowed.scrollController.isCurrentlyNearBottom)

        let offsetBeforeGrowth = collectionView.contentOffset.y

        for round in 1...6 {
            items[items.count - 2] = .thinking(
                id: thinkingID,
                preview: String(repeating: "Thinking round \(round). ", count: round * 12),
                hasMore: true,
                isDone: false
            )
            items[items.count - 1] = .assistantMessage(
                id: assistantID,
                text: growingAssistantText(round: round),
                timestamp: Date()
            )
            applyFullTimeline(items, to: windowed, isBusy: true)
        }

        #expect(
            !windowed.scrollController.isCurrentlyNearBottom,
            "in-place growth yanked a detached reader back to the tail"
        )
        let distanceFromBottom = timelineMaxOffset(collectionView) - collectionView.contentOffset.y
        #expect(
            distanceFromBottom >= 120,
            "detached viewport chased the live tail, distance=\(distanceFromBottom)"
        )
        #expect(abs(collectionView.contentOffset.y - offsetBeforeGrowth) < 24)
    }

    private func historyItems() -> [ChatItem] {
        (0..<36).map { index in
            .assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index) line. ", count: 12),
                timestamp: Date()
            )
        }
    }

    private func growingAssistantText(round: Int) -> String {
        (0..<(round * 8)).map { line in
            "Streaming round \(round) line \(line)."
        }.joined(separator: "\n")
    }

    private func applyFullTimeline(
        _ items: [ChatItem],
        to windowed: WindowedTimelineHarness,
        isBusy: Bool
    ) {
        // Omit streamingAssistantID so SafeSizingCell does not reuse a 340ms
        // cached height. The 260ms busy-tail throttle is what this suite
        // stresses: same-ID growth must still keep the working row pinned.
        let config = makeTimelineConfiguration(
            items: items,
            isBusy: isBusy,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: composerHeight
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        settleTimelineLayout(windowed.collectionView)
    }

    private func pinToBottom(_ windowed: WindowedTimelineHarness) {
        let collectionView = windowed.collectionView
        collectionView.layoutIfNeeded()
        let targetOffsetY = timelineMaxOffset(collectionView)
        if let anchored = collectionView as? AnchoredCollectionView {
            anchored.applyOffsetCorrection(targetOffsetY)
        } else {
            collectionView.contentOffset.y = targetOffsetY
        }
        settleTimelineLayout(collectionView)
        windowed.scrollController.updateNearBottom(true)
        windowed.coordinator.updateScrollState(collectionView)
    }

    private func expectWorkingIndicatorAboveComposer(
        _ windowed: WindowedTimelineHarness,
        label: String
    ) throws {
        let collectionView = windowed.collectionView
        let workingID = ChatTimelineCollectionHost.workingIndicatorID
        #expect(
            windowed.coordinator.currentIDs.last == workingID,
            "\(label) missing working indicator at tail"
        )
        let index = try #require(windowed.coordinator.currentIDs.firstIndex(of: workingID))
        let attrs = try #require(
            collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        )
        let insets = collectionView.adjustedContentInset
        let viewportBottomY = collectionView.contentOffset.y
            + collectionView.bounds.height
            - insets.bottom
        // keepLiveTailVisible asks for 16pt, but the last row can only sit
        // sectionInsets.bottom (8pt) above contentSize.height. Max-offset
        // therefore caps padding at that remaining space.
        let padding = viewportBottomY - attrs.frame.maxY
        let achievablePadding = min(
            liveTailMinimumBottomPadding,
            collectionView.contentSize.height - attrs.frame.maxY
        )
        #expect(
            padding + 1 >= achievablePadding,
            "\(label) working indicator under composer, padding=\(padding) achievable=\(achievablePadding) maxY=\(attrs.frame.maxY) viewportBottomY=\(viewportBottomY) offset=\(collectionView.contentOffset.y) contentH=\(collectionView.contentSize.height) insetBottom=\(insets.bottom)"
        )
        #expect(windowed.scrollController.isCurrentlyNearBottom, "\(label) detached")
    }

    private func timelineMaxOffset(_ collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
    }
}
