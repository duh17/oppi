import Foundation
import Testing
@testable import Oppi

private actor CoordinatorPreparationGate {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func suspendPreparation() async {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

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

    @Test func restoreActiveServerSwitchesWithoutWaitingForHTTPS() {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:restore-a", name: "Server A")
        let serverB = makeServer(id: "sha256:restore-b", name: "Server B")
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.serverStore.addOrUpdate(serverB)
        coordinator.activatePairedServerShell(serverA)
        coordinator.activatePairedServerShell(serverB)
        #expect(coordinator.activeServerId == "sha256:restore-b")

        #expect(coordinator.restoreActiveServer("sha256:restore-a"))
        #expect(coordinator.activeServerId == "sha256:restore-a")
        #expect(coordinator.restoreActiveServer("sha256:unknown") == false)
        #expect(coordinator.activeServerId == "sha256:restore-a")
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

    @Test func supersededPreparationDoesNotActivateServerOrNavigate() async {
        let (coordinator, _) = makeCoordinator()
        let newerServer = makeServer(id: "sha256:newer-server", name: "Newer")
        let staleServer = makeServer(id: "sha256:stale-server", name: "Stale")
        coordinator.serverStore.addOrUpdate(newerServer)
        coordinator.serverStore.addOrUpdate(staleServer)
        coordinator.switchToServer(newerServer)

        let navigation = AppNavigation()
        navigation.openWorkspaceSession(.init(
            serverId: newerServer.id,
            sessionId: "newer-session",
            workspaceId: "newer-workspace"
        ))
        let requestCoordinator = ResourceReferenceRequestCoordinator()
        let gate = CoordinatorPreparationGate()
        coordinator._initialLANEndpointForTesting = { serverID in
            guard serverID == staleServer.id else { return nil }
            await gate.suspendPreparation()
            return nil
        }

        requestCoordinator.perform { token in
            let switched = await coordinator.switchToServerReady(
                staleServer,
                shouldActivate: { requestCoordinator.isCurrent(token) }
            )
            guard switched, requestCoordinator.isCurrent(token) else { return }
            navigation.openReferencedSession(.init(
                serverId: staleServer.id,
                sessionId: "stale-session",
                workspaceId: "stale-workspace"
            ))
        }
        await gate.waitUntilStarted()

        requestCoordinator.perform { token in
            #expect(requestCoordinator.isCurrent(token))
        }
        await gate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.activeServerId == newerServer.id)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "newer-session")
    }

    @Test func missingBonjourCandidateUsesPairedTransport() async {
        let (coordinator, _) = makeCoordinator()
        let server = makeServer(id: "sha256:no-lan-wait", name: "Cellular")
        coordinator.serverStore.addOrUpdate(server)

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(connection.transportPath == .paired)
    }

    @Test func existingLiveConnectionStillRunsLeftoverDeviceMigrate() async throws {
        let (coordinator, store) = makeCoordinator()
        let server = try leftoverDtServer()
        store.addOrUpdate(server)

        let client = CountingCoordinatorMigrationClient(error: .refreshRejected(code: "revoked"))
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in client },
            persist: { _ in }
        )
        coordinator._migrateDeviceIfNeededForTesting = { incoming, force in
            await service.migrateIfNeeded(incoming, force: force)
        }

        let first = await coordinator.ensureConnectionReady(for: server)
        #expect(first.apiClient != nil)
        #expect(client.calls == 1)

        let second = await coordinator.ensureConnectionReady(for: server)
        #expect(second === first)
        #expect(client.calls == 1)
    }

    @Test func rotatingDeviceAccessTokenDoesNotRecomposeTransport() async throws {
        let (coordinator, store) = makeCoordinator()
        let server = try deviceAuthServer(accessToken: "at_old", expiresAt: 1_000_000)
        store.addOrUpdate(server)

        let first = await coordinator.ensureConnectionReady(for: server)
        let wsBefore = first.wsClient
        let streamGeneration = first.persistentStreamGenerationForTesting
        let configurationGeneration = first.transportConfigurationGenerationForTesting
        #expect(wsBefore != nil)
        #expect(first.apiClient != nil)

        var rotated = try #require(store.server(for: server.id))
        rotated.deviceCredential = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_rotated",
            expiresAt: 2_000_000,
            refreshChallenge: DeviceAuthChallenge(
                nonce: "n2",
                audience: DeviceAuthSession.refreshAudience,
                expiresAt: 3_000_000
            )
        )
        store.addOrUpdate(rotated)

        let after = await coordinator.ensureConnectionReady(
            for: try #require(store.server(for: server.id))
        )

        #expect(after === first, "Same-route token rotation must keep the live connection")
        #expect(after.wsClient === wsBefore, "Rotating at_ must not replace the focused WebSocket client")
        #expect(
            after.persistentStreamGenerationForTesting == streamGeneration,
            "Rotating at_ must not rebuild persistent streams"
        )
        #expect(
            after.transportConfigurationGenerationForTesting == configurationGeneration,
            "Rotating at_ must not bump transport configuration generation"
        )
        #expect(after.credentials?.deviceCredential?.accessToken == "at_rotated")
        #expect(after.credentials?.deviceCredential?.expiresAt == 2_000_000)
        #expect(after.credentials?.name == rotated.name)
    }

    @Test func sameRouteRotationDoesNotReuseDeadTransport() async throws {
        let (coordinator, store) = makeCoordinator()
        let server = try deviceAuthServer(accessToken: "at_old", expiresAt: 1_000_000)
        store.addOrUpdate(server)

        let first = await coordinator.ensureConnectionReady(for: server)
        #expect(first.apiClient != nil)
        #expect(first.wsClient != nil)
        let configurationGeneration = first.transportConfigurationGenerationForTesting
        first.setAPIClientForTesting(nil)
        #expect(!first.hasViableConfiguredTransport)

        var rotated = try #require(store.server(for: server.id))
        rotated.deviceCredential = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_rotated",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        store.addOrUpdate(rotated)

        let after = await coordinator.ensureConnectionReady(
            for: try #require(store.server(for: server.id))
        )

        #expect(after === first, "Dead same-route transport must be rebuilt on the same connection")
        #expect(after.apiClient != nil, "Unconfigured HTTP must be recomposed")
        #expect(after.wsClient != nil, "Unconfigured WebSocket must be recomposed")
        #expect(after.hasViableConfiguredTransport)
        #expect(after.credentials?.deviceCredential?.accessToken == "at_rotated")
        #expect(
            after.transportConfigurationGenerationForTesting != configurationGeneration,
            "Dead transport must not skip reconfigure"
        )
    }

    @Test func renamingPairedServerDoesNotRecomposeTransport() async throws {
        let (coordinator, store) = makeCoordinator()
        let server = try deviceAuthServer(accessToken: "at_stable", expiresAt: 2_000_000)
        store.addOrUpdate(server)

        let first = await coordinator.ensureConnectionReady(for: server)
        let wsBefore = first.wsClient
        let streamGeneration = first.persistentStreamGenerationForTesting

        var renamed = try #require(store.server(for: server.id))
        renamed.name = "Studio Renamed"
        store.addOrUpdate(renamed)

        let after = await coordinator.ensureConnectionReady(
            for: try #require(store.server(for: server.id))
        )

        #expect(after === first)
        #expect(after.wsClient === wsBefore)
        #expect(after.persistentStreamGenerationForTesting == streamGeneration)
        #expect(after.credentials?.name == "Studio Renamed")
    }

    @Test func hostOrDeviceIdChangeStillRecomposesTransport() async throws {
        let (coordinator, store) = makeCoordinator()
        let server = try deviceAuthServer(accessToken: "at_old", expiresAt: 1_000_000)
        store.addOrUpdate(server)

        let first = await coordinator.ensureConnectionReady(for: server)
        let wsBefore = first.wsClient
        let streamGeneration = first.persistentStreamGenerationForTesting
        let configurationGeneration = first.transportConfigurationGenerationForTesting

        var moved = try #require(store.server(for: server.id))
        moved.host = "studio-b.example.test"
        store.addOrUpdate(moved)

        let afterHost = await coordinator.ensureConnectionReady(
            for: try #require(store.server(for: server.id))
        )
        #expect(afterHost === first)
        #expect(afterHost.wsClient !== wsBefore)
        #expect(afterHost.persistentStreamGenerationForTesting != streamGeneration)
        #expect(afterHost.transportConfigurationGenerationForTesting != configurationGeneration)
        #expect(afterHost.credentials?.host == "studio-b.example.test")

        let wsAfterHost = afterHost.wsClient
        let streamGenerationAfterHost = afterHost.persistentStreamGenerationForTesting

        var otherDevice = try #require(store.server(for: server.id))
        otherDevice.deviceCredential = DeviceCredential(
            deviceId: "dev_other",
            accessToken: "at_other",
            expiresAt: 3_000_000,
            refreshChallenge: nil
        )
        store.addOrUpdate(otherDevice, replacingStoredDeviceCredential: true)

        let afterDevice = await coordinator.ensureConnectionReady(
            for: try #require(store.server(for: server.id))
        )
        #expect(afterDevice === first)
        #expect(afterDevice.wsClient !== wsAfterHost)
        #expect(afterDevice.persistentStreamGenerationForTesting != streamGenerationAfterHost)
        #expect(afterDevice.credentials?.deviceCredential?.deviceId == "dev_other")
    }

    @Test func migrateReplacementRebindsExistingLiveConnection() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let replacementGate = CoordinatorReplacementGate()
        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        coordinator._migrateDeviceIfNeededForTesting = { incoming, _ in
            guard replacementGate.shouldReplace else { return incoming }
            var migrated = incoming
            migrated.deviceCredential = replacement
            migrated.token = ""
            return migrated
        }

        let first = await coordinator.ensureConnectionReady(for: leftover)
        #expect(first.credentials?.token == "dt_legacy")
        #expect(first.credentials?.deviceCredential == nil)

        replacementGate.shouldReplace = true

        let rebound = await coordinator.ensureConnectionReady(for: leftover)
        #expect(rebound === first)
        #expect(rebound.credentials?.token.isEmpty == true)
        #expect(rebound.credentials?.deviceCredential?.accessToken == "at_replacement")
        #expect(rebound.credentials?.effectiveAccessToken == "at_replacement")
    }

    @Test func inFlightPreparationStillMigratesLeftoverAfterReplacement() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let migrateGate = CoordinatorPreparationGate()
        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        var migrateCalls = 0
        coordinator._migrateDeviceIfNeededForTesting = { incoming, _ in
            migrateCalls += 1
            if migrateCalls == 1 {
                await migrateGate.suspendPreparation()
                return incoming
            }
            var migrated = incoming
            migrated.deviceCredential = replacement
            migrated.token = ""
            return migrated
        }

        let firstTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.waitUntilStarted()

        let secondTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.release()

        let first = await firstTask.value
        let second = await secondTask.value

        #expect(migrateCalls >= 2)
        #expect(second.credentials?.deviceCredential?.accessToken == "at_replacement")
        #expect(second.credentials?.effectiveAccessToken == "at_replacement")
        #expect(first.credentials?.effectiveAccessToken == "at_replacement" || first.credentials?.token == "dt_legacy")
    }

    @Test func leftoverMigrateFailureDoesNotRecurseForever() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let migrateGate = CoordinatorPreparationGate()
        var migrateCalls = 0
        coordinator._migrateDeviceIfNeededForTesting = { incoming, _ in
            migrateCalls += 1
            if migrateCalls == 1 {
                await migrateGate.suspendPreparation()
            }
            return incoming
        }

        let firstTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.waitUntilStarted()
        let secondTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.release()

        let first = await firstTask.value
        let second = await secondTask.value

        #expect(migrateCalls == 2)
        #expect(first.credentials?.token == "dt_legacy")
        #expect(second.credentials?.token == "dt_legacy")
        #expect(second.apiClient != nil)
    }

    @Test func leftoverMigrateFailureDoesNotPostAgainForInFlightWaiter() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let migrateGate = CoordinatorPreparationGate()
        let client = CountingCoordinatorMigrationClient(error: .refreshRejected(code: "revoked"))
        let service = DeviceAuthMigrationService(
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            clientFactory: { _ in client },
            persist: { _ in }
        )
        coordinator._migrateDeviceIfNeededForTesting = { incoming, force in
            if client.calls == 0 {
                await migrateGate.suspendPreparation()
            }
            return await service.migrateIfNeeded(incoming, force: force)
        }

        let firstTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.waitUntilStarted()
        let secondTask = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: leftover)
        }
        await migrateGate.release()

        let first = await firstTask.value
        let second = await secondTask.value

        #expect(client.calls == 1)
        #expect(first.credentials?.token == "dt_legacy")
        #expect(second.credentials?.token == "dt_legacy")
        #expect(second.apiClient != nil)
    }

    @Test func addServerReadyReplacesStoredAccessTokenOnUserInitiatedPair() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        var migrated = leftover
        migrated.deviceCredential = replacement
        migrated.token = ""
        try store.persistServer(migrated)

        let freshPair = try #require(PairedServer(from: leftover.credentials.withAuthToken("dt_fresh_pair")))
        let added = await coordinator.addServerReady(freshPair, switchTo: false)

        #expect(added)
        let current = try #require(store.server(for: leftover.id))
        #expect(current.deviceCredential == nil)
        #expect(current.token == "dt_fresh_pair")
        #expect(current.credentials.effectiveAccessToken == "dt_fresh_pair")
    }

    @Test func addServerReadyKeepsReplacementWhenLeftoverWriterHasNoToken() async throws {
        let (coordinator, store) = makeCoordinator()
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        var migrated = leftover
        migrated.deviceCredential = replacement
        migrated.token = ""
        try store.persistServer(migrated)

        var emptyWriter = leftover
        emptyWriter.token = ""
        emptyWriter.deviceCredential = nil
        let added = await coordinator.addServerReady(emptyWriter, switchTo: false)

        #expect(added)
        let current = try #require(store.server(for: leftover.id))
        #expect(current.deviceCredential?.accessToken == "at_replacement")
        #expect(current.token.isEmpty)
    }

    @Test func addServerReadyFailedRepairRestoresPriorAccessToken() async throws {
        let (coordinator, store) = makeCoordinator()
        coordinator._serverInfoBootstrapForTesting = { _, _ in
            throw APIError.server(status: 401, message: "Unauthorized")
        }
        let leftover = try leftoverDtServer()
        store.addOrUpdate(leftover)

        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        var migrated = leftover
        migrated.deviceCredential = replacement
        migrated.token = ""
        try store.persistServer(migrated)

        let freshPair = try #require(PairedServer(from: leftover.credentials.withAuthToken("dt_fresh_pair")))
        let added = await coordinator.addServerReady(freshPair, switchTo: false)

        #expect(!added)
        let current = try #require(store.server(for: leftover.id))
        #expect(current.deviceCredential?.accessToken == "at_replacement")
        #expect(current.token.isEmpty)
        #expect(current.credentials.effectiveAccessToken == "at_replacement")
    }

    @Test func coordinatorRejectsPlaintextEndpointInHTTPSOnlyMode() async throws {
        let (coordinator, _) = makeCoordinator()
        var server = makeServer(
            id: "sha256:https-only-plaintext",
            name: "Plaintext",
            host: "plaintext.test",
            scheme: .http
        )
        coordinator.serverStore.addOrUpdate(server)
        let shell = coordinator.activatePairedServerShell(server)

        let prepared = await coordinator.ensureConnectionReady(for: server)

        #expect(prepared !== shell)
        #expect(shell.credentials == nil)
        #expect(shell.apiClient == nil)
    }

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

    @Test func findOrFetchSessionUsesCachedRowWithoutHTTP() async {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:fetch-a", name: "A")
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.switchToServer(serverA)
        coordinator.activeConnection.sessionStore.upsert(makeTestSession(id: "cached", name: "Cached"))

        var fetchedIds: [String] = []
        coordinator._getSessionRecordForTesting = { _, sessionId in
            fetchedIds.append(sessionId)
            return makeTestSession(id: sessionId, name: "Fetched")
        }

        let result = await coordinator.findOrFetchSession(id: "cached")
        #expect(result?.connection.sessionStore.session(id: "cached")?.name == "Cached")
        #expect(fetchedIds.isEmpty)
    }

    @Test func findOrFetchSessionLoadsMissingRowFromHintedServer() async {
        let (coordinator, _) = makeCoordinator()
        let serverA = makeServer(id: "sha256:fetch-miss", name: "A")
        coordinator.serverStore.addOrUpdate(serverA)
        coordinator.switchToServer(serverA)

        coordinator._getSessionRecordForTesting = { _, sessionId in
            makeTestSession(id: sessionId, workspaceId: "w1", name: "Fetched", status: .busy)
        }

        let result = await coordinator.findOrFetchSession(id: "missing-child")
        #expect(result?.serverId == "sha256:fetch-miss")
        #expect(result?.connection.sessionStore.session(id: "missing-child")?.name == "Fetched")
        #expect(result?.connection.sessionStore.session(id: "missing-child")?.status == .busy)
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

    @Test func refreshServerDoesNotMarkSyncFailedWithoutAPIClient() async {
        let (coordinator, _) = makeCoordinator()
        coordinator._serverInfoBootstrapForTesting = { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let server = makeServer(id: "sha256:refresh-no-api", name: "Unavailable")
        coordinator.serverStore.addOrUpdate(server)

        let connection = coordinator.ensureConnection(for: server)
        connection.setAPIClientForTesting(nil)

        await coordinator.refreshServer(server.id, force: true)

        #expect(connection.apiClient == nil)
        #expect(!connection.workspaceStore.lastSyncFailed)
        #expect(!connection.sessionStore.lastSyncFailed)
    }

    @Test func retryServerConnectionDoesNotMarkSyncFailedWithoutAPIClient() async {
        let (coordinator, _) = makeCoordinator()
        coordinator._serverInfoBootstrapForTesting = { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let server = makeServer(id: "sha256:retry-no-api", name: "Unavailable")
        coordinator.serverStore.addOrUpdate(server)

        let connection = coordinator.ensureConnection(for: server)
        connection.setAPIClientForTesting(nil)

        await coordinator.retryServerConnection(server.id)

        #expect(connection.apiClient == nil)
        #expect(!connection.workspaceStore.lastSyncFailed)
        #expect(!connection.sessionStore.lastSyncFailed)
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
        coordinator._initialLANEndpointForTesting = { _ in nil }
        coordinator._serverInfoBootstrapForTesting = { _, _ in successfulServerInfo() }
        return (coordinator, store)
    }

    private func successfulServerInfo() -> ServerInfo {
        ServerInfo(
            name: "Test",
            version: "1.0.0",
            uptime: 1,
            os: "darwin",
            arch: "arm64",
            hostname: "test.local",
            nodeVersion: "22",
            piVersion: "1",
            configVersion: 1,
            identity: nil,
            uploadProtocol: nil,
            images: nil,
            capabilities: .init(
                sessionStream: .init(version: 1),
                dictationStream: nil,
                appEventStream: nil,
                extensionNativeUI: nil,
                controlSessions: nil
            ),
            stats: .init(
                workspaceCount: 0,
                activeSessionCount: 0,
                totalSessionCount: 0,
                skillCount: 0,
                modelCount: 0
            )
        )
    }

    private func installEmptyCatalogHandler() {
        TestURLProtocol.handler = { request in
            let body = switch request.url?.path {
            case "/workspaces": #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#
            case "/skills": #"{"skills":[]}"#
            case "/sessions/recent": #"{"sessions":[]}"#
            default: #"{}"#
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://test.local")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
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

    private func deviceAuthServer(
        accessToken: String,
        expiresAt: Int64,
        name: String = "Studio",
        host: String = "studio.example.test",
        deviceId: String = "dev_1"
    ) throws -> PairedServer {
        let credentials = ServerCredentials(
            host: host,
            port: 7749,
            token: "",
            name: name,
            scheme: .https,
            serverFingerprint: "sha256:device-auth-identity",
            deviceCredential: DeviceCredential(
                deviceId: deviceId,
                accessToken: accessToken,
                expiresAt: expiresAt,
                refreshChallenge: nil
            )
        )
        return try #require(PairedServer(from: credentials))
    }

    private func leftoverDtServer() throws -> PairedServer {
        let credentials = ServerCredentials(
            host: "pairing.example.test",
            port: 7749,
            token: "dt_legacy",
            name: "Legacy",
            scheme: .https,
            serverFingerprint: "sha256:leftover-dt"
        )
        return try #require(PairedServer(from: credentials))
    }

    private func makeServer(
        id: String,
        name: String,
        host: String = "localhost",
        scheme: ServerScheme = .https,
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

@MainActor
private final class CoordinatorReplacementGate {
    var shouldReplace = false
}

@MainActor
private final class CountingCoordinatorMigrationClient: DeviceAuthMigrationTransport {
    var calls = 0
    let error: DeviceAuthError

    init(error: DeviceAuthError) {
        self.error = error
    }

    func migrateDevice(
        deviceName: String?,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceResponse {
        calls += 1
        throw error
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
