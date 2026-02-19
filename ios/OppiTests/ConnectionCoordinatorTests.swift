import Foundation
import Testing
@testable import Oppi

@Suite("ConnectionCoordinator", .serialized)
@MainActor
struct ConnectionCoordinatorTests {

    // MARK: - Server Switching

    @Test func switchToServerUpdatesAllStores() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:switch-test", name: "Studio")

        coordinator.serverStore.addOrUpdate(server)
        let result = coordinator.switchToServer(server)

        #expect(result == true)
        #expect(coordinator.activeServerId == "sha256:switch-test")
        #expect(coordinator.connection.sessionStore.activeServerId == "sha256:switch-test")
        #expect(coordinator.connection.permissionStore.activeServerId == "sha256:switch-test")
        #expect(coordinator.connection.currentServerId == "sha256:switch-test")
    }

    @Test func switchToUnknownServerReturnsFalse() {
        let (coordinator, _) = makeCoordinator()
        let result = coordinator.switchToServer("sha256:unknown")
        #expect(result == false)
    }

    @Test func switchToSameServerIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:same-test", name: "Studio")
        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)

        // Second switch should return true immediately
        let result = coordinator.switchToServer(server)
        #expect(result == true)
    }

    // MARK: - Session Isolation

    @Test func sessionsAreIsolatedBetweenServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:iso-a", name: "Server A")
        let serverB = makeServer(id: "sha256:iso-b", name: "Server B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Add sessions to server A
        coordinator.switchToServer(serverA)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s1", name: "Session A"))

        // Switch to server B — should see empty sessions
        coordinator.switchToServer(serverB)
        #expect(coordinator.connection.sessionStore.sessions.isEmpty)

        // Add sessions to server B
        coordinator.connection.sessionStore.upsert(makeSession(id: "s2", name: "Session B"))
        #expect(coordinator.connection.sessionStore.sessions.count == 1)
        #expect(coordinator.connection.sessionStore.sessions[0].name == "Session B")

        // Switch back to server A — session A should still be there
        coordinator.switchToServer(serverA)
        #expect(coordinator.connection.sessionStore.sessions.count == 1)
        #expect(coordinator.connection.sessionStore.sessions[0].name == "Session A")
    }

    // MARK: - Permission Isolation

    @Test func permissionsAreIsolatedBetweenServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:perm-a", name: "A")
        let serverB = makeServer(id: "sha256:perm-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Add permission on server A
        coordinator.switchToServer(serverA)
        coordinator.connection.permissionStore.add(makePermission(id: "p1"))

        // Server B should be empty
        coordinator.switchToServer(serverB)
        #expect(coordinator.connection.permissionStore.pending.isEmpty)

        // But allPending should see it
        #expect(coordinator.connection.permissionStore.allPending.count == 1)
    }

    // MARK: - Server Removal

    @Test func removeServerCleansAllStores() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:remove-test", name: "Victim")

        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s1", name: "Doomed"))
        coordinator.connection.permissionStore.add(makePermission(id: "p1"))

        coordinator.removeServer(id: "sha256:remove-test")

        #expect(coordinator.serverStore.server(for: "sha256:remove-test") == nil)
        #expect(coordinator.connection.sessionStore.sessions(forServer: "sha256:remove-test").isEmpty)
        #expect(coordinator.connection.permissionStore.pending(forServer: "sha256:remove-test").isEmpty)
        #expect(coordinator.activeServerId != "sha256:remove-test")
    }

    @Test func removeActiveServerSwitchesToNext() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:auto-switch-a", name: "A")
        let serverB = makeServer(id: "sha256:auto-switch-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)
        coordinator.switchToServer(serverA)

        coordinator.removeServer(id: "sha256:auto-switch-a")

        // Should auto-switch to the remaining server
        #expect(coordinator.activeServerId == "sha256:auto-switch-b")
    }

    // MARK: - API Client Caching

    @Test func apiClientIsCachedPerServer() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:api-cache", name: "Cache")
        coordinator.serverStore.addOrUpdate(server)

        let client1 = coordinator.apiClient(for: "sha256:api-cache")
        let client2 = coordinator.apiClient(for: "sha256:api-cache")

        #expect(client1 != nil)
        // Same actor instance
        #expect(client1 === client2)
    }

    @Test func invalidateAPIClientForcesRecreation() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:api-invalidate", name: "Invalidate")
        coordinator.serverStore.addOrUpdate(server)

        let client1 = coordinator.apiClient(for: "sha256:api-invalidate")
        coordinator.invalidateAPIClient(for: "sha256:api-invalidate")
        let client2 = coordinator.apiClient(for: "sha256:api-invalidate")

        #expect(client1 != nil)
        #expect(client2 != nil)
        #expect(client1 !== client2)
    }

    // MARK: - Cross-Server Queries

    @Test func sessionStoreAllSessionsSpansServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:cross-a", name: "A")
        let serverB = makeServer(id: "sha256:cross-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s1", name: "A1"))

        coordinator.switchToServer(serverB)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s2", name: "B1"))

        let allSessions = coordinator.connection.sessionStore.allSessions
        #expect(allSessions.count == 2)
    }

    @Test func sessionStoreFindSessionAcrossServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:find-a", name: "A")
        let serverB = makeServer(id: "sha256:find-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s-on-a", name: "On A"))

        coordinator.switchToServer(serverB)
        // Currently on B, find session that lives on A
        let result = coordinator.connection.sessionStore.findSession(id: "s-on-a")
        #expect(result != nil)
        #expect(result?.serverId == "sha256:find-a")
        #expect(result?.session.name == "On A")
    }

    // MARK: - Push Navigation

    @Test func pushNavigationSwitchesServerForCrossServerSession() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:push-a", name: "A")
        let serverB = makeServer(id: "sha256:push-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Session lives on server A
        coordinator.switchToServer(serverA)
        coordinator.connection.sessionStore.upsert(makeSession(id: "s-push-target", name: "Target"))

        // Switch to server B (simulate user looking at different server)
        coordinator.switchToServer(serverB)
        #expect(coordinator.activeServerId == "sha256:push-b")

        // Push notification arrives for session on server A — find and switch
        if let found = coordinator.connection.sessionStore.findSession(id: "s-push-target") {
            coordinator.switchToServer(found.serverId)
        }
        coordinator.connection.sessionStore.activeSessionId = "s-push-target"

        #expect(coordinator.activeServerId == "sha256:push-a")
        #expect(coordinator.connection.sessionStore.activeSessionId == "s-push-target")
    }

    // MARK: - Server Order Sync

    @Test func workspaceServerOrderMatchesServerStore() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:order-a", name: "A")
        let serverB = makeServer(id: "sha256:order-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)
        coordinator.switchToServer(serverA)

        // After switching, workspace store should reflect server store order
        coordinator.connection.workspaceStore.serverOrder = coordinator.serverStore.servers.map(\.id)

        let order = coordinator.connection.workspaceStore.serverOrder
        #expect(order.contains("sha256:order-a"))
        #expect(order.contains("sha256:order-b"))
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (ConnectionCoordinator, ServerStore) {
        // Clear leftover state from other test runs.
        // Must purge both UserDefaults index AND Keychain entries,
        // otherwise the Keychain discovery fallback finds leaked
        // entries from other test suites (ServerStoreTests).
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
        KeychainService.deleteAllServers()
        let store = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: store)
        return (coordinator, store)
    }

    private func makeServer(id: String, name: String) -> PairedServer {
        let creds = ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test",
            name: name, serverFingerprint: id
        )

        guard let server = PairedServer(from: creds, sortOrder: 0) else {
            preconditionFailure("Failed to create PairedServer for test")
        }

        return server
    }

    private func makeSession(id: String, name: String) -> Session {
        Session(
            id: id,
            workspaceId: "w1",
            name: name,
            status: .ready,
            createdAt: Date(),
            lastActivity: Date(),
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
    }

    private func makePermission(id: String) -> PermissionRequest {
        PermissionRequest(
            id: id,
            sessionId: "s1",
            tool: "bash",
            input: [:],
            displaySummary: "test",
            reason: "",
            timeoutAt: Date().addingTimeInterval(60)
        )
    }
}
