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

    @Test func removedIDsReflectItemsDroppedFromCurrentSnapshot() {
        let plan = ChatTimelineApplyPlan.build(
            items: [.systemEvent(id: "keep", message: "keep")],
            hiddenCount: 0,
            isBusy: false,
            streamingAssistantID: nil
        ).withRemovedIDs(from: ["drop", "keep"])

        #expect(plan.removedIDs == Set(["drop"]))
    }
}
