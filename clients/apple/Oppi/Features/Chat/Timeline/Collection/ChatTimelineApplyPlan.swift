import Foundation

@MainActor
struct ChatTimelineApplyPlan {
    let nextIDs: [String]
    let nextItemByID: [String: ChatItem]
    let removedIDs: Set<String>

    static func build(
        items: [ChatItem],
        hiddenCount: Int,
        hasOlderServerPage: Bool = false,
        isBusy: Bool,
        showsWorkingIndicator: Bool? = nil,
        streamingAssistantID _: String?
    ) -> Self {
        var nextIDs: [String] = []
        nextIDs.reserveCapacity(items.count + 2)

        if TimelineRenderWindowPolicy.showsShowEarlierControl(
            hiddenCount: hiddenCount,
            hasOlderServerPage: hasOlderServerPage
        ) {
            nextIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        let dedupedItems = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast(items)
        nextIDs.append(contentsOf: dedupedItems.orderedIDs)

        if showsWorkingIndicator ?? isBusy {
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
