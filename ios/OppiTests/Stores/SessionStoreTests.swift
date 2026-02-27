import Testing
import Foundation
@testable import Oppi

@Suite("SessionStore Partitioning")
struct SessionStorePartitioningTests {

    // MARK: - Server partitioning

    @MainActor
    @Test func sessionsPartitionedByServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))

        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s2")

        store.switchServer(to: "srv1")
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s1")
    }

    @MainActor
    @Test func sessionsForSpecificServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        #expect(store.sessions(forServer: "srv1").count == 1)
        #expect(store.sessions(forServer: "srv1")[0].id == "s1")
        #expect(store.sessions(forServer: "nonexistent").isEmpty)
    }

    @MainActor
    @Test func allSessionsSpansServers() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1", lastActivity: Date(timeIntervalSince1970: 100)))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2", lastActivity: Date(timeIntervalSince1970: 200)))

        let all = store.allSessions
        #expect(all.count == 2)
        #expect(all[0].id == "s2")
    }

    @MainActor
    @Test func findSessionAcrossServers() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        let found = store.findSession(id: "s1")
        #expect(found?.session.id == "s1")
        #expect(found?.serverId == "srv1")
        #expect(store.findSession(id: "missing") == nil)
    }

    // MARK: - Upsert

    @MainActor
    @Test func upsertReturnsFalseWhenUnchanged() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let s = makeTestSession(id: "s1")
        store.upsert(s)
        #expect(store.upsert(s) == false)
    }

    // MARK: - Remove

    @MainActor
    @Test func removeClearsActiveSessionId() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.activeSessionId = "s1"

        store.remove(id: "s1")
        #expect(store.activeSessionId == nil)
        #expect(store.sessions.isEmpty)
    }

    // MARK: - Server removal

    @MainActor
    @Test func removeServerClearsPartition() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")

        store.removeServer("srv1")
        #expect(store.sessions(forServer: "srv1").isEmpty)
    }

    @MainActor
    @Test func removeActiveServerClearsId() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.removeServer("srv1")
        #expect(store.activeServerId == nil)
    }

    // MARK: - Snapshot merge

    @MainActor
    @Test func snapshotReplacesData() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        // "old" is stopped and old enough to be dropped by the merge window
        store.upsert(makeTestSession(
            id: "old",
            status: .stopped,
            createdAt: Date(timeIntervalSinceNow: -600)
        ))

        let snapshot = [
            makeTestSession(id: "new1", lastActivity: Date(timeIntervalSince1970: 200)),
            makeTestSession(id: "new2", lastActivity: Date(timeIntervalSince1970: 100)),
        ]
        store.applyServerSnapshot(snapshot)

        #expect(store.sessions.count == 2)
        #expect(store.sessions[0].id == "new1")
    }

    @MainActor
    @Test func snapshotPreservesActiveSessions() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "local-active", status: .busy))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(ids.contains("server-only"))
        #expect(ids.contains("local-active"))
    }

    @MainActor
    @Test func snapshotPreservesRecentStopped() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "recent", status: .stopped, createdAt: Date()))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(ids.contains("recent"))
    }

    @MainActor
    @Test func snapshotDropsOldStopped() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(
            id: "old",
            status: .stopped,
            createdAt: Date(timeIntervalSinceNow: -600)
        ))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(!ids.contains("old"))
    }

    // MARK: - Freshness

    @MainActor
    @Test func freshnessPerServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.markSyncSucceeded()

        store.switchServer(to: "srv2")
        #expect(store.lastSuccessfulSyncAt == nil)

        store.switchServer(to: "srv1")
        #expect(store.lastSuccessfulSyncAt != nil)
    }

    @MainActor
    @Test func syncLifecycle() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        store.markSyncStarted()
        #expect(store.isSyncing == true)

        store.markSyncSucceeded()
        #expect(store.isSyncing == false)
        #expect(store.lastSyncFailed == false)
        #expect(store.lastSuccessfulSyncAt != nil)
    }

    @MainActor
    @Test func syncFailure() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.markSyncStarted()
        store.markSyncFailed()
        #expect(store.isSyncing == false)
        #expect(store.lastSyncFailed == true)
    }

    // MARK: - Convenience

    @MainActor
    @Test func activeSessionLookup() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.activeSessionId = "s1"
        #expect(store.activeSession?.id == "s1")
    }

    @MainActor
    @Test func workspaceIdForSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1", workspaceId: "w42"))
        #expect(store.workspaceId(for: "s1") == "w42")
        #expect(store.workspaceId(for: "missing") == nil)
    }

    @MainActor
    @Test func sortByLastActivity() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "older", lastActivity: Date(timeIntervalSince1970: 100)))
        store.upsert(makeTestSession(id: "newer", lastActivity: Date(timeIntervalSince1970: 200)))
        store.sort()
        #expect(store.sessions[0].id == "newer")
    }
}
