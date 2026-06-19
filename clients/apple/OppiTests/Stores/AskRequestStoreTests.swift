import Foundation
import Testing
@testable import Oppi

@Suite("AskRequestStore")
@MainActor
struct AskRequestStoreTests {

    // MARK: - Basic operations

    @Test func initiallyEmpty() {
        let store = AskRequestStore()
        #expect(store.pending.isEmpty)
    }

    @Test func setAndRetrieveAskRequest() {
        let store = AskRequestStore()
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Which color?", options: [
                AskOption(value: "red", label: "Red"),
            ], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        store.set(ask, for: "s1")
        #expect(store.pending(for: "s1") != nil)
        #expect(store.pending(for: "s1")?.id == "ask-1")
    }

    @Test func queuesMultipleAskRequestsForSameSession() {
        let store = AskRequestStore()
        let first = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil)
        let second = AskRequest(id: "ask-2", sessionId: "s1", questions: [], allowCustom: false, timeout: nil)

        store.set(first, for: "s1")
        store.set(second, for: "s1")

        #expect(store.pending(for: "s1")?.id == "ask-1")
        _ = store.remove(id: "ask-1")
        #expect(store.pending(for: "s1")?.id == "ask-2")
    }

    @Test func removeAskRequest() {
        let store = AskRequestStore()
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [],
            allowCustom: true,
            timeout: nil
        )
        store.set(ask, for: "s1")
        store.remove(for: "s1")
        #expect(store.pending(for: "s1") == nil)
    }

    @Test func pendingReturnsNilForUnknownSession() {
        let store = AskRequestStore()
        #expect(store.pending(for: "unknown") == nil)
    }

    @Test func hasPendingAskForSession() {
        let store = AskRequestStore()
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [],
            allowCustom: true,
            timeout: nil
        )
        store.set(ask, for: "s1")
        #expect(store.hasPending(for: "s1"))
        #expect(!store.hasPending(for: "s2"))
    }

    @Test func multipleSessionsTrackedIndependently() {
        let store = AskRequestStore()
        let ask1 = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil)
        let ask2 = AskRequest(id: "ask-2", sessionId: "s2", questions: [], allowCustom: true, timeout: nil)
        store.set(ask1, for: "s1")
        store.set(ask2, for: "s2")
        #expect(store.pending.count == 2)
        store.remove(for: "s1")
        #expect(store.pending.count == 1)
        #expect(store.hasPending(for: "s2"))
    }

    @Test func duplicateReplayUpdatesExistingAskWithoutAppending() {
        let store = AskRequestStore()
        let first = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil)
        let replay = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: false, timeout: 42)

        store.set(first, for: "s1")
        store.set(replay, for: "s1")

        #expect(store.pending(for: "s1")?.allowCustom == false)
        #expect(store.pending(for: "s1")?.timeout == 42)
    }

    @Test func workspaceSnapshotDoesNotClearInlineExtensionPrompt() {
        let store = AskRequestStore()
        let prompt = AskRequest(
            id: "select-1",
            sessionId: "s1",
            questions: [],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )

        store.set(prompt, for: "s1")
        let removed = store.applyWorkspaceSnapshot(
            workspaceId: "w1",
            asks: [],
            workspaceSessionIds: ["s1"]
        )

        #expect(removed.isEmpty)
        #expect(store.pending(for: "s1")?.id == "select-1")
    }

    @Test func workspaceSnapshotPreservesQueueOrderWhenVisibleAskStillPending() {
        let store = AskRequestStore()
        let visibleAsk = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [],
            allowCustom: true,
            timeout: nil,
            workspaceId: "w1"
        )
        let queuedPrompt = AskRequest(
            id: "select-1",
            sessionId: "s1",
            questions: [],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )
        let refreshedVisibleAsk = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [],
            allowCustom: false,
            timeout: 30,
            workspaceId: "w1"
        )

        store.set(visibleAsk, for: "s1")
        store.set(queuedPrompt, for: "s1")
        _ = store.applyWorkspaceSnapshot(
            workspaceId: "w1",
            asks: [refreshedVisibleAsk],
            workspaceSessionIds: ["s1"]
        )

        #expect(store.pending(for: "s1")?.id == "ask-1")
        #expect(store.pending(for: "s1")?.allowCustom == false)
        #expect(store.pending(for: "s1")?.timeout == 30)
        _ = store.remove(id: "ask-1")
        #expect(store.pending(for: "s1")?.id == "select-1")
    }

    @Test func workspaceSnapshotReportsSessionWhenVisibleAskRemovedButInlinePromptRemains() {
        let store = AskRequestStore()
        let visibleAsk = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [],
            allowCustom: true,
            timeout: nil,
            workspaceId: "w1"
        )
        let queuedPrompt = AskRequest(
            id: "select-1",
            sessionId: "s1",
            questions: [],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )

        store.set(visibleAsk, for: "s1")
        store.set(queuedPrompt, for: "s1")
        let changedSessionIds = store.applyWorkspaceSnapshot(
            workspaceId: "w1",
            asks: [],
            workspaceSessionIds: ["s1"]
        )

        #expect(changedSessionIds == ["s1"])
        #expect(store.pending(for: "s1")?.id == "select-1")
    }

    // MARK: - Server switching

    @Test func switchServerClearsAndIsolates() {
        let store = AskRequestStore()
        store.switchServer(to: "server-a")
        let ask = AskRequest(id: "ask-1", sessionId: "s1", questions: [], allowCustom: true, timeout: nil)
        store.set(ask, for: "s1")
        #expect(store.hasPending(for: "s1"))

        store.switchServer(to: "server-b")
        #expect(store.pending.isEmpty)
        #expect(!store.hasPending(for: "s1"))
    }
}
