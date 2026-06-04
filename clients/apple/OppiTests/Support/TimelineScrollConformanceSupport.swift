import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
enum TimelineScrollConformanceAnchorEdge {
    case top
    case bottom
}

@MainActor
func timelineConformanceMaxOffsetY(_ collectionView: UICollectionView) -> CGFloat {
    let insets = collectionView.adjustedContentInset
    return max(
        -insets.top,
        collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
    )
}

@MainActor
func timelineConformanceDistanceFromBottom(_ collectionView: UICollectionView) -> CGFloat {
    timelineConformanceMaxOffsetY(collectionView) - collectionView.contentOffset.y
}

@MainActor
final class TimelineScrollConformanceHarness {
    let windowed: WindowedTimelineHarness
    private(set) var items: [ChatItem]
    let streamingID = "stream-tail"

    init(sessionId: String, itemCount: Int = 26) {
        self.windowed = makeWindowedTimelineHarness(
            sessionId: sessionId,
            useAnchoredCollectionView: true
        )
        self.items = Self.makeItems(
            count: itemCount,
            toolArgsStore: windowed.toolArgsStore,
            toolOutputStore: windowed.toolOutputStore,
            streamingID: streamingID
        )
    }

    var collectionView: UICollectionView { windowed.collectionView }
    var scrollController: ChatScrollController { windowed.scrollController }
    var reducer: TimelineReducer { windowed.reducer }
    var coordinator: ChatTimelineCollectionHost.Controller { windowed.coordinator }

    func apply(isBusy: Bool = true, streamingID explicitStreamingID: String? = nil) {
        windowed.applyItems(
            items,
            isBusy: isBusy,
            streamingID: explicitStreamingID ?? (isBusy ? streamingID : nil)
        )
        settleTimelineLayout(collectionView, passes: 3)
    }

    func startAttachedAtBottom(isBusy: Bool = true) {
        apply(isBusy: isBusy)
        collectionView.scrollToItem(
            at: IndexPath(item: coordinator.currentIDs.count - 1, section: 0),
            at: .bottom,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 3)
        scrollController.updateNearBottom(true)
        coordinator.updateScrollState(collectionView)
    }

    func userScrollsUpToRead(itemID: String) {
        guard let index = index(of: itemID) else {
            Issue.record("Missing item \(itemID)")
            return
        }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 3)
        scrollController.detachFromBottomForUserScroll()
        if let anchored = collectionView as? AnchoredCollectionView {
            anchored.isDetachedFromBottom = true
            anchored.captureDetachedAnchor()
        }
    }

    func growStreamingText(round: Int) {
        replaceItem(id: streamingID) {
            .assistantMessage(
                id: streamingID,
                text: String(repeating: "Streaming round \(round). ", count: max(1, round) * 16),
                timestamp: Date()
            )
        }
    }

    func appendToolRows(count: Int) {
        let start = items.count
        for offset in 0..<count {
            let id = "appended-tool-\(start + offset)"
            windowed.toolArgsStore.set(["command": .string("echo appended \(offset)")], for: id)
            windowed.toolOutputStore.append("appended output \(offset)", to: id)
            items.append(.toolCall(
                id: id,
                tool: "bash",
                argsSummary: "echo appended \(offset)",
                outputPreview: "appended output \(offset)",
                outputByteCount: 64,
                isError: false,
                isDone: true
            ))
        }
    }

    func growToolOutput(id: String, lineCount: Int) {
        windowed.toolOutputStore.replace(String(repeating: "grown output line\n", count: lineCount), for: id)
        replaceItem(id: id) {
            .toolCall(
                id: id,
                tool: "bash",
                argsSummary: "echo grown",
                outputPreview: String(repeating: "grown output line\n", count: min(lineCount, 8)),
                outputByteCount: lineCount * 18,
                isError: false,
                isDone: true
            )
        }
    }

    func expandTool(id: String) {
        tapTool(id: id)
    }

    func collapseTool(id: String) {
        tapTool(id: id)
    }

    func tapTool(id: String) {
        guard let index = index(of: id) else {
            Issue.record("Missing tool \(id)")
            return
        }
        coordinator.collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))
        settleTimelineLayout(collectionView, passes: 4)
    }

    func screenY(of itemID: String, edge: TimelineScrollConformanceAnchorEdge) -> CGFloat? {
        guard let index = index(of: itemID),
              let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else {
            return nil
        }
        let y = switch edge {
        case .top: attrs.frame.minY
        case .bottom: attrs.frame.maxY
        }
        return y - collectionView.contentOffset.y
    }

    func assertTailVisible() {
        guard let lastIndex = coordinator.currentIDs.indices.last,
              let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: lastIndex, section: 0)) else {
            Issue.record("Missing tail layout attributes")
            return
        }
        let bottom = collectionView.contentOffset.y
            + collectionView.bounds.height
            - collectionView.adjustedContentInset.bottom
        #expect(attrs.frame.maxY <= bottom + 140, "tail should remain visible")
    }

    func assertExactBottom(maxDistance: CGFloat = 12) {
        let distance = timelineConformanceDistanceFromBottom(collectionView)
        #expect(distance <= maxDistance, "expected exact bottom, distance=\(distance)")
    }

    func assertAnchorStable(
        itemID: String,
        edge: TimelineScrollConformanceAnchorEdge,
        before: CGFloat?,
        maxDrift: CGFloat = 8
    ) {
        guard let before, let after = screenY(of: itemID, edge: edge) else {
            Issue.record("Missing anchor for \(itemID)")
            return
        }
        let drift = abs(after - before)
        #expect(drift <= maxDrift, "anchor drifted \(drift)pt for \(itemID)")
    }

    func expandedInnerScrollViews(for toolID: String) -> [UIScrollView] {
        guard let index = index(of: toolID),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) else {
            return []
        }
        return timelineAllScrollViews(in: cell.contentView).filter { $0 !== collectionView }
    }

    func index(of itemID: String) -> Int? {
        items.firstIndex { $0.id == itemID }
    }

    private func replaceItem(id: String, replacement: () -> ChatItem) {
        guard let index = index(of: id) else {
            Issue.record("Missing item \(id)")
            return
        }
        items[index] = replacement()
    }

    private static func makeItems(
        count: Int,
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore,
        streamingID: String
    ) -> [ChatItem] {
        var items: [ChatItem] = []
        for index in 0..<count {
            items.append(.assistantMessage(
                id: "message-\(index)",
                text: String(repeating: "History message \(index). ", count: index.isMultiple(of: 3) ? 18 : 8),
                timestamp: Date()
            ))

            let toolID = "tool-\(index)"
            toolArgsStore.set(["command": .string("echo \(index)")], for: toolID)
            toolOutputStore.append(String(repeating: "output \(index)\n", count: 6), to: toolID)
            items.append(.toolCall(
                id: toolID,
                tool: "bash",
                argsSummary: "echo \(index)",
                outputPreview: "output \(index)",
                outputByteCount: 128,
                isError: false,
                isDone: true
            ))
        }
        items.append(.assistantMessage(id: streamingID, text: "Starting", timestamp: Date()))
        return items
    }
}
