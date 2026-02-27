import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Foreground Recovery")
struct ServerConnectionForegroundRecoveryTests {

    @MainActor
    @Test func reconnectIfNeededWithoutApiClientIsNoOp() async {
        let conn = ServerConnection()
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectIfNeededReentrancyGuard() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight, "Flag should be reset after completion")
    }

    @MainActor
    @Test func reconnectDoesNotTouchReducerTimeline() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))
        conn._setActiveSessionIdForTesting("s1")

        conn.reducer.process(.agentStart(sessionId: "s1"))
        conn.reducer.process(.textDelta(sessionId: "s1", delta: "hello world"))
        conn.reducer.process(.agentEnd(sessionId: "s1"))
        let countBefore = conn.reducer.items.count
        #expect(countBefore > 0)

        await conn.reconnectIfNeeded()

        #expect(conn.reducer.items.count == countBefore,
                "Foreground recovery must not replace timeline — ChatSessionManager owns that")
    }

    @MainActor
    @Test func reconnectRefreshesWithoutActiveSession() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectSkipsFullListRefreshWhenRecentSyncIsFresh() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.reconnectIfNeeded()

        #expect(conn.sessionStore.lastSyncFailed == false)
        #expect(conn.workspaceStore.lastSyncFailed == false)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func reconnectPerformsFullListRefreshWhenCachedDataIsStale() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let stale = Date().addingTimeInterval(-600)
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: stale)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: stale)

        await conn.reconnectIfNeeded()

        #expect(conn.sessionStore.lastSyncFailed == true)
        #expect(conn.workspaceStore.lastSyncFailed == true)
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @MainActor
    @Test func refreshSessionListSkipsNetworkWhenFreshAndNotForced() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: false)

        #expect(conn.sessionStore.lastSyncFailed == false)
    }

    @MainActor
    @Test func refreshSessionListSkipEmitsStructuredBreadcrumb() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        var skipMetadata: [String: String] = [:]
        conn._onRefreshBreadcrumbForTesting = { message, metadata, _ in
            if message == "session_list.skip" {
                skipMetadata = metadata
            }
        }

        await conn.refreshSessionList(force: false)

        #expect(skipMetadata["force"] == "0")
        #expect(skipMetadata["cachedSessionCount"] == "1")
        #expect(skipMetadata["durationMs"] != nil)
    }

    @MainActor
    @Test func refreshSessionListForceRefreshesEvenWhenFresh() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: true)

        #expect(conn.sessionStore.lastSyncFailed == true)
    }

    @MainActor
    @Test func refreshWorkspaceCatalogSkipsNetworkWhenFreshAndNotForced() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        let now = Date()
        conn.workspaceStore.workspaces = [makeTestWorkspace()]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.refreshWorkspaceCatalog(force: false)

        #expect(conn.workspaceStore.lastSyncFailed == false)
    }

    @MainActor
    @Test func refreshWorkspaceCatalogForceEmitsEndBreadcrumbWithCounts() async {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "192.0.2.1", port: 7749, token: "sk_test", name: "Test"
        ))

        var endMetadata: [String: String] = [:]
        var endLevel: ClientLogLevel?
        conn._onRefreshBreadcrumbForTesting = { message, metadata, level in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
                endLevel = level
            }
        }

        await conn.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["force"] == "1")
        #expect(endMetadata["durationMs"] != nil)
        #expect(endMetadata["workspaceCount"] != nil)
        #expect(endMetadata["sessionCount"] != nil)
        #expect(endMetadata["skillCount"] != nil)
        #expect(endLevel != nil)
    }

    @MainActor
    @Test func flushAndSuspendDoesNotDisconnect() {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test", name: "Test"
        ))
        conn._setActiveSessionIdForTesting("s1")

        conn.flushAndSuspend()

        #expect(conn.wsClient != nil, "WS client should not be nil after suspend")
    }
}
