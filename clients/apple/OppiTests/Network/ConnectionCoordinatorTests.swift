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

    // MARK: - Server Removal

    @Test func removeServerCleansConnection() async {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:remove-test", name: "Victim")

        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "s1", name: "Doomed"))

        await coordinator.removeServer(id: "sha256:remove-test")

        #expect(coordinator.serverStore.server(for: "sha256:remove-test") == nil)
        #expect(coordinator.connections["sha256:remove-test"] == nil)
        #expect(coordinator.activeServerId != "sha256:remove-test")
    }

    @Test func removeActiveServerSwitchesToNext() async {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:auto-switch-a", name: "A")
        let serverB = makeServer(id: "sha256:auto-switch-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)
        coordinator.switchToServer(serverA)

        await coordinator.removeServer(id: "sha256:auto-switch-a")

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

    @Test func unpreparedIrohOnlySwitchAwaitsReadyTransport() async {
        let (coordinator, _) = makeCoordinator()
        guard let server = PairedServer(from: makeTestIrohOnlyCredentials(), sortOrder: 0) else {
            Issue.record("Expected Iroh-only PairedServer")
            return
        }
        coordinator.serverStore.addOrUpdate(server)

        #expect(coordinator.connection(for: server.id) == nil)
        let switched = await coordinator.switchToServerReady(server)

        #expect(switched)
        #expect(coordinator.activeServerId == server.id)
        #expect(coordinator.preparingServerIds.isEmpty)
        #expect(coordinator.activeConnection.transportPath == .iroh)
        #expect(coordinator.activeConnection.apiClient != nil)
        #expect(await coordinator.activeConnection.apiClient?.baseURL.host == "127.0.0.1")
        await coordinator.removeServer(id: server.id)
    }

    @Test func switchToIrohOnlyServerUsesTransparentAPIClient() async {
        let (coordinator, _) = makeCoordinator()
        guard let server = PairedServer(from: makeTestIrohOnlyCredentials(), sortOrder: 0) else {
            Issue.record("Expected Iroh-only PairedServer")
            return
        }

        coordinator.serverStore.addOrUpdate(server)
        let prepared = await coordinator.ensureConnectionReady(for: server)
        let result = await coordinator.switchToServerReady(server)

        #expect(prepared.credentials != nil)
        #expect(result)
        #expect(coordinator.activeServerId == "sha256:iroh-server-fp")
        #expect(coordinator.activeConnection.transportPath == .iroh)
        #expect(coordinator.activeConnection.apiClient != nil)
        #expect(coordinator.apiClient(for: "sha256:iroh-server-fp") != nil)
        #expect(await coordinator.activeConnection.apiClient?.baseURL.host == "127.0.0.1")
        #expect(coordinator.activeConnection.credentials?.baseURL == nil)

        await coordinator.removeServer(id: server.id)
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

    @Test func backgroundActivityIncludesInactiveBusyServer() {
        let (coordinator, _) = makeCoordinator()
        let selected = makeServer(id: "sha256:bg-selected", name: "Selected")
        let inactive = makeServer(id: "sha256:bg-inactive", name: "Inactive")
        coordinator.serverStore.addOrUpdate(selected)
        coordinator.serverStore.addOrUpdate(inactive)

        coordinator.switchToServer(selected)
        coordinator.activeConnection.sessionStore.upsert(
            makeTestSession(id: "selected-idle", status: .ready)
        )
        coordinator.switchToServer(inactive)
        coordinator.activeConnection.sessionStore.upsert(
            makeTestSession(id: "inactive-busy", status: .busy)
        )
        coordinator.switchToServer(selected)

        #expect(coordinator.hasActiveAgentTransport)
        #expect(BackgroundKeepAlive.hasActiveAgent(in: coordinator.connections.values))
    }

    @Test func backgroundActivityIsFalseWhenAllServersIdle() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:bg-idle-a", name: "A")
        let serverB = makeServer(id: "sha256:bg-idle-b", name: "B")
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "idle-a", status: .ready))
        coordinator.switchToServer(serverB)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "idle-b", status: .stopped))

        #expect(!coordinator.hasActiveAgentTransport)
        #expect(!BackgroundKeepAlive.hasActiveAgent(in: coordinator.connections.values))
    }

    @Test func foregroundRecoveryRefreshesInactiveBusyServer() async {
        let (coordinator, _) = makeCoordinator()
        let selected = makeServer(id: "sha256:fg-selected", name: "Selected")
        let inactive = makeServer(id: "sha256:fg-inactive", name: "Inactive")
        coordinator.serverStore.addOrUpdate(selected)
        coordinator.serverStore.addOrUpdate(inactive)
        coordinator.switchToServer(selected)
        coordinator.switchToServer(inactive)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "busy", status: .busy))
        coordinator.switchToServer(selected)

        var refreshed: [String] = []
        coordinator._onRefreshInactiveServerForTesting = { refreshed.append($0) }
        await coordinator.refreshInactiveServers()

        #expect(refreshed == [inactive.id])
    }

    @Test func audioTransportPlaybackOnlyTracksLiveStreams() {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:audio-transport", name: "A")

        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)
        let connection = coordinator.activeConnection

        connection.audioPlayer._setPlaybackStateForTesting(playing: "voice-local", loading: nil)
        #expect(!coordinator.hasActiveAudioTransportPlayback)

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: "s-live")
        #expect(coordinator.hasActiveAudioTransportPlayback)

        connection.audioPlayer._setLiveTransportPlaybackForTesting(sessionID: "s-live", receivedDone: true)
        #expect(!coordinator.hasActiveAudioTransportPlayback)
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
        #expect(result?.connection.sessionStore.session(id: "s-on-a")?.name == "On A")
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

    @Test func prepareAllConnectionsCreatesConnectionsForAllServersWithoutOpeningStreams() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:pool-a", name: "A")
        let serverB = makeServer(id: "sha256:pool-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // Before connecting, only the switched-to server has a connection
        coordinator.switchToServer(serverA)
        #expect(coordinator.connections.count == 1)

        // Prepare all creates connections for remaining servers without opening startup sockets.
        coordinator.prepareAllConnections()
        #expect(coordinator.connections.count == 2)
        #expect(coordinator.connections["sha256:pool-a"] != nil)
        #expect(coordinator.connections["sha256:pool-b"] != nil)
        #expect(coordinator.connections["sha256:pool-a"]?.wsClient?.status == .disconnected)
        #expect(coordinator.connections["sha256:pool-b"]?.wsClient?.status == .disconnected)
    }

    @Test func ensureConnectionReconfiguresExistingConnectionAfterRepair() async {
        let (coordinator, _) = makeCoordinator()
        let original = makeServer(
            id: "sha256:repair-test",
            name: "Studio",
            host: "old.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:oldtls"
        )
        let repaired = makeServer(
            id: "sha256:repair-test",
            name: "Studio",
            host: "new.tail11111.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:newtls"
        )

        coordinator.serverStore.addOrUpdate(original)
        let connection = coordinator.ensureConnection(for: original)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://old.tail00000.ts.net:7749")

        coordinator.serverStore.addOrUpdate(repaired)
        let repairedConnection = coordinator.ensureConnection(for: repaired)

        #expect(repairedConnection === connection)
        #expect(repairedConnection.credentials == repaired.credentials)
        #expect(await repairedConnection.apiClient?.baseURL.absoluteString == "https://new.tail11111.ts.net:7749")
    }

    // MARK: - refreshAllServers ensures connections

    @Test func refreshAllServersCreatesConnectionsBeforeIterating() async {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:refresh-a", name: "A")
        let serverB = makeServer(id: "sha256:refresh-b", name: "B")

        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        // No connections exist yet (we skip switchToServer/prepareAllConnections)
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

    @Test func directCatalogConsumerCoalescesWithSelectedServerRefreshIncludingEmptyCatalog() async {
        defer { TestURLProtocol.handler = nil }

        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:refresh-one-a", name: "A", host: "server-a.test")
        let serverB = makeServer(id: "sha256:refresh-one-b", name: "B", host: "server-b.test")
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        let connectionA = coordinator.ensureConnection(for: serverA)
        let connectionB = coordinator.ensureConnection(for: serverB)
        connectionA.setAPIClientForTesting(makeTestAPIClient(host: "server-a.test"))
        connectionB.setAPIClientForTesting(makeTestAPIClient(host: "server-b.test"))
        connectionA.setSplitStreamCapabilitiesForTesting()
        connectionB.setSplitStreamCapabilitiesForTesting()

        let requestLog = CoordinatorRequestLog()
        let requestGate = CoordinatorRequestGate()
        var refreshEvents: [String] = []
        connectionB._onRefreshEventForTesting = { message, _, _ in
            refreshEvents.append(message)
        }
        TestURLProtocol.handler = { request in
            requestLog.append(request)
            requestGate.blockFirstWorkspaceRequestIfNeeded(request)

            let body = switch request.url?.path {
            case "/workspaces":
                #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#
            case "/skills":
                #"{"skills":[]}"#
            case "/sessions/recent":
                #"{"sessions":[]}"#
            default:
                #"{}"#
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://server-b.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }

        // Models invite bootstrap or WorkspaceListView starting a catalog-only
        // refresh just before the selected-server inbox starts its full refresh.
        let firstRefresh = Task { await connectionB.refreshWorkspaceCatalog(force: true) }
        #expect(await requestLog.waitForCount(path: "/workspaces", expected: 1))

        let secondRefresh = Task { await coordinator.refreshServer(serverB.id, force: true) }
        for _ in 0..<50 where !refreshEvents.contains("workspace_catalog.coalesced") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshEvents.contains("workspace_catalog.coalesced"))
        requestGate.releaseFirstWorkspaceRequest()

        await firstRefresh.value
        await secondRefresh.value

        let hosts = requestLog.hosts()
        #expect(!hosts.isEmpty)
        #expect(hosts.allSatisfy { $0 == "server-b.test" })
        #expect(requestLog.count(path: "/workspaces") == 1)
        #expect(requestLog.count(path: "/skills") == 1)
        #expect(requestLog.count(path: "/sessions/recent") == 1)
        #expect(connectionB.workspaceStore.isLoaded)
        #expect(!connectionB.workspaceStore.lastSyncFailed)
        #expect(!connectionB.sessionStore.lastSyncFailed)
    }

    @Test func refreshServerKeepsFailedUnloadedCatalogDistinctFromSuccessfulEmptySessions() async {
        defer { TestURLProtocol.handler = nil }

        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:refresh-failed-catalog", name: "Unavailable", host: "failed.test")
        coordinator.serverStore.addOrUpdate(server)

        let connection = coordinator.ensureConnection(for: server)
        connection.setAPIClientForTesting(makeTestAPIClient(host: "failed.test"))
        connection.setSplitStreamCapabilitiesForTesting()

        let requestLog = CoordinatorRequestLog()
        TestURLProtocol.handler = { request in
            requestLog.append(request)

            let statusCode: Int
            let body: String
            switch request.url?.path {
            case "/workspaces":
                statusCode = 503
                body = #"{"error":"catalog unavailable"}"#
            case "/skills":
                statusCode = 200
                body = #"{"skills":[]}"#
            case "/sessions/recent":
                statusCode = 200
                body = #"{"sessions":[]}"#
            default:
                statusCode = 404
                body = #"{}"#
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://failed.test")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }

        await coordinator.refreshServer(server.id, force: true)

        #expect(requestLog.count(path: "/workspaces") == 2, "An unloaded failed catalog gets one session-path retry")
        #expect(requestLog.count(path: "/skills") == 2)
        #expect(requestLog.count(path: "/sessions/recent") == 1)
        #expect(!connection.workspaceStore.isLoaded)
        #expect(connection.workspaceStore.workspaces.isEmpty)
        #expect(connection.workspaceStore.lastSyncFailed)
        #expect(!connection.sessionStore.lastSyncFailed)
        #expect(connection.sessionStore.listProjectionSessions.isEmpty)
    }

    @Test func refreshServerMarksSyncFailedWithoutAPIClient() async {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:refresh-no-api", name: "Unavailable")
        coordinator.serverStore.addOrUpdate(server)

        let connection = coordinator.ensureConnection(for: server)
        connection.setAPIClientForTesting(nil)

        await coordinator.refreshServer(server.id, force: true)

        #expect(connection.workspaceStore.lastSyncFailed)
        #expect(connection.sessionStore.lastSyncFailed)
    }

    // MARK: - LAN Discovery Integration

    @Test func lanDiscoveryUpdatesMatchingConnectionAndFallsBackWhenMissing() {
        let (coordinator, _) = makeCoordinator()

        let lanServer = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "LAN",
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        let otherServer = makeServer(
            id: "sha256:OTHERSERVERFINGERPRINT",
            name: "Other",
            host: "other.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:OTHERTLSFINGERPRINT"
        )

        coordinator.serverStore.addOrUpdate(lanServer)
        coordinator.serverStore.addOrUpdate(otherServer)

        let lanConnection = coordinator.ensureConnection(for: lanServer)
        let otherConnection = coordinator.ensureConnection(for: otherServer)

        #expect(lanConnection.transportPath == .paired)
        #expect(otherConnection.transportPath == .paired)

        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])

        #expect(lanConnection.transportPath == .lan)
        #expect(otherConnection.transportPath == .paired)

        coordinator._applyLANDiscoveryForTesting([])

        #expect(lanConnection.transportPath == .paired)
        #expect(otherConnection.transportPath == .paired)
    }

    @Test func lanDiscoveryPrefersCandidateThatPassesTLSPinValidation() async {
        let (coordinator, _) = makeCoordinator()

        // Use an IP-based host so HTTPS hostname preservation doesn't
        // replace the discovered LAN IP in the URL (hostname-based hosts
        // keep the paired hostname for TLS CN/SAN compat).
        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "LAN",
            host: "10.0.0.1",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        coordinator.serverStore.addOrUpdate(server)
        let connection = coordinator.ensureConnection(for: server)

        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.10",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "WRONGTLS"
            ),
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])

        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func lanDiscoveryPrefersMoreSpecificFingerprintCandidate() async {
        let (coordinator, _) = makeCoordinator()

        // Use an IP-based host so HTTPS hostname preservation doesn't
        // replace the discovered LAN IP in the URL.
        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "LAN",
            host: "10.0.0.1",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        coordinator.serverStore.addOrUpdate(server)
        let connection = coordinator.ensureConnection(for: server)

        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.10",
                port: 7749,
                serverFingerprintPrefix: "SERVER",
                tlsCertFingerprintPrefix: nil
            ),
        ])

        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.10:7749")

        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.10",
                port: 7749,
                serverFingerprintPrefix: "SERVER",
                tlsCertFingerprintPrefix: nil
            ),
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])

        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
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
        guard let irohLoopbackURL = URL(string: "http://127.0.0.1:41996") else {
            preconditionFailure("Static Iroh loopback fixture must be valid")
        }
        coordinator._irohProxyFactoryForTesting = { _, _ in
            (nil, irohLoopbackURL)
        }
        return (coordinator, store)
    }

    private func makeTestAPIClient(host: String) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://\(host):7749")!,
            token: "sk_test",
            configuration: configuration
        )
    }

    private func makeServer(
        id: String,
        name: String,
        host: String = "localhost",
        scheme: ServerScheme = .http,
        tlsFingerprint: String? = nil
    ) -> PairedServer {
        let creds = ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_test",
            name: name,
            scheme: scheme,
            serverFingerprint: id,
            tlsCertFingerprint: tlsFingerprint
        )

        guard let server = PairedServer(from: creds, sortOrder: 0) else {
            preconditionFailure("Failed to create PairedServer for test")
        }

        return server
    }

}

private final class CoordinatorRequestLog: @unchecked Sendable {
    private struct Entry {
        let host: String
        let path: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ request: URLRequest) {
        lock.withLock {
            entries.append(Entry(
                host: request.url?.host ?? "",
                path: request.url?.path ?? ""
            ))
        }
    }

    func hosts() -> [String] {
        lock.withLock { entries.map(\.host) }
    }

    func count(path: String) -> Int {
        lock.withLock { entries.count { $0.path == path } }
    }

    func waitForCount(path: String, expected: Int, timeoutMs: Int = 1_000) async -> Bool {
        let attempts = max(1, timeoutMs / 10)
        for _ in 0..<attempts {
            if count(path: path) >= expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class CoordinatorRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasBlockedWorkspaceRequest = false

    func blockFirstWorkspaceRequestIfNeeded(_ request: URLRequest) {
        guard request.url?.path == "/workspaces" else { return }
        let shouldBlock = lock.withLock {
            guard !hasBlockedWorkspaceRequest else { return false }
            hasBlockedWorkspaceRequest = true
            return true
        }
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    func releaseFirstWorkspaceRequest() {
        releaseSemaphore.signal()
    }
}
