import Foundation
import Network
import Testing
@testable import Oppi

// MARK: - ServerConnection.handleNetworkPathChange Tests

@Suite("ServerConnection Network Path Change", .serialized)
@MainActor
struct ServerConnectionNetworkPathChangeTests {

    // MARK: - Endpoint Clearing

    @Test func pathChangeClearsLANEndpointAndFallsToPaired() async {
        let (conn, pipe) = makeConnectionOnLAN()
        #expect(conn.transportPath == .lan)

        conn.handleNetworkPathChange()

        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func pathChangeWhenAlreadyPairedStaysPaired() async {
        let conn = makeConnectionPaired()
        #expect(conn.transportPath == .paired)

        conn.handleNetworkPathChange()

        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    // MARK: - Reconnect Decisions by WS Status

    @Test func reconnecting_forcesImmediateReconnect() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn.wsClient?._setStatusForTesting(.reconnecting(attempt: 5))

        conn.handleNetworkPathChange()

        // cancelReconnectBackoff sets status to .disconnected, then connectStream()
        // starts a fresh connection. The WS client should exist and not be in
        // .reconnecting state anymore.
        #expect(conn.wsClient != nil)
        #expect(conn.transportPath == .paired)
        // Should NOT still be stuck in reconnecting with the old attempt count
        if case .reconnecting(let attempt) = conn.wsClient?.status {
            #expect(attempt <= 1, "Should have reset reconnect attempts, not carried forward attempt 5")
        }
    }

    @Test func connectedViaLAN_forcesReconnect() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn.wsClient?._setStatusForTesting(.connected)
        #expect(conn.transportPath == .lan)

        conn.handleNetworkPathChange()

        // After path change, endpoint should be paired and WS should be
        // reconnecting or connecting (not still .connected to dead LAN IP)
        #expect(conn.transportPath == .paired)
        #expect(conn.wsClient?.status != .connected,
                "Should not remain connected to the stale LAN IP")
    }

    @Test func connectedViaPaired_noReconnect() {
        let conn = makeConnectionPaired()
        conn.wsClient?._setStatusForTesting(.connected)
        #expect(conn.transportPath == .paired)

        conn.handleNetworkPathChange()

        // Paired (Tailscale) connections survive network changes —
        // Tailscale handles mobility internally. Should stay connected.
        #expect(conn.wsClient?.status == .connected)
        #expect(conn.transportPath == .paired)
    }

    @Test func disconnected_triggersReconnect() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.handleNetworkPathChange()

        // Should attempt to reconnect with the updated (paired) endpoint
        #expect(conn.transportPath == .paired)
        #expect(conn.wsClient != nil)
    }

    @Test func connecting_noForceReconnect() {
        let conn = makeConnectionPaired()
        conn.wsClient?._setStatusForTesting(.connecting)

        conn.handleNetworkPathChange()

        // .connecting state is transient — let the in-progress handshake
        // finish or fail on its own. Endpoint is already updated for next attempt.
        #expect(conn.transportPath == .paired)
    }

    // MARK: - Session Preservation

    @Test func pathChangePreservesActiveSessionId() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn._setActiveSessionIdForTesting("s1")
        conn.wsClient?._setStatusForTesting(.connected)

        conn.handleNetworkPathChange()

        #expect(conn.activeSessionId == "s1",
                "Active session must survive network path change")
    }

    @Test func pathChangePreservesNotificationSubscriptions() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn._setActiveSessionIdForTesting("s1")
        conn.notificationSessionIds = ["s2", "s3"]
        conn.wsClient?._setStatusForTesting(.connected)

        conn.handleNetworkPathChange()

        #expect(conn.notificationSessionIds == ["s2", "s3"],
                "Notification subscriptions must survive network path change")
    }

    @Test func pathChangePreservesReducerTimeline() {
        let (conn, pipe) = makeConnectionOnLAN()
        conn.wsClient?._setStatusForTesting(.connected)

        pipe.reducer.process(.agentStart(sessionId: "s1"))
        pipe.reducer.process(.textDelta(sessionId: "s1", delta: "hello world"))
        pipe.reducer.process(.agentEnd(sessionId: "s1"))
        let countBefore = pipe.reducer.items.count
        #expect(countBefore > 0)

        conn.handleNetworkPathChange()

        #expect(pipe.reducer.items.count == countBefore,
                "Timeline must not be cleared by network path change")
    }

    // MARK: - No WS Client

    @Test func pathChangeWithoutWSClientIsNoOp() {
        let conn = ServerConnection()
        // Not configured — no wsClient
        conn.handleNetworkPathChange()
        // Should not crash
        #expect(conn.wsClient == nil)
    }

    // MARK: - Helpers

    private func makeLANCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "sk_test",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
    }

    private func makeConnectionOnLAN() -> (conn: ServerConnection, pipe: TestEventPipeline) {
        let conn = ServerConnection()
        let creds = makeLANCredentials()
        conn.configure(credentials: creds)
        conn._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: conn)

        // Simulate Bonjour discovering a matching LAN endpoint
        conn.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        return (conn, pipe)
    }

    private func makeConnectionPaired() -> ServerConnection {
        let conn = ServerConnection()
        let creds = makeLANCredentials()
        conn.configure(credentials: creds)
        // No LAN endpoint — stays on paired/Tailscale
        return conn
    }
}

// MARK: - Reconnect Delay Sanity (complements WebSocketClientReconnectBackoffTests)

@Suite("Network Path Change — Reconnect Delay Sanity")
struct PathChangeReconnectDelaySanityTests {

    @Test func totalReconnectWindowIsReasonable() {
        // Verify that even without NWPathMonitor intervention,
        // the full 10-attempt window doesn't exceed ~90s.
        // With path monitoring, recovery should be < 1s.
        var total: Double = 0
        for attempt in 1...10 {
            total += WebSocketClient.reconnectDelay(attempt: attempt)
        }
        #expect(total < 100, "Total reconnect window should be under 100s")
        #expect(total > 10, "Total should reflect escalating backoff")
    }
}

// MARK: - ConnectionCoordinator Path Change Integration Tests

@Suite("ConnectionCoordinator Network Path Change", .serialized)
@MainActor
struct ConnectionCoordinatorPathChangeTests {

    @Test func applyNetworkPathChangeClearsLANOnAllConnections() {
        let (coordinator, _) = makeCoordinator()

        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "Studio",
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        coordinator.serverStore.addOrUpdate(server)
        let conn = coordinator.ensureConnection(for: server)

        // Put connection on LAN
        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])
        #expect(conn.transportPath == .lan)

        // Simulate network path change (calls handleNetworkPathChange on all connections)
        coordinator._applyNetworkPathChangeForTesting()

        #expect(conn.transportPath == .paired,
                "LAN endpoint should be cleared after network path change")
    }

    @Test func applyNetworkPathChangeAffectsMultipleServers() {
        let (coordinator, _) = makeCoordinator()

        let serverA = makeServer(
            id: "sha256:SERVERAFINGERPRINT",
            name: "Server A",
            host: "server-a.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSAFINGERPRINTABCDEF"
        )
        let serverB = makeServer(
            id: "sha256:SERVERBFINGERPRINT",
            name: "Server B",
            host: "server-b.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSBFINGERPRINTABCDEF"
        )
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)

        let connA = coordinator.ensureConnection(for: serverA)
        let connB = coordinator.ensureConnection(for: serverB)

        // Put server A on LAN, server B stays paired
        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERAFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSAFINGERPRINT"
            ),
        ])
        #expect(connA.transportPath == .lan)
        #expect(connB.transportPath == .paired)

        coordinator._applyNetworkPathChangeForTesting()

        #expect(connA.transportPath == .paired, "Server A should fall back to paired")
        #expect(connB.transportPath == .paired, "Server B should remain paired")
    }

    @Test func pathMonitorStartAndStopAreIdempotent() {
        let (coordinator, _) = makeCoordinator()

        // Start twice — should not crash
        coordinator.startNetworkPathMonitor()
        coordinator.startNetworkPathMonitor()

        // Stop twice — should not crash
        coordinator.stopNetworkPathMonitor()
        coordinator.stopNetworkPathMonitor()
    }

    // MARK: - Full LAN→Tailscale Transition Simulation

    @Test func simulateLANToTailscaleTransition() async {
        let (coordinator, _) = makeCoordinator()

        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "Studio",
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)

        let conn = coordinator.activeConnection

        // Step 1: Bonjour discovers LAN endpoint (user is on home WiFi)
        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])
        #expect(conn.transportPath == .lan)
        #expect(await conn.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")

        // Step 2: User has an active session
        conn._setActiveSessionIdForTesting("s1")
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))

        // Step 3: WS was connected via LAN
        conn.wsClient?._setStatusForTesting(.connected)

        // Step 4: User walks out — network interface changes.
        // NWPathMonitor fires → coordinator calls handleNetworkPathChange on all connections.
        // (In real code, this goes through the debounce; we call directly for test.)
        coordinator._applyNetworkPathChangeForTesting()

        // Step 5: Verify recovery
        #expect(conn.transportPath == .paired,
                "Should fall back to paired/Tailscale endpoint")
        #expect(await conn.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749",
                "API client should use Tailscale address")
        #expect(conn.activeSessionId == "s1",
                "Active session must survive the transition")
        #expect(conn.sessionStore.sessions.first(where: { $0.id == "s1" })?.status == .busy,
                "Session status must survive the transition")
        #expect(conn.wsClient?.status != .connected,
                "Old LAN connection should be torn down")
    }

    @Test func simulateReconnectingDuringLANToTailscale() async {
        let (coordinator, _) = makeCoordinator()

        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "Studio",
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)

        let conn = coordinator.activeConnection

        // LAN endpoint active
        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])
        #expect(conn.transportPath == .lan)

        // WS was already reconnecting (TCP to LAN died, backoff in progress)
        conn.wsClient?._setStatusForTesting(.reconnecting(attempt: 7))

        // NWPathMonitor fires
        coordinator._applyNetworkPathChangeForTesting()

        // Should have cancelled the stale backoff and started fresh
        #expect(conn.transportPath == .paired)
        // Should NOT still be at attempt 7
        if case .reconnecting(let attempt) = conn.wsClient?.status {
            #expect(attempt <= 1,
                    "Reconnect attempt should reset after path change, not carry attempt \(attempt)")
        }
    }

    @Test func simulateTailscaleToLAN_noDisruption() async {
        let (coordinator, _) = makeCoordinator()

        let server = makeServer(
            id: "sha256:SERVERFINGERPRINTABCDEF",
            name: "Studio",
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        coordinator.serverStore.addOrUpdate(server)
        coordinator.switchToServer(server)

        let conn = coordinator.activeConnection
        #expect(conn.transportPath == .paired)

        // Connected via Tailscale
        conn.wsClient?._setStatusForTesting(.connected)

        // Network changes (walked back into LAN range)
        coordinator._applyNetworkPathChangeForTesting()

        // Tailscale connection should NOT be disrupted
        #expect(conn.wsClient?.status == .connected,
                "Working Tailscale connection should not be force-closed")
        #expect(conn.transportPath == .paired,
                "Should stay paired until Bonjour discovers LAN endpoint")

        // Later, Bonjour discovers LAN endpoint — endpoint updates for NEXT connection
        coordinator._applyLANDiscoveryForTesting([
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            ),
        ])
        #expect(conn.transportPath == .lan,
                "LAN endpoint should be preferred once discovered")
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (ConnectionCoordinator, ServerStore) {
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
        KeychainService.deleteAllServers()
        let store = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: store)
        return (coordinator, store)
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

// MARK: - Reconnect Backoff Curve Tests (delay verification)

@Suite("WebSocket Reconnect Delay Curve")
struct ReconnectDelayCurveTests {

    @Test func firstThreeAttemptsAreSubSecond() {
        for attempt in 1...3 {
            let delay = WebSocketClient.reconnectDelay(attempt: attempt)
            #expect(delay < 1.0, "Attempt \(attempt) delay \(delay) should be sub-second for fast recovery")
        }
    }

    @Test func laterAttemptsEscalate() {
        let delay4 = WebSocketClient.reconnectDelay(attempt: 4)
        let delay6 = WebSocketClient.reconnectDelay(attempt: 6)
        let delay10 = WebSocketClient.reconnectDelay(attempt: 10)

        #expect(delay4 >= 1.0, "Attempt 4 should have at least 1s delay")
        #expect(delay6 > delay4, "Delay should escalate")
        #expect(delay10 <= 20.0, "Cap should prevent excessive delays")
    }
}
