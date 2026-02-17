import Testing
import Foundation
@testable import Oppi

// MARK: - SessionStore

@Suite("SessionStore")
struct SessionStoreTests {

    private func makeSession(
        id: String,
        status: SessionStatus = .ready,
        lastActivity: Date = Date()
    ) -> Session {
        let tsMs = lastActivity.timeIntervalSince1970 * 1000
        let json = """
        {
            "id": "\(id)",
            "status": "\(status.rawValue)",
            "createdAt": \(tsMs),
            "lastActivity": \(tsMs),
            "messageCount": 0,
            "tokens": {"input": 0, "output": 0},
            "cost": 0
        }
        """
        return try! JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)
    }

    @MainActor
    @Test func upsertInsertsNew() {
        let store = SessionStore()
        let session = makeSession(id: "s1")

        store.upsert(session)

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s1")
    }

    @MainActor
    @Test func upsertUpdatesExisting() {
        let store = SessionStore()
        let session1 = makeSession(id: "s1", status: .ready)
        store.upsert(session1)

        let session2 = makeSession(id: "s1", status: .busy)
        let didMutate = store.upsert(session2)

        #expect(didMutate)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .busy)
    }

    @MainActor
    @Test func upsertIdenticalSessionIsNoOp() {
        let store = SessionStore()
        let session = makeSession(id: "s1", status: .ready)

        #expect(store.upsert(session))
        let didMutate = store.upsert(session)

        #expect(!didMutate)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0] == session)
    }

    @MainActor
    @Test func upsertInsertsAtFront() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))
        store.upsert(makeSession(id: "s2"))

        // Most recent insert at index 0
        #expect(store.sessions[0].id == "s2")
        #expect(store.sessions[1].id == "s1")
    }

    @MainActor
    @Test func removeById() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))
        store.upsert(makeSession(id: "s2"))

        store.remove(id: "s1")

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s2")
    }

    @MainActor
    @Test func removeClearsActiveSessionId() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))
        store.activeSessionId = "s1"

        store.remove(id: "s1")

        #expect(store.activeSessionId == nil)
    }

    @MainActor
    @Test func removeNonActiveDoesNotClearActive() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))
        store.upsert(makeSession(id: "s2"))
        store.activeSessionId = "s1"

        store.remove(id: "s2")

        #expect(store.activeSessionId == "s1")
    }

    @MainActor
    @Test func activeSession() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))
        store.upsert(makeSession(id: "s2"))

        #expect(store.activeSession == nil)

        store.activeSessionId = "s1"
        #expect(store.activeSession?.id == "s1")

        store.activeSessionId = "nonexistent"
        #expect(store.activeSession == nil)
    }

    @MainActor
    @Test func sortByLastActivity() {
        let store = SessionStore()
        let now = Date()
        store.upsert(makeSession(id: "old", lastActivity: now.addingTimeInterval(-3600)))
        store.upsert(makeSession(id: "recent", lastActivity: now))
        store.upsert(makeSession(id: "mid", lastActivity: now.addingTimeInterval(-60)))

        store.sort()

        #expect(store.sessions.map(\.id) == ["recent", "mid", "old"])
    }

    @MainActor
    @Test func removeNonexistentIdIsNoOp() {
        let store = SessionStore()
        store.upsert(makeSession(id: "s1"))

        store.remove(id: "nonexistent")

        #expect(store.sessions.count == 1)
    }
}

// MARK: - PermissionStore

@Suite("PermissionStore")
struct PermissionStoreTests {

    private func makePerm(id: String, sessionId: String = "s1") -> PermissionRequest {
        PermissionRequest(
            id: id, sessionId: sessionId, tool: "bash",
            input: [:], displaySummary: "bash: test",
            risk: .low, reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
    }

    @MainActor
    @Test func addAndCount() {
        let store = PermissionStore()

        store.add(makePerm(id: "p1"))
        store.add(makePerm(id: "p2"))

        #expect(store.count == 2)
        #expect(store.pending.count == 2)
    }

    @MainActor
    @Test func addRejectsDuplicates() {
        let store = PermissionStore()

        store.add(makePerm(id: "p1"))
        store.add(makePerm(id: "p1"))

        #expect(store.count == 1)
    }

    @MainActor
    @Test func removeById() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1"))
        store.add(makePerm(id: "p2"))

        store.remove(id: "p1")

        #expect(store.count == 1)
        #expect(store.pending[0].id == "p2")
    }

    @MainActor
    @Test func takeRemovesAndReturnsFromPending() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1"))

        let taken = store.take(id: "p1")

        #expect(taken?.id == "p1")
        #expect(store.count == 0)
    }

    @MainActor
    @Test func takeReturnsNilForMissing() {
        let store = PermissionStore()
        let taken = store.take(id: "nonexistent")
        #expect(taken == nil)
    }

    @MainActor
    @Test func removeRemovesFromPending() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1"))

        store.remove(id: "p1")

        #expect(store.count == 0)
    }

    @MainActor
    @Test func pendingForSession() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1", sessionId: "s1"))
        store.add(makePerm(id: "p2", sessionId: "s2"))
        store.add(makePerm(id: "p3", sessionId: "s1"))

        let s1Perms = store.pending(for: "s1")
        #expect(s1Perms.count == 2)
        #expect(s1Perms.map(\.id).contains("p1"))
        #expect(s1Perms.map(\.id).contains("p3"))

        let s2Perms = store.pending(for: "s2")
        #expect(s2Perms.count == 1)
        #expect(s2Perms[0].id == "p2")
    }

    @MainActor
    @Test func pendingForNonexistentSessionReturnsEmpty() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1", sessionId: "s1"))

        #expect(store.pending(for: "s99").isEmpty)
    }

    @MainActor
    @Test func removeNonexistentIdIsNoOp() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1"))

        store.remove(id: "nonexistent")

        #expect(store.count == 1)
    }
}

// MARK: - WorkspaceStore

@Suite("WorkspaceStore")
struct WorkspaceStoreTests {

    private func makeWorkspace(id: String, name: String = "Test") -> Workspace {
        let now = Date().timeIntervalSince1970 * 1000
        let json = """
        {
            "id": "\(id)",
            "name": "\(name)",
            "skills": [],
            "policyPreset": "container",
            "createdAt": \(now),
            "updatedAt": \(now)
        }
        """
        return try! JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)
    }

    @MainActor
    @Test func upsertInsertsNew() {
        let store = WorkspaceStore()

        store.upsert(makeWorkspace(id: "w1"))

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "w1")
    }

    @MainActor
    @Test func upsertUpdatesExisting() {
        let store = WorkspaceStore()
        store.upsert(makeWorkspace(id: "w1", name: "Original"))

        store.upsert(makeWorkspace(id: "w1", name: "Updated"))

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].name == "Updated")
    }

    @MainActor
    @Test func removeById() {
        let store = WorkspaceStore()
        store.upsert(makeWorkspace(id: "w1"))
        store.upsert(makeWorkspace(id: "w2"))

        store.remove(id: "w1")

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].id == "w2")
    }

    @MainActor
    @Test func removeNonexistentIsNoOp() {
        let store = WorkspaceStore()
        store.upsert(makeWorkspace(id: "w1"))

        store.remove(id: "nonexistent")

        #expect(store.workspaces.count == 1)
    }

    @MainActor
    @Test func isLoadedStartsFalse() {
        let store = WorkspaceStore()
        #expect(!store.isLoaded)
    }

    @MainActor
    @Test func skillsStartEmpty() {
        let store = WorkspaceStore()
        #expect(store.skills.isEmpty)
    }
}
