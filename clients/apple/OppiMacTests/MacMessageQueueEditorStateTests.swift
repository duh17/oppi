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

    @Test func acceptedDraftCommitsOnceAndAdoptsLaterServerQueue() throws {
        var state = MacMessageQueueEditorState(queue: queue(version: 3, steering: ["old"], followUp: []))
        let didUpdate = state.updateMessage(kind: .steer, index: 0, message: "accepted")
        #expect(didUpdate)
        let submitted = try #require(state.draftRequest())

        state.receiveServerQueue(queue(version: 4, steering: ["accepted"], followUp: []))
        #expect(state.displayedQueue.version == 3)

        state.acceptDraft(submitted)

        #expect(!state.isDraftMode)
        #expect(state.draftRequest() == nil)
        #expect(state.displayedQueue.steering.map(\.message) == ["accepted"])
        #expect(state.displayedQueue.version == 4)

        state.receiveServerQueue(queue(version: 5, steering: ["server accepted"], followUp: ["later"]))

        #expect(state.serverQueue.version == 5)
        #expect(state.displayedQueue == state.serverQueue)
        #expect(state.displayedQueue.steering.map(\.message) == ["server accepted"])
        #expect(state.displayedQueue.followUp.map(\.message) == ["later"])
    }

    @Test func acceptedDraftPreservesEditsMadeAfterSubmission() throws {
        var state = MacMessageQueueEditorState(queue: queue(version: 5, steering: ["old"], followUp: []))
        let didUpdateSubmitted = state.updateMessage(kind: .steer, index: 0, message: "submitted")
        #expect(didUpdateSubmitted)
        let submitted = try #require(state.draftRequest())

        let didUpdateWhileSaving = state.updateMessage(
            kind: .steer,
            index: 0,
            message: "edited while saving"
        )
        #expect(didUpdateWhileSaving)
        state.acceptDraft(submitted)

        #expect(state.isDraftMode)
        #expect(state.displayedQueue.steering.map(\.message) == ["edited while saving"])
        #expect(state.draftRequest()?.steering.map(\.message) == ["edited while saving"])
    }

    @Test func rejectedImmediateStructuralMutationRollsBackToServerState() {
        var state = MacMessageQueueEditorState(
            queue: queue(version: 4, steering: ["first", "second"], followUp: ["later"])
        )

        let request = state.deleteItem(kind: .steer, id: "s-0")
        #expect(request?.steering.map(\.message) == ["second"])
        #expect(state.displayedQueue.steering.map(\.message) == ["second"])

        state.rollbackRejectedImmediateMutation()

        #expect(state.displayedQueue == state.serverQueue)
        #expect(state.displayedQueue.steering.map(\.message) == ["first", "second"])
        #expect(!state.isDraftMode)
    }

    @Test func idBasedLookupUpdateAndMoveKeepTargetingTheSameItem() {
        var state = MacMessageQueueEditorState(
            queue: queue(version: 8, steering: ["first", "second", "third"], followUp: [])
        )

        #expect(state.item(kind: .steer, id: "s-1")?.message == "second")
        #expect(state.canMove(kind: .steer, id: "s-1", direction: -1))
        #expect(!state.canMove(kind: .steer, id: "s-0", direction: -1))
        #expect(!state.canMove(kind: .steer, id: "missing", direction: 1))

        let request = state.moveItem(kind: .steer, id: "s-1", direction: -1)
        #expect(request?.steering.compactMap(\.id) == ["s-1", "s-0", "s-2"])
        #expect(state.displayedQueue.steering.map(\.id) == ["s-1", "s-0", "s-2"])

        let didUpdate = state.updateMessage(kind: .steer, id: "s-1", message: "edited second")
        #expect(didUpdate)
        #expect(state.item(kind: .steer, id: "s-1")?.message == "edited second")
        #expect(state.displayedQueue.steering.first?.id == "s-1")
    }

    @Test func idBasedCrossQueueMoveAndDeleteKeepTargetingTheSameItem() {
        var state = MacMessageQueueEditorState(
            queue: queue(version: 12, steering: ["first", "second"], followUp: ["later"])
        )

        let moveRequest = state.moveBetweenQueues(kind: .steer, id: "s-1")
        #expect(moveRequest?.steering.compactMap(\.id) == ["s-0"])
        #expect(moveRequest?.followUp.compactMap(\.id) == ["f-0", "s-1"])
        #expect(state.item(kind: .followUp, id: "s-1")?.message == "second")

        let deleteRequest = state.deleteItem(kind: .followUp, id: "s-1")
        #expect(deleteRequest?.followUp.compactMap(\.id) == ["f-0"])
        #expect(state.item(kind: .followUp, id: "s-1") == nil)
        let missingDelete = state.deleteItem(kind: .followUp, id: "missing")
        #expect(missingDelete == nil)
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
