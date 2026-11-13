import Foundation

@MainActor
struct ChatTimelineApplyPlan {
    let nextIDs: [String]
    let nextItemByID: [String: ChatItem]
    let nextWorkLineByID: [String: QuietTimelineWorkLine]
    /// The live work line drawn as the working row (`workingRowLine`); nil when
    /// the working row stands alone or does not show.
    let workingRowLineID: String?
    let removedIDs: Set<String>

    /// While the turn runs, its live folded work and the working indicator are
    /// one row: the work line's row draws the spinner and the extension's
    /// working text with the turn's time and steps after them, and keeps the
    /// line's tap. Nil when no work is folded yet (the indicator row stands
    /// alone) or the extension hid the working indicator (the line keeps its
    /// own pill or strip). The projection makes at most one line live.
    static func workingRowLine(in rows: [TimelineDisplayRow], showsWorkingIndicator: Bool) -> QuietTimelineWorkLine? {
        guard showsWorkingIndicator else { return nil }
        for row in rows.reversed() {
            if case .quietWork(let line) = row { return line.isLive ? line : nil }
        }
        return nil
    }

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
            nextIDs.append(ChatTimelineController.loadMoreID)
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
            case .childTail:
                // Its payload is `ChatTimelineConfiguration.childTailByID`.
                nextIDs.append(row.id)
            }
        }

        let workingRowLine = workingRowLine(in: rows, showsWorkingIndicator: showsWorkingIndicator ?? isBusy)
        if showsWorkingIndicator ?? isBusy, workingRowLine == nil {
            nextIDs.append(ChatTimelineController.workingIndicatorID)
        }

        return Self(
            nextIDs: nextIDs,
            nextItemByID: itemByID,
            nextWorkLineByID: workLineByID,
            workingRowLineID: workingRowLine?.id,
            removedIDs: []
        )
    }

    func withRemovedIDs(from currentIDs: [String]) -> Self {
        Self(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            nextWorkLineByID: nextWorkLineByID,
            workingRowLineID: workingRowLineID,
            removedIDs: Set(currentIDs).subtracting(nextIDs)
        )
    }

    /// Child tails whose lines changed under the same ID.
    static func childTailReconfigureIDs(
        previous: [String: ConversationChildTail],
        next: [String: ConversationChildTail]
    ) -> [String] {
        next.compactMap { id, tail in
            guard let old = previous[id], old != tail else { return nil }
            return id
        }
        .sorted()
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
