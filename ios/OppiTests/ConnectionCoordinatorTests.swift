import Foundation
import Testing
@testable import Oppi

@Suite("ConnectionCoordinator", .serialized)
@MainActor
struct ConnectionCoordinatorTests {

    // MARK: - Server Switching

    @Test func switchToServerUpdatesActiveServer() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:switch-test", name: "Studio")

        coordinator.serverStore.addOrUpdate(server)
        let result = coordinator.switchToServer(server)

        #expect(result == true)
        #expect(coordinator.activeServerId == "sha256:switch-test")
        #expect(coordinator.activeConnection.currentServerId == "sha256:switch-test")
        #expect(coordinator.activeConnection.sessionStore.activeServerId == "sha256:switch-test")
        #expect(coordinator.activeConnection.permissionStore.activeServerId == "sha256:switch-test")
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

    // MARK: - Per-Server Connection Isolation

    @Test func eachServerGetsOwnConnection() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:iso-a", name: "Server A")
        let serverB = makeServer(id: "sha256:iso-b", name: "Server B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        let connA = coordinator.activeConnection

        coordinator.switchToServer(serverB)
        let connB = coordinator.activeConnection

        // Different connection instances
        #expect(connA !== connB)
        #expect(connA.currentServerId == "sha256:iso-a")
        #expect(connB.currentServerId == "sha256:iso-b")
    }

    @Test func sessionsAreIsolatedBetweenServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:iso-a", name: "Server A")
        let serverB = makeServer(id: "sha256:iso-b", name: "Server B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Add sessions to server A
        coordinator.switchToServer(serverA)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s1", name: "Session A"))

        // Switch to server B — should see empty sessions
        coordinator.switchToServer(serverB)
        #expect(coordinator.activeConnection.sessionStore.sessions.isEmpty)

        // Add sessions to server B
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s2", name: "Session B"))
        #expect(coordinator.activeConnection.sessionStore.sessions.count == 1)
        #expect(coordinator.activeConnection.sessionStore.sessions[0].name == "Session B")

        // Switch back to server A — session A should still be there
        coordinator.switchToServer(serverA)
        #expect(coordinator.activeConnection.sessionStore.sessions.count == 1)
        #expect(coordinator.activeConnection.sessionStore.sessions[0].name == "Session A")
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
        coordinator.activeConnection.permissionStore.add(makePermission(id: "p1"))

        // Server B should be empty
        coordinator.switchToServer(serverB)
        #expect(coordinator.activeConnection.permissionStore.pending.isEmpty)

        // Cross-server query should find it
        #expect(coordinator.allPendingPermissions.count == 1)
        #expect(coordinator.allPendingPermissionCount == 1)
    }

    // MARK: - Server Removal

    @Test func removeServerCleansConnection() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:remove-test", name: "Victim")

        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s1", name: "Doomed"))
        coordinator.activeConnection.permissionStore.add(makePermission(id: "p1"))

        coordinator.removeServer(id: "sha256:remove-test")

        #expect(coordinator.serverStore.server(for: "sha256:remove-test") == nil)
        #expect(coordinator.connections["sha256:remove-test"] == nil)
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

    // MARK: - API Client Per Connection

    @Test func apiClientIsFromConnectionForServer() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:api-cache", name: "Cache")
        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)

        let client1 = coordinator.apiClient(for: "sha256:api-cache")
        let client2 = coordinator.apiClient(for: "sha256:api-cache")

        #expect(client1 != nil)
        // Same connection → same API client
        #expect(client1 === client2)
    }

    // MARK: - Cross-Server Queries

    @Test func allSessionsSpansServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:cross-a", name: "A")
        let serverB = makeServer(id: "sha256:cross-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s1", name: "A1"))

        coordinator.switchToServer(serverB)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s2", name: "B1"))

        let allSessions = coordinator.allSessions
        #expect(allSessions.count == 2)
    }

    @Test func findSessionAcrossServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:find-a", name: "A")
        let serverB = makeServer(id: "sha256:find-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s-on-a", name: "On A"))

        coordinator.switchToServer(serverB)
        // Currently on B, find session that lives on A
        let result = coordinator.findSession(id: "s-on-a")
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
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s-push-target", name: "Target"))

        // Switch to server B (simulate user looking at different server)
        coordinator.switchToServer(serverB)
        #expect(coordinator.activeServerId == "sha256:push-b")

        // Push notification arrives for session on server A — find and switch
        if let found = coordinator.findSession(id: "s-push-target") {
            coordinator.switchToServer(found.serverId)
            found.connection.sessionStore.activeSessionId = "s-push-target"
        }

        #expect(coordinator.activeServerId == "sha256:push-a")
        #expect(coordinator.activeConnection.sessionStore.activeSessionId == "s-push-target")
    }

    // MARK: - Connection Pool

    @Test func connectAllStreamsCreatesConnectionsForAllServers() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:pool-a", name: "A")
        let serverB = makeServer(id: "sha256:pool-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Before connecting, only the switched-to server has a connection
        coordinator.switchToServer(serverA)
        #expect(coordinator.connections.count == 1)

        // Connect all creates connections for remaining servers
        coordinator.connectAllStreams()
        #expect(coordinator.connections.count == 2)
        #expect(coordinator.connections["sha256:pool-a"] != nil)
        #expect(coordinator.connections["sha256:pool-b"] != nil)
    }

    // MARK: - refreshAllServers ensures connections

    @Test func refreshAllServersCreatesConnectionsBeforeIterating() async {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:refresh-a", name: "A")
        let serverB = makeServer(id: "sha256:refresh-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // No connections exist yet (we skip switchToServer/connectAllStreams)
        #expect(coordinator.connections.isEmpty)

        // refreshAllServers should create connections via ensureConnection
        await coordinator.refreshAllServers()

        #expect(coordinator.connections.count == 2)
        #expect(coordinator.connections["sha256:refresh-a"] != nil)
        #expect(coordinator.connections["sha256:refresh-b"] != nil)
    }

    @Test func refreshAllServersCoalescesConcurrentCalls() async {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:coalesce", name: "Studio")

        coordinator.serverStore.addOrUpdate(server)
        coordinator.ensureConnection(for: server)

        // Launch two concurrent refreshes
        async let refresh1: Void = coordinator.refreshAllServers()
        async let refresh2: Void = coordinator.refreshAllServers()

        // Both should complete without crash or deadlock
        _ = await (refresh1, refresh2)

        // Connection should still exist and be valid
        #expect(coordinator.connections["sha256:coalesce"] != nil)
    }

    // MARK: - Workspace Store Order

    @Test func workspaceServerOrderMatchesServerStore() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:order-a", name: "A")
        let serverB = makeServer(id: "sha256:order-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)
        coordinator.switchToServer(serverA)

        coordinator.activeConnection.workspaceStore.serverOrder = coordinator.serverStore.servers.map(\.id)

        let order = coordinator.activeConnection.workspaceStore.serverOrder
        #expect(order.contains("sha256:order-a"))
        #expect(order.contains("sha256:order-b"))
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (ConnectionCoordinator, ServerStore) {
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
