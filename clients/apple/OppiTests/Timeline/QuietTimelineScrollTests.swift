import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Quiet timeline scroll follow")
@MainActor
struct QuietTimelineScrollTests {
    @Test func attachedQuietModeFollowsAssistantAndLiveWorkStrip() {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-quiet-tail",
            useAnchoredCollectionView: true
        )
        let assistantID = "assistant-live"
        var items = quietHistoryItems() + [
            .assistantMessage(id: assistantID, text: "Starting", timestamp: Date()),
        ]

        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
        pinToBottom(windowed)

        items.append(.thinking(id: "think-1", preview: "plan", hasMore: false, isDone: false))
        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
        expectAttachedTail(
            windowed,
            mustContain: ["quiet-work-line:think-1", ChatTimelineCollectionHost.workingIndicatorID],
            label: "live work strip insert"
        )

        var previousOffsetY = windowed.collectionView.contentOffset.y
        for round in 1...8 {
            items[items.count - 2] = .assistantMessage(
                id: assistantID,
                text: String(repeating: "Streaming round \(round). ", count: round * 16),
                timestamp: Date()
            )
            applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
            previousOffsetY = expectCalmAttachedFollow(
                windowed,
                previousOffsetY: previousOffsetY,
                round: round,
                label: "quiet assistant streaming"
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
        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
        expectAttachedTail(
            windowed,
            mustContain: ["quiet-work-line:think-1", ChatTimelineCollectionHost.workingIndicatorID],
            label: "quiet tool fold"
        )
        #expect(windowed.collectionView.contentOffset.y >= previousOffsetY - 4)
    }

    @Test func quietModeStillDetachesOnUpwardUserScroll() {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-quiet-detach",
            useAnchoredCollectionView: true
        )
        var items = quietHistoryItems() + [
            .assistantMessage(id: "a1", text: "Done", timestamp: Date()),
            .thinking(id: "think-1", preview: "next", hasMore: false, isDone: false),
        ]
        applyQuiet(items, to: windowed, isBusy: true)
        pinToBottom(windowed)

        let metricsView = TimelineScrollMetricsCollectionView(frame: windowed.collectionView.bounds)
        metricsView.testContentSize = windowed.collectionView.contentSize
        metricsView.testVisibleIndexPaths = windowed.collectionView.indexPathsForVisibleItems
        metricsView.contentOffset = windowed.collectionView.contentOffset
        metricsView.testIsTracking = true
        windowed.coordinator.scrollViewWillBeginDragging(metricsView)
        metricsView.contentOffset = CGPoint(
            x: 0,
            y: timelineOffsetY(forDistanceFromBottom: 150, in: metricsView)
        )
        windowed.coordinator.scrollViewDidScroll(metricsView)
        #expect(!windowed.scrollController.isCurrentlyNearBottom)
    }

    @Test func detachedQuietModeDoesNotFollowLiveWorkStripInsertOrFold() throws {
        let windowed = makeWindowedTimelineHarness(
            sessionId: "session-quiet-detached-strip",
            useAnchoredCollectionView: true
        )
        let collectionView = windowed.collectionView
        let anchored = try #require(collectionView as? AnchoredCollectionView)
        let assistantID = "assistant-live"
        var items = quietHistoryItems() + [
            .assistantMessage(id: assistantID, text: "Starting", timestamp: Date()),
        ]

        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
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

        let offsetBeforeInsert = collectionView.contentOffset.y

        items.append(.thinking(id: "think-1", preview: "plan", hasMore: false, isDone: false))
        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
        #expect(windowed.coordinator.currentIDs.contains("quiet-work-line:think-1"))
        #expect(
            !windowed.scrollController.isCurrentlyNearBottom,
            "live work strip insert chased the tail"
        )

        items.append(.toolCall(
            id: "bash-1",
            tool: "bash",
            argsSummary: "swift test",
            outputPreview: "ok",
            outputByteCount: 8,
            isError: false,
            isDone: false
        ))
        applyQuiet(items, to: windowed, isBusy: true, streamingID: assistantID)
        #expect(
            !windowed.scrollController.isCurrentlyNearBottom,
            "quiet tool fold chased the tail"
        )

        let distanceFromBottom = timelineMaxOffset(collectionView) - collectionView.contentOffset.y
        #expect(
            distanceFromBottom >= 120,
            "detached viewport chased the live tail, distance=\(distanceFromBottom)"
        )
        #expect(abs(collectionView.contentOffset.y - offsetBeforeInsert) < 24)
    }

    private func quietHistoryItems() -> [ChatItem] {
        (0..<36).map { index in
            .assistantMessage(
                id: "history-\(index)",
                text: String(repeating: "History \(index) line. ", count: 12),
                timestamp: Date()
            )
        }
    }

    private func applyQuiet(
        _ items: [ChatItem],
        to windowed: WindowedTimelineHarness,
        isBusy: Bool,
        streamingID: String? = nil
    ) {
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: isBusy,
            expandedTurnIDs: []
        )
        let workLines = projection.rows.compactMap { row -> QuietTimelineWorkLine? in
            guard case .quietWork(let line) = row else { return nil }
            return line
        }
        let config = makeTimelineConfiguration(
            items: projection.rows.compactMap { row in
                guard case .item(let item) = row else { return nil }
                return item
            },
            fullTimelineItemIDs: projection.fullTimelineItemIDs,
            displayRows: projection.rows,
            workLineByID: Dictionary(uniqueKeysWithValues: workLines.map { ($0.id, $0) }),
            isBusy: isBusy,
            streamingAssistantID: streamingID,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
        windowed.collectionView.layoutIfNeeded()
    }

    private func pinToBottom(_ windowed: WindowedTimelineHarness) {
        windowed.collectionView.layoutIfNeeded()
        let last = IndexPath(item: windowed.coordinator.currentIDs.count - 1, section: 0)
        windowed.collectionView.scrollToItem(at: last, at: .bottom, animated: false)
        windowed.collectionView.layoutIfNeeded()
        windowed.scrollController.updateNearBottom(true)
        windowed.coordinator.updateScrollState(windowed.collectionView)
    }

    private func expectAttachedTail(
        _ windowed: WindowedTimelineHarness,
        mustContain ids: [String],
        label: String
    ) {
        for id in ids {
            #expect(windowed.coordinator.currentIDs.contains(id), "\(label) missing \(id)")
        }
        let maxOffsetY = timelineMaxOffset(windowed.collectionView)
        let distanceFromBottom = maxOffsetY - windowed.collectionView.contentOffset.y
        #expect(windowed.scrollController.isCurrentlyNearBottom, "\(label) detached")
        #expect(
            distanceFromBottom < 120,
            "\(label) lost the live tail, distance=\(distanceFromBottom)"
        )
    }

    private func expectCalmAttachedFollow(
        _ windowed: WindowedTimelineHarness,
        previousOffsetY: CGFloat,
        round: Int,
        label: String
    ) -> CGFloat {
        let offsetY = windowed.collectionView.contentOffset.y
        let distanceFromBottom = timelineMaxOffset(windowed.collectionView) - offsetY
        #expect(
            offsetY >= previousOffsetY - 4,
            "\(label) offset bounced upward by \(previousOffsetY - offsetY)pt on round \(round)"
        )
        #expect(
            distanceFromBottom < 120,
            "\(label) lost the live tail on round \(round), distance=\(distanceFromBottom)"
        )
        #expect(windowed.scrollController.isCurrentlyNearBottom, "\(label) detached on round \(round)")
        return offsetY
    }

    private func timelineMaxOffset(_ collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
    }
}
