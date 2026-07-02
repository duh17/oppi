import Testing
@testable import Oppi

@Suite("Mac message queue editor state")
struct MacMessageQueueEditorStateTests {
    @Test func structuralMutationProducesSetQueueRequestImmediatelyInLiveMode() {
        var state = MacMessageQueueEditorState(queue: queue(version: 7, steering: ["a", "b"], followUp: ["c"]))

        let request = state.moveItem(kind: .steer, from: 1, direction: -1)

        #expect(request?.baseVersion == 7)
        #expect(request?.steering.map(\.message) == ["b", "a"])
        #expect(request?.followUp.map(\.message) == ["c"])
    }

    @Test func textEditsEnterDraftModeUntilSavedOrDiscarded() {
        var state = MacMessageQueueEditorState(queue: queue(version: 3, steering: ["old"], followUp: []))

        let didUpdate = state.updateMessage(kind: .steer, index: 0, message: "new")
        #expect(didUpdate)
        #expect(state.isDraftMode)
        #expect(state.moveItem(kind: .steer, from: 0, direction: 1) == nil)

        let request = state.draftRequest()
        #expect(request?.baseVersion == 3)
        #expect(request?.steering.map(\.message) == ["new"])

        state.discardDraft()
        #expect(!state.isDraftMode)
        #expect(state.displayedQueue.steering.map(\.message) == ["old"])
    }

    @Test func liveStateAdoptsServerQueueButDraftStateKeepsLocalEdits() {
        var state = MacMessageQueueEditorState(queue: queue(version: 1, steering: ["old"], followUp: []))
        state.receiveServerQueue(queue(version: 2, steering: ["latest"], followUp: []))
        #expect(state.displayedQueue.steering.map(\.message) == ["latest"])

        let didUpdate = state.updateMessage(kind: .steer, index: 0, message: "draft")
        #expect(didUpdate)
        state.receiveServerQueue(queue(version: 3, steering: ["server"], followUp: []))

        #expect(state.serverQueue.steering.map(\.message) == ["server"])
        #expect(state.displayedQueue.steering.map(\.message) == ["draft"])
        #expect(state.draftRequest()?.baseVersion == 3)
    }

    private func queue(version: Int, steering: [String], followUp: [String]) -> MessageQueueState {
        MessageQueueState(
            version: version,
            steering: steering.enumerated().map { index, message in item(id: "s-\(index)", message: message) },
            followUp: followUp.enumerated().map { index, message in item(id: "f-\(index)", message: message) }
        )
    }

    private func item(id: String, message: String) -> MessageQueueItem {
        MessageQueueItem(id: id, message: message, createdAt: 1_800_000_000_000)
    }
}
