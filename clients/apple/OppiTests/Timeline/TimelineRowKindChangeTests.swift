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

    private func contentConfiguration(of itemID: String, in harness: WindowedTimelineHarness) -> (any UIContentConfiguration)? {
        guard let index = harness.coordinator.currentIDs.firstIndex(of: itemID),
              let cell = harness.collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return nil }
        return cell.contentConfiguration
    }
}
