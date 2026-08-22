import Foundation
import Testing
@testable import Oppi

@Suite("ChatTimelineApplyPlan")
@MainActor
struct ChatTimelineApplyPlanTests {
    @Test func planAddsLoadMoreAndWorkingIndicatorAroundDedupedItems() {
        let first = ChatItem.systemEvent(id: "dup", message: "first")
        let middle = ChatItem.error(id: "middle", message: "middle")
        let second = ChatItem.systemEvent(id: "dup", message: "second")

        let plan = ChatTimelineApplyPlan.build(
            items: [first, middle, second],
            hiddenCount: 3,
            isBusy: true,
            streamingAssistantID: nil
        )

        #expect(plan.nextIDs == [
            ChatTimelineCollectionHost.loadMoreID,
            "middle",
            "dup",
            ChatTimelineCollectionHost.workingIndicatorID,
        ])
        #expect(plan.nextItemByID["dup"] == second)
        #expect(plan.nextItemByID["middle"] == middle)
    }

    @Test func planKeepsLoadMoreAvailableWhenOnlyServerPagesRemain() {
        let plan = ChatTimelineApplyPlan.build(
            items: [.assistantMessage(id: "assistant-1", text: "hi", timestamp: Date())],
            hiddenCount: 0,
            hasOlderServerPage: true,
            isBusy: false,
            streamingAssistantID: nil
        )

        #expect(plan.nextIDs == [
            ChatTimelineCollectionHost.loadMoreID,
            "assistant-1",
        ])
    }

    @Test func planIncludesWorkingIndicatorWhileAssistantIsStreaming() {
        let plan = ChatTimelineApplyPlan.build(
            items: [.assistantMessage(id: "assistant-1", text: "hi", timestamp: Date())],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: "assistant-1"
        )

        #expect(plan.nextIDs == [
            "assistant-1",
            ChatTimelineCollectionHost.workingIndicatorID,
        ])
    }

    @Test func quietWorkRowsKeepSyntheticIdentityAndReportRemovedRows() {
        let workLine = QuietTimelineWorkLine(
            id: "quiet-work-line:u1",
            turnID: "u1",
            sourceItemIDs: ["think-1", "tool-1"],
            buckets: [.init(kind: .tooling, count: 1)],
            displayStyle: .icons,
            isExpanded: false,
            isLive: false,
            liveStartedAt: nil
        )
        let rows: [TimelineDisplayRow] = [
            .quietWork(workLine),
            .item(.assistantMessage(id: "assistant-1", text: "done", timestamp: Date()))
        ]

        let plan = ChatTimelineApplyPlan.build(
            rows: rows,
            hiddenCount: 2,
            isBusy: true,
            showsWorkingIndicator: true,
            streamingAssistantID: nil
        ).withRemovedIDs(from: [
            "quiet-work-line:old",
            "assistant-1"
        ])

        #expect(plan.nextIDs == [
            ChatTimelineCollectionHost.loadMoreID,
            "quiet-work-line:u1",
            "assistant-1",
            ChatTimelineCollectionHost.workingIndicatorID,
        ])
        #expect(plan.nextWorkLineByID[workLine.id] == workLine)
        #expect(plan.removedIDs == Set(["quiet-work-line:old"]))
    }

    @Test func removedIDsReflectItemsDroppedFromCurrentSnapshot() {
        let plan = ChatTimelineApplyPlan.build(
            items: [.systemEvent(id: "keep", message: "keep")],
            hiddenCount: 0,
            isBusy: false,
            streamingAssistantID: nil
        ).withRemovedIDs(from: ["drop", "keep"])

        #expect(plan.removedIDs == Set(["drop"]))
    }

    @Test func workLineCountChangesReconfigureExistingSyntheticIDs() {
        func line(toolCount: Int) -> QuietTimelineWorkLine {
            QuietTimelineWorkLine(
                id: "quiet-work-line:think-1",
                turnID: "think-1",
                sourceItemIDs: ["think-1"],
                buckets: [.init(kind: .tooling, count: toolCount)],
                displayStyle: .icons,
                isExpanded: false,
                isLive: true,
                liveStartedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
        let previous = ["quiet-work-line:think-1": line(toolCount: 1)]
        let next = ["quiet-work-line:think-1": line(toolCount: 2)]
        #expect(
            ChatTimelineApplyPlan.workLineReconfigureIDs(previous: previous, next: next)
                == ["quiet-work-line:think-1"]
        )
        #expect(ChatTimelineApplyPlan.workLineReconfigureIDs(previous: next, next: next).isEmpty)
    }
}
