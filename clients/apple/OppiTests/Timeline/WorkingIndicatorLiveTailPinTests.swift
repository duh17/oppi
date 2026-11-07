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
        let workingID = ChatTimelineController.workingIndicatorID
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

/// A chat out of the window (a page pushed over it, another chat in front)
/// skips the timeline's forced layout and settles once when it returns. The
/// person must see what a timeline that stayed on screen shows: the same rows
/// at the same scroll position, whether they followed the live tail or were
/// reading back.
@Suite("Off-screen timeline settle")
@MainActor
struct OffscreenTimelineSettleTests {
    private let composerHeight: CGFloat = 80

    @Test func attachedTimelineHiddenThroughUpdatesReturnsToTheSameTail() throws {
        let visible = makeWindowedTimelineHarness(sessionId: "session-offscreen-attached-visible")
        let hidden = makeWindowedTimelineHarness(sessionId: "session-offscreen-attached-hidden")
        defer {
            hideTestWindow(visible.window)
            hideTestWindow(hidden.window)
        }
        let history = historyItems()
        for windowed in [visible, hidden] {
            apply(history + [reply(round: 0)], working: true, to: windowed)
            settleTimelineLayout(windowed.collectionView)
            pinToBottom(windowed)
        }

        let host = takeOffScreen(hidden)
        for round in 1...8 {
            let items = history + [reply(round: round)]
            apply(items, working: round % 2 == 0, to: visible)
            settleTimelineLayout(visible.collectionView)
            apply(items, working: round % 2 == 0, to: hidden)
        }
        bringBack(hidden, from: host)

        try expectSameViewport(hidden, as: visible)
        #expect(hidden.scrollController.isCurrentlyNearBottom)
        let maxOffset = timelineMaxOffset(hidden.collectionView)
        #expect(
            abs(hidden.collectionView.contentOffset.y - maxOffset) <= 1,
            "returned off the live tail: offset=\(hidden.collectionView.contentOffset.y) max=\(maxOffset)"
        )
    }

    @Test func detachedTimelineHiddenThroughUpdatesReturnsToTheSameReaderPosition() throws {
        let visible = makeWindowedTimelineHarness(sessionId: "session-offscreen-detached-visible")
        let hidden = makeWindowedTimelineHarness(sessionId: "session-offscreen-detached-hidden")
        defer {
            hideTestWindow(visible.window)
            hideTestWindow(hidden.window)
        }
        let history = historyItems()
        for windowed in [visible, hidden] {
            apply(history + [reply(round: 0)], working: true, to: windowed)
            settleTimelineLayout(windowed.collectionView)
            pinToBottom(windowed)
            detach(windowed)
        }
        let anchorID = try #require(firstReadRowID(in: visible))
        let anchorScreenY = try #require(screenY(of: anchorID, in: visible))

        let host = takeOffScreen(hidden)
        for round in 1...8 {
            // Rows land below the reader: a tool call appended at the tail
            // and the working row coming and going.
            var items = history + [reply(round: round)]
            if round >= 4 {
                items.append(.toolCall(
                    id: "offscreen-tool",
                    tool: "bash",
                    argsSummary: "swift test",
                    outputPreview: "ok",
                    outputByteCount: 8,
                    isError: false,
                    isDone: round >= 6
                ))
            }
            apply(items, working: round % 2 == 0, to: visible)
            settleTimelineLayout(visible.collectionView)
            apply(items, working: round % 2 == 0, to: hidden)
        }
        bringBack(hidden, from: host)

        try expectSameViewport(hidden, as: visible)
        #expect(!hidden.scrollController.isCurrentlyNearBottom)
        let visibleY = try #require(screenY(of: anchorID, in: visible))
        let hiddenY = try #require(screenY(of: anchorID, in: hidden))
        #expect(abs(visibleY - anchorScreenY) <= 1, "precondition: the visible reader stayed put")
        #expect(abs(hiddenY - visibleY) <= 1, "reader row moved: hidden=\(hiddenY) visible=\(visibleY)")
    }

    @Test func detachedTimelineHiddenWhileRowsAboveTheReaderChangeReturnsToTheSameReaderPosition() throws {
        let visible = makeWindowedTimelineHarness(sessionId: "session-offscreen-above-visible")
        let hidden = makeWindowedTimelineHarness(sessionId: "session-offscreen-above-hidden")
        defer {
            hideTestWindow(visible.window)
            hideTestWindow(hidden.window)
        }
        // A live thinking row sits above the reader; earlier rows wait behind
        // the window's top.
        let thinkingID = "offscreen-thinking"
        var full = historyItems()
        full.insert(
            .thinking(id: thinkingID, preview: "plan", hasMore: false, isDone: false),
            at: 16
        )
        for windowed in [visible, hidden] {
            apply(Array(full[12...]) + [reply(round: 0)], hiddenCount: 12, working: true, to: windowed)
            settleTimelineLayout(windowed.collectionView)
            pinToBottom(windowed)
            detach(windowed)
        }
        let anchorID = try #require(firstReadRowID(in: visible))
        let thinkingIndex = try #require(visible.coordinator.currentIDs.firstIndex(of: thinkingID))
        let anchorIndex = try #require(visible.coordinator.currentIDs.firstIndex(of: anchorID))
        #expect(thinkingIndex < anchorIndex, "precondition: the thinking row is above the reader")
        let anchorScreenY = try #require(screenY(of: anchorID, in: visible))

        let host = takeOffScreen(hidden)
        for round in 1...6 {
            // Earlier rows are revealed above the reader, then the thinking
            // row above it grows, while the working row comes and goes.
            full[16] = .thinking(
                id: thinkingID,
                preview: String(repeating: "Thinking round \(round). ", count: round * 12),
                hasMore: true,
                isDone: false
            )
            let hiddenCount = round == 1 ? 12 : 4
            let items = Array(full[hiddenCount...]) + [reply(round: round)]
            apply(items, hiddenCount: hiddenCount, working: round % 2 == 0, to: visible)
            settleTimelineLayout(visible.collectionView)
            apply(items, hiddenCount: hiddenCount, working: round % 2 == 0, to: hidden)
        }
        bringBack(hidden, from: host)

        try expectSameViewport(hidden, as: visible)
        #expect(!hidden.scrollController.isCurrentlyNearBottom)
        let visibleY = try #require(screenY(of: anchorID, in: visible))
        let hiddenY = try #require(screenY(of: anchorID, in: hidden))
        #expect(abs(visibleY - anchorScreenY) <= 1, "precondition: the visible reader stayed put")
        #expect(abs(hiddenY - visibleY) <= 1, "reader row moved: hidden=\(hiddenY) visible=\(visibleY)")
    }

    // MARK: - Helpers

    /// The chat's view leaves the window; the timeline stays in it.
    private func takeOffScreen(_ windowed: WindowedTimelineHarness) -> UIView {
        let host = UIView(frame: windowed.window.bounds)
        host.addSubview(windowed.collectionView)
        #expect(windowed.collectionView.window == nil)
        return host
    }

    /// Back in the window, then the layout passes the next frames run.
    private func bringBack(_ windowed: WindowedTimelineHarness, from host: UIView) {
        windowed.window.addSubview(windowed.collectionView)
        #expect(host.subviews.isEmpty)
        settleTimelineLayout(windowed.collectionView)
    }

    private func expectSameViewport(
        _ hidden: WindowedTimelineHarness,
        as visible: WindowedTimelineHarness
    ) throws {
        #expect(hidden.coordinator.currentIDs == visible.coordinator.currentIDs)
        #expect(
            abs(hidden.collectionView.contentSize.height - visible.collectionView.contentSize.height) <= 1,
            "content height: hidden=\(hidden.collectionView.contentSize.height) visible=\(visible.collectionView.contentSize.height)"
        )
        #expect(
            abs(hidden.collectionView.contentOffset.y - visible.collectionView.contentOffset.y) <= 1,
            "offset: hidden=\(hidden.collectionView.contentOffset.y) visible=\(visible.collectionView.contentOffset.y)"
        )
        #expect(visibleRowIDs(in: hidden) == visibleRowIDs(in: visible))
    }

    private func visibleRowIDs(in windowed: WindowedTimelineHarness) -> [String] {
        let collectionView = windowed.collectionView
        let viewport = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        return windowed.coordinator.currentIDs.enumerated().compactMap { index, id in
            guard let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
                  attributes.frame.intersects(viewport) else { return nil }
            return id
        }
    }

    private func firstReadRowID(in windowed: WindowedTimelineHarness) -> String? {
        let collectionView = windowed.collectionView
        let readingTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return windowed.coordinator.currentIDs.enumerated().first { index, _ in
            guard let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else {
                return false
            }
            return attributes.frame.maxY > readingTop
        }?.element
    }

    private func screenY(of itemID: String, in windowed: WindowedTimelineHarness) -> CGFloat? {
        guard let index = windowed.coordinator.currentIDs.firstIndex(of: itemID),
              let attributes = windowed.collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else {
            return nil
        }
        return attributes.frame.minY - windowed.collectionView.contentOffset.y
    }

    private func apply(
        _ items: [ChatItem],
        hiddenCount: Int = 0,
        working: Bool,
        to windowed: WindowedTimelineHarness
    ) {
        var config = makeTimelineConfiguration(
            items: items,
            hiddenCount: hiddenCount,
            isBusy: true,
            streamingAssistantID: replyID,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer,
            bottomOverlap: composerHeight
        )
        config.showsWorkingIndicator = working
        windowed.coordinator.apply(configuration: config, to: windowed.collectionView)
    }

    private func pinToBottom(_ windowed: WindowedTimelineHarness) {
        let collectionView = windowed.collectionView
        collectionView.layoutIfNeeded()
        (collectionView as? AnchoredCollectionView)?.applyOffsetCorrection(timelineMaxOffset(collectionView))
        settleTimelineLayout(collectionView)
        windowed.scrollController.updateNearBottom(true)
        windowed.coordinator.updateScrollState(collectionView)
    }

    /// The reader drags halfway up the history.
    private func detach(_ windowed: WindowedTimelineHarness) {
        let collectionView = windowed.collectionView
        guard let anchored = collectionView as? AnchoredCollectionView else { return }
        anchored.testIsTracking = true
        anchored.testIsDragging = true
        windowed.coordinator.scrollViewWillBeginDragging(collectionView)
        setTimelineUserScrollOffsetY(collectionView, timelineMaxOffset(collectionView) * 0.5)
        windowed.coordinator.scrollViewDidScroll(collectionView)
        anchored.testIsTracking = false
        anchored.testIsDragging = false
        windowed.coordinator.scrollViewDidEndDragging(collectionView, willDecelerate: false)
        settleTimelineLayout(collectionView)
    }

    private let replyID = "offscreen-reply"

    private func reply(round: Int) -> ChatItem {
        .assistantMessage(
            id: replyID,
            text: (0...(round * 3)).map { "Streaming line \($0) of the live reply." }.joined(separator: "\n"),
            timestamp: Date(timeIntervalSince1970: 1_700_001_000)
        )
    }

    private func historyItems() -> [ChatItem] {
        (0..<36).map { index in
            .assistantMessage(
                id: "offscreen-history-\(index)",
                text: String(repeating: "History \(index) line. ", count: 12),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
    }

    private func timelineMaxOffset(_ collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
    }
}
