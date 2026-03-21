import Foundation

@MainActor
struct ChatTimelineApplyPlan {
    let nextIDs: [String]
    let nextItemByID: [String: ChatItem]
    let removedIDs: Set<String>

    static func build(
        items: [ChatItem],
        hiddenCount: Int,
        isBusy: Bool,
        streamingAssistantID _: String?
    ) -> Self {
        var nextIDs: [String] = []
        nextIDs.reserveCapacity(items.count + 2)

        if hiddenCount > 0 {
            nextIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        let dedupedItems = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items)
        nextIDs.append(contentsOf: dedupedItems.orderedIDs)

        if isBusy {
            nextIDs.append(ChatTimelineCollectionHost.workingIndicatorID)
        }

        return Self(
            nextIDs: nextIDs,
            nextItemByID: dedupedItems.itemByID,
            removedIDs: []
        )
    }

    func withRemovedIDs(from currentIDs: [String]) -> Self {
        Self(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            removedIDs: Set(currentIDs).subtracting(nextIDs)
        )
    }
}
