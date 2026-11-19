import Foundation
import Testing
import UIKit
@testable import Oppi

/// A row can change kind under its ID: a system note that becomes a
/// compaction marker, a custom card that gains terminal output. Its cell came
/// from the old kind's registration, and UIKit refuses to reconfigure a cell
/// (a prefetched one included) through another registration: it throws
/// "Attempted to dequeue a cell for a different registration ... when
/// reconfiguring an item", which crashed the app. The row redraws as its new
/// kind instead.
@Suite("TimelineRowKindChange")
@MainActor
struct TimelineRowKindChangeTests {
    private let timestamp = Date(timeIntervalSince1970: 0)

    @Test(arguments: [false, true])
    func aRowThatChangesKindRedrawsAsItsNewKind(isBusy: Bool) {
        let harness = makeWindowedTimelineHarness(sessionId: "row-kind-change")
        let user = ChatItem.userMessage(id: "user-1", text: "Compact, please", timestamp: timestamp)

        harness.applyItems([user, .systemEvent(id: "event-1", message: "Model changed")], isBusy: isBusy)
        #expect(contentConfiguration(of: "event-1", in: harness) is SystemTimelineRowConfiguration)

        harness.applyItems([user, .systemEvent(id: "event-1", message: "Compacting context...")], isBusy: isBusy)
        #expect(contentConfiguration(of: "event-1", in: harness) is CompactionTimelineRowConfiguration)

        harness.applyItems([user, .systemEvent(id: "event-1", message: "Model changed again")], isBusy: isBusy)
        #expect(contentConfiguration(of: "event-1", in: harness) is SystemTimelineRowConfiguration)
    }

    /// UIKit keeps the cells of rows that just scrolled off screen and puts
    /// them back without the data source when the rows return. A kept cell
    /// with a pending redraw is reconfigured on its way back through the cell
    /// provider, which threw when the row's kind had changed meanwhile in an
    /// apply that did not count the row as changed: during streaming that
    /// apply compares only rows expected to change, and a card that gains
    /// terminal output is not one. Without the pending redraw the kept cell
    /// came back drawn as the old kind.
    ///
    /// It needs a scene window (UIKit keeps no cells for a sceneless one) and
    /// a plain collection view (the anchored one holds its reading position
    /// against programmatic scrolling).
    @Test(arguments: [true, false])
    func aRowThatChangesKindOffScreenComesBackAsItsNewKind(pendingRedraw: Bool) {
        let window = makeSceneWindow()
        defer { hideTestWindow(window) }
        let harness = makeWindowedTimelineHarness(
            sessionId: "row-kind-change-offscreen",
            useAnchoredCollectionView: false,
            window: window
        )
        let collectionView = harness.collectionView
        func items(cardTitle: String = "Card", terminal: Bool = false, reply: String = "Working") -> [ChatItem] {
            var card = TraceEventPresentation(kind: "custom", title: cardTitle, subtitle: nil,
                status: "completed", body: "producer command", fields: nil, accent: "success")
            if terminal {
                card.output = .init(kind: "terminal", entryId: "1", command: "producer command", truncated: nil)
            }
            return [.customEvent(id: "card", message: "Card", presentation: card)]
                + (1..<40).map { .userMessage(id: "user-\($0)", text: "Message \($0)", timestamp: timestamp) }
                + [.assistantMessage(id: "reply", text: reply, timestamp: timestamp)]
        }
        func scroll(by step: CGFloat) {
            for _ in 0..<14 {
                let y = max(0, collectionView.contentOffset.y + step)
                collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let cardIndex = IndexPath(item: 0, section: 0)

        harness.applyItems(items(), isBusy: false)
        collectionView.setContentOffset(.zero, animated: false)
        collectionView.layoutIfNeeded()
        #expect(contentConfiguration(of: "card", in: harness) is CustomTimelineRowConfiguration)
        scroll(by: 14)
        #expect(!collectionView.indexPathsForVisibleItems.contains(cardIndex))

        if pendingRedraw {
            harness.applyItems(items(cardTitle: "Card, renamed"), isBusy: false)
        }
        harness.applyItems(
            items(cardTitle: pendingRedraw ? "Card, renamed" : "Card", terminal: true, reply: "Working on it"),
            isBusy: true,
            streamingID: "reply"
        )
        // The reload is owed once: the off-screen row has no cell now, and a
        // later apply must not reload it again.
        #expect(harness.coordinator.cellKindChangedIDs().isEmpty)
        scroll(by: -14)

        #expect(collectionView.indexPathsForVisibleItems.contains(cardIndex))
        #expect(contentConfiguration(of: "card", in: harness) is CollapsedToolTimelineRowConfiguration)
    }

    private func contentConfiguration(of itemID: String, in harness: WindowedTimelineHarness) -> (any UIContentConfiguration)? {
        guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID),
              let cell = harness.collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return nil }
        return cell.contentConfiguration
    }
}
