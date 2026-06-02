import Testing
import Foundation
@testable import Oppi

// MARK: - SessionStore

@Suite("SessionStore")
@MainActor
struct SessionStoreTests {

    @Test func upsertInsertsNew() {
        let store = SessionStore()
        let session = makeTestSession(id: "s1")

        store.upsert(session)

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s1")
    }

    @Test func upsertUpdatesExisting() {
        let store = SessionStore()
        let session1 = makeTestSession(id: "s1", status: .ready)
        store.upsert(session1)

        let session2 = makeTestSession(id: "s1", status: .busy)
        let didMutate = store.upsert(session2)

        #expect(didMutate)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .busy)
    }

    @Test func upsertIdenticalSessionIsNoOp() {
        let store = SessionStore()
        let session = makeTestSession(id: "s1", status: .ready)

        #expect(store.upsert(session))
        let didMutate = store.upsert(session)

        #expect(!didMutate)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0] == session)
    }

    @Test func upsertInsertsAtFront() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))
        store.upsert(makeTestSession(id: "s2"))

        // Most recent insert at index 0
        #expect(store.sessions[0].id == "s2")
        #expect(store.sessions[1].id == "s1")
    }

    @Test func removeById() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))
        store.upsert(makeTestSession(id: "s2"))

        store.remove(id: "s1")

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s2")
    }

    @Test func removeClearsActiveSessionId() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))
        store.activeSessionId = "s1"

        store.remove(id: "s1")

        #expect(store.activeSessionId == nil)
    }

    @Test func removeNonActiveDoesNotClearActive() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))
        store.upsert(makeTestSession(id: "s2"))
        store.activeSessionId = "s1"

        store.remove(id: "s2")

        #expect(store.activeSessionId == "s1")
    }

    @Test func activeSession() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))
        store.upsert(makeTestSession(id: "s2"))

        #expect(store.activeSession == nil)

        store.activeSessionId = "s1"
        #expect(store.activeSession?.id == "s1")

        store.activeSessionId = "nonexistent"
        #expect(store.activeSession == nil)
    }

    @Test func sortByLastActivity() {
        let store = SessionStore()
        let now = Date()
        store.upsert(makeTestSession(id: "old", lastActivity: now.addingTimeInterval(-3600)))
        store.upsert(makeTestSession(id: "recent", lastActivity: now))
        store.upsert(makeTestSession(id: "mid", lastActivity: now.addingTimeInterval(-60)))

        store.sort()

        #expect(store.sessions.map(\.id) == ["recent", "mid", "old"])
    }

    @Test func removeNonexistentIdIsNoOp() {
        let store = SessionStore()
        store.upsert(makeTestSession(id: "s1"))

        store.remove(id: "nonexistent")

        #expect(store.sessions.count == 1)
    }
}

// MARK: - WorkspaceStore

@Suite("WorkspaceStore")
@MainActor
struct WorkspaceStoreTests {

    @Test func upsertInsertsNew() {
        let store = WorkspaceStore()

        store.upsert(makeTestWorkspace(id: "w1"))

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "w1")
    }

    @Test func upsertUpdatesExisting() {
        let store = WorkspaceStore()
        store.upsert(makeTestWorkspace(id: "w1", name: "Original"))

        store.upsert(makeTestWorkspace(id: "w1", name: "Updated"))

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].name == "Updated")
    }

    @Test func removeById() {
        let store = WorkspaceStore()
        store.upsert(makeTestWorkspace(id: "w1"))
        store.upsert(makeTestWorkspace(id: "w2"))

        store.remove(id: "w1")

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "w2")
    }

    @Test func removeNonexistentIsNoOp() {
        let store = WorkspaceStore()
        store.upsert(makeTestWorkspace(id: "w1"))

        store.remove(id: "nonexistent")

        #expect(store.workspaces.count == 1)
    }

    @Test func isLoadedStartsFalse() {
        let store = WorkspaceStore()
        #expect(!store.isLoaded)
    }

    @Test func skillsStartEmpty() {
        let store = WorkspaceStore()
        #expect(store.skills.isEmpty)
    }
}
