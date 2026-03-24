import Testing
@testable import Oppi

@Suite("MessageQueueEditorState")
struct MessageQueueEditorStateTests {
    @Test("Live structural edits apply immediately using current server version")
    func liveStructuralEditsApplyImmediately() {
        var state = MessageQueueEditorState(queue: makeQueue())

        let request = state.moveItem(kind: .steer, from: 1, direction: -1)

        #expect(request?.baseVersion == 10)
        #expect(state.displayedQueue.steering.map(\.id) == ["s2", "s1"])
        #expect(!state.isDraftMode)
    }

    @Test("Text edit enters draft mode and structural edits stay local")
    func textEditEntersDraftModeAndStructuralEditsStayLocal() {
        var state = MessageQueueEditorState(queue: makeQueue())

        let changed = state.updateMessage(kind: .steer, index: 0, message: "updated")
        let request = state.moveItem(kind: .steer, from: 1, direction: -1)

        #expect(changed)
        #expect(state.isDraftMode)
        #expect(request == nil)
        #expect(state.displayedQueue.steering.map(\.message) == ["follow build", "updated"])
    }

    @Test("Queue changes during draft preserve draft and mark started-item conflict")
    func queueChangesDuringDraftPreserveDraftAndMarkConflict() {
        var state = MessageQueueEditorState(queue: makeQueue())
        _ = state.updateMessage(kind: .steer, index: 0, message: "updated")

        state.receiveServerQueue(
            MessageQueueState(
                version: 11,
                steering: [MessageQueueItem(id: "s2", message: "follow build", images: nil, createdAt: 2)],
                followUp: [MessageQueueItem(id: "f1", message: "summarize", images: nil, createdAt: 3)]
            ),
            isExpanded: true
        )

        #expect(state.conflict == .queuedMessageStarted)
        #expect(state.displayedQueue.steering.first?.message == "updated")
        #expect(state.serverQueue.version == 11)
    }

    @Test("Queue cleared during draft preserves draft and marks cleared conflict")
    func queueClearedDuringDraftPreservesDraftAndMarksConflict() {
        var state = MessageQueueEditorState(queue: makeQueue())
        _ = state.updateMessage(kind: .steer, index: 0, message: "updated")

        state.receiveServerQueue(.empty, isExpanded: true)

        #expect(state.conflict == .queueCleared)
        #expect(state.displayedQueue.steering.first?.message == "updated")
    }

    @Test("Review latest stashes draft and restore draft resumes editing")
    func reviewLatestStashesDraftAndRestoreDraftResumesEditing() {
        var state = MessageQueueEditorState(queue: makeQueue())
        _ = state.updateMessage(kind: .steer, index: 0, message: "updated")
        state.receiveServerQueue(
            MessageQueueState(
                version: 11,
                steering: [MessageQueueItem(id: "s2", message: "follow build", images: nil, createdAt: 2)],
                followUp: [MessageQueueItem(id: "f1", message: "summarize", images: nil, createdAt: 3)]
            ),
            isExpanded: true
        )

        state.reviewLatest()

        #expect(!state.isDraftMode)
        #expect(state.hasStashedDraft)
        #expect(state.displayedQueue.version == 11)
        #expect(state.displayedQueue.steering.map(\.id) == ["s2"])

        state.restoreDraft()

        #expect(state.isDraftMode)
        #expect(!state.hasStashedDraft)
        #expect(state.displayedQueue.steering.first?.message == "updated")
    }

    @Test("Collapsed draft still preserves edits when queue changes")
    func collapsedDraftStillPreservesEditsWhenQueueChanges() {
        var state = MessageQueueEditorState(queue: makeQueue())
        _ = state.updateMessage(kind: .steer, index: 0, message: "updated")

        state.receiveServerQueue(
            MessageQueueState(
                version: 11,
                steering: [MessageQueueItem(id: "s2", message: "follow build", images: nil, createdAt: 2)],
                followUp: [MessageQueueItem(id: "f1", message: "summarize", images: nil, createdAt: 3)]
            ),
            isExpanded: false
        )

        #expect(state.conflict == .queuedMessageStarted)
        #expect(state.displayedQueue.steering.first?.message == "updated")
    }

    @Test("Draft requests use latest server version after conflict")
    func draftRequestsUseLatestServerVersionAfterConflict() {
        var state = MessageQueueEditorState(queue: makeQueue())
        _ = state.updateMessage(kind: .steer, index: 0, message: "updated")
        state.receiveServerQueue(
            MessageQueueState(
                version: 42,
                steering: [MessageQueueItem(id: "s2", message: "follow build", images: nil, createdAt: 2)],
                followUp: [MessageQueueItem(id: "f1", message: "summarize", images: nil, createdAt: 3)]
            ),
            isExpanded: true
        )

        let request = state.draftRequest()

        #expect(request?.baseVersion == 42)
        #expect(request?.steering.first?.message == "updated")
    }
}

private func makeQueue() -> MessageQueueState {
    MessageQueueState(
        version: 10,
        steering: [
            MessageQueueItem(id: "s1", message: "fix tests", images: nil, createdAt: 1),
            MessageQueueItem(id: "s2", message: "follow build", images: nil, createdAt: 2),
        ],
        followUp: [
            MessageQueueItem(id: "f1", message: "summarize", images: nil, createdAt: 3),
        ]
    )
}
