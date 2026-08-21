import Foundation

@MainActor
struct ChatTimelineApplyPlan {
    let nextIDs: [String]
    let nextItemByID: [String: ChatItem]
    let nextWorkLineByID: [String: QuietTimelineWorkLine]
    let removedIDs: Set<String>

    static func build(
        items: [ChatItem],
        hiddenCount: Int,
        hasOlderServerPage: Bool = false,
        isBusy: Bool,
        showsWorkingIndicator: Bool? = nil,
        streamingAssistantID: String?
    ) -> Self {
        build(
            rows: items.map(TimelineDisplayRow.item),
            hiddenCount: hiddenCount,
            hasOlderServerPage: hasOlderServerPage,
            isBusy: isBusy,
            showsWorkingIndicator: showsWorkingIndicator,
            streamingAssistantID: streamingAssistantID
        )
    }

    static func build(
        rows: [TimelineDisplayRow],
        hiddenCount: Int,
        hasOlderServerPage: Bool = false,
        isBusy: Bool,
        showsWorkingIndicator: Bool? = nil,
        streamingAssistantID _: String?
    ) -> Self {
        var nextIDs: [String] = []
        nextIDs.reserveCapacity(rows.count + 2)

        if TimelineRenderWindowPolicy.showsShowEarlierControl(
            hiddenCount: hiddenCount,
            hasOlderServerPage: hasOlderServerPage
        ) {
            nextIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        var lastIndexByItemID: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case .item(let item) = row {
                lastIndexByItemID[item.id] = index
            }
        }

        var itemByID: [String: ChatItem] = [:]
        var workLineByID: [String: QuietTimelineWorkLine] = [:]
        for (index, row) in rows.enumerated() {
            switch row {
            case .item(let item):
                guard lastIndexByItemID[item.id] == index else { continue }
                itemByID[item.id] = item
                nextIDs.append(item.id)
            case .quietWork(let workLine):
                workLineByID[workLine.id] = workLine
                nextIDs.append(workLine.id)
            }
        }

        if showsWorkingIndicator ?? isBusy {
            nextIDs.append(ChatTimelineCollectionHost.workingIndicatorID)
        }

        return Self(
            nextIDs: nextIDs,
            nextItemByID: itemByID,
            nextWorkLineByID: workLineByID,
            removedIDs: []
        )
    }

    func withRemovedIDs(from currentIDs: [String]) -> Self {
        Self(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            nextWorkLineByID: nextWorkLineByID,
            removedIDs: Set(currentIDs).subtracting(nextIDs)
        )
    }

    /// Same synthetic ID, new counts/live state. Diffable snapshots ignore payload
    /// changes unless these IDs are force-reconfigured.
    static func workLineReconfigureIDs(
        previous: [String: QuietTimelineWorkLine],
        next: [String: QuietTimelineWorkLine]
    ) -> [String] {
        next.compactMap { id, line in
            guard let old = previous[id], old != line else { return nil }
            return id
        }
        .sorted()
    }
}
