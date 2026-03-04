import Foundation
import Testing
@testable import Oppi

@Suite("TimelineSnapshotApplier")
struct TimelineSnapshotApplierTests {
    @MainActor
    @Test func largeTimelineReconfigureIDsAreStableAndVisibleOnly() {
        let timelineIDs = (0..<620).map { "item-\($0)" }
        let nextIDs = [ChatTimelineCollectionHost.loadMoreID] + timelineIDs
        let timestamp = Date(timeIntervalSince1970: 0)

        var nextItemByID: [String: ChatItem] = [:]
        var previousItemByID: [String: ChatItem] = [:]

        for id in timelineIDs {
            let stable = ChatItem.assistantMessage(
                id: id,
                text: "stable-\(id)",
                timestamp: timestamp
            )
            nextItemByID[id] = stable
            previousItemByID[id] = stable
        }

        let changedIDs = ["item-4", "item-250", "item-519"]
        for id in changedIDs {
            nextItemByID[id] = .assistantMessage(
                id: id,
                text: "updated-\(id)",
                timestamp: timestamp
            )
        }

        nextItemByID["orphan-next-only"] = .assistantMessage(
            id: "orphan-next-only",
            text: "orphan",
            timestamp: timestamp
        )
        previousItemByID["stale-removed"] = .assistantMessage(
            id: "stale-removed",
            text: "old",
            timestamp: timestamp
        )

        let reconfigureIDs = TimelineSnapshotApplier.reconfigureItemIDs(
            nextIDs: nextIDs,
            nextIDSet: Set(nextIDs),
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID,
            hiddenCount: 3,
            previousHiddenCount: 0,
            streamingAssistantID: "item-250",
            previousStreamingAssistantID: "stale-removed",
            themeChanged: false
        )

        #expect(reconfigureIDs == [
            "item-4",
            "item-250",
            "item-519",
            ChatTimelineCollectionHost.loadMoreID,
        ])
        #expect(Set(reconfigureIDs).count == reconfigureIDs.count)
    }
}
