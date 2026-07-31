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

@Suite("ConnectionCoordinator Route Modes", .serialized)
@MainActor
struct ConnectionCoordinatorRouteModeTests {
    @Test func passesEffectiveHTTPSOnlyModeToInitialAndExplicitRetry() async throws {
        defer { TestURLProtocol.handler = nil }
        TestURLProtocol.handler = { request in
            let body = switch request.url?.path {
            case "/workspaces": #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#
            case "/skills": #"{"skills":[]}"#
            case "/sessions/recent": #"{"sessions":[]}"#
            default: #"{}"#
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://studio.tailnet.ts.net")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }

        let (coordinator, server) = try makeCoordinatorAndServer(routeMode: .httpsOnly)
        var irohDials = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohDials += 1
            throw IrohTransportError.unavailable("HTTPS Only must not dial Iroh")
        }

        let connection = await coordinator.ensureConnectionReady(for: server)
        #expect(connection.transportPath == .paired)
        #expect(irohDials == 0)

        await coordinator.retryServerConnection(server.id)
        #expect(connection.transportPath == .paired)
        #expect(irohDials == 0)
    }

    @Test func passesEffectiveIrohOnlyModeWithoutConstructingHTTPClient() async throws {
        let (coordinator, server) = try makeCoordinatorAndServer(routeMode: .irohOnly)
        var constructedHosts: [String] = []
        var irohDials = 0
        coordinator._apiClientFactoryForTesting = { environment, observer in
            constructedHosts.append(environment.baseURL.host ?? "")
            return APIClient(environment: environment, availabilityObserver: observer)
        }
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohDials += 1
            return (nil, try #require(URL(string: "http://127.0.0.1:42103")))
        }

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(connection.transportPath == .iroh)
        #expect(irohDials == 1)
        #expect(constructedHosts == ["127.0.0.1"])
    }

    private func makeCoordinatorAndServer(
        routeMode: PairedServerRouteMode
    ) throws -> (ConnectionCoordinator, PairedServer) {
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
        KeychainService.deleteAllServers()
        let store = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: store)
        coordinator._initialLANEndpointForTesting = { _ in nil }
        coordinator._serverInfoBootstrapForTesting = { _, _ in routeModeServerInfo() }
        coordinator._apiClientFactoryForTesting = { environment, observer in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TestURLProtocol.self]
            return APIClient(
                environment: environment,
                configuration: configuration,
                availabilityObserver: observer
            )
        }

        let credentials = ServerCredentials(
            host: "studio.tailnet.ts.net",
            port: 7749,
            token: "dt_route_mode",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:ROUTEMODE",
            tlsCertFingerprint: "sha256:ROUTEMODETLS",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "route-mode-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "studio.tailnet.ts.net",
                    port: 7749,
                    scheme: .https,
                    tlsCertFingerprint: "sha256:ROUTEMODETLS"
                )
            )
        )
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = routeMode
        store.addOrUpdate(server)
        return (coordinator, server)
    }

    private func routeModeServerInfo() -> ServerInfo {
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
            runtimeUpdate: nil,
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

    @Test func coordinatorPassesEffectiveHTTPSOnlyModeToInitialAndExplicitRetry() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_https_only")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .httpsOnly
        coordinator.serverStore.addOrUpdate(server)
        var irohDials = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohDials += 1
            throw IrohTransportError.unavailable("HTTPS Only must not dial Iroh")
        }

        let connection = await coordinator.ensureConnectionReady(for: server)
        #expect(connection.transportPath == .paired)
        #expect(irohDials == 0)

        await coordinator.retryServerConnection(server.id)
        #expect(connection.transportPath == .paired)
        #expect(irohDials == 0)
    }

    @Test func coordinatorRejectsPlaintextEndpointInHTTPSOnlyMode() async throws {
        let (coordinator, _) = makeCoordinator()
        var server = makeServer(
            id: "sha256:https-only-plaintext",
            name: "Plaintext",
            host: "plaintext.test",
            scheme: .http
        )
        server.routeMode = .httpsOnly
        coordinator.serverStore.addOrUpdate(server)
        let shell = coordinator.activatePairedServerShell(server)

        let prepared = await coordinator.ensureConnectionReady(for: server)

        #expect(prepared !== shell)
        #expect(shell.credentials == nil)
        #expect(shell.apiClient == nil)
    }

    @Test func coordinatorPassesEffectiveIrohOnlyModeWithoutHTTPBootstrap() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_iroh_only")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        var irohDials = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohDials += 1
            return (nil, try #require(URL(string: "http://127.0.0.1:42103")))
        }

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(connection.transportPath == .iroh)
        #expect(irohDials == 1)
    }

    @Test func pairedShellPublishesIrohServerBeforeTransportPreparation() throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_staged_launch")
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)

        let connection = coordinator.activatePairedServerShell(server)

        #expect(coordinator.activeServerId == server.id)
        #expect(coordinator.connection(for: server.id) === connection)
        #expect(coordinator.activeConnection === connection)
        #expect(connection.sessionStore.activeServerId == server.id)
        #expect(connection.workspaceStore.activeServerId == server.id)
        #expect(connection.serverResourceStore.activeServerId == server.id)
        #expect(connection.credentials == nil)
        #expect(connection.apiClient == nil)
    }

    @Test func pairedShellSurvivesAvailabilityFailureAndRetriesAtPathBoundary() async throws {
        defer { TestURLProtocol.handler = nil }
        TestURLProtocol.handler = { request in
            let body = switch request.url?.path {
            case "/workspaces": #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#
            case "/skills": #"{"skills":[]}"#
            case "/sessions/recent": #"{"sessions":[]}"#
            default: #"{}"#
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://recovered.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }

        let (coordinator, _) = makeCoordinator()
        let credentials = makeTestIrohOnlyCredentials()
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        let shellConnection = coordinator.activatePairedServerShell(server)
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 1 {
                throw IrohTransportError.unavailable("path unavailable")
            }
            return (nil, try #require(URL(string: "http://127.0.0.1:41997")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "recovered.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        _ = await coordinator.ensureConnectionReady(for: server)

        #expect(coordinator.activeConnection === shellConnection)
        #expect(coordinator.serverStore.server(for: server.id) != nil)
        #expect(shellConnection.credentials == nil)

        coordinator._applyNetworkPathChangeForTesting()
        for _ in 0..<100 where shellConnection.credentials == nil {
            await Task.yield()
        }

        #expect(attempts == 2)
        #expect(coordinator.activeConnection === shellConnection)
        #expect(shellConnection.credentials == credentials)
        #expect(shellConnection.apiClient != nil)
    }

    @Test func terminalIrohOnlyInitialFailureDoesNotAutomaticallyRetryAtPathBoundary() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_terminal_staged_launch")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        let shellConnection = coordinator.activatePairedServerShell(server)
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            throw IrohTransportError.authentication("peer rejected")
        }

        _ = await coordinator.ensureConnectionReady(for: server)
        coordinator._applyNetworkPathChangeForTesting()
        for _ in 0..<10 { await Task.yield() }

        #expect(attempts == 1)
        #expect(shellConnection.credentials == nil)
        #expect(!shellConnection.canAutomaticallyRetryInitialTransport)
    }

    @Test func explicitRetryRebuildsConfiguredTerminalIrohOnlyTransport() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_explicit_terminal_retry")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            return (nil, try #require(URL(string: "http://127.0.0.1:41999")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "retry.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let connection = await coordinator.ensureConnectionReady(for: server)
        coordinator.activatePairedServerShell(server)
        connection.failTransportTerminallyForTesting()
        #expect(connection.apiClient == nil)

        await coordinator.retryServerConnection(server.id)

        #expect(attempts == 2)
        #expect(connection.credentials == credentials)
        #expect(connection.apiClient != nil)
        #expect(!connection.workspaceStore.lastSyncFailed)
        #expect(!connection.sessionStore.lastSyncFailed)
    }

    @Test func explicitRetryRebuildsIrohOnlyTransportWhenForegroundRecoveryIsBusy() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_busy_explicit_retry")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            return (nil, try #require(URL(string: "http://127.0.0.1:42022")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "retry.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let connection = await coordinator.ensureConnectionReady(for: server)
        let originalAPIClient = connection.apiClient
        #expect(connection.transportPath == .iroh)
        connection.foregroundRecoveryInFlight = true

        await coordinator.retryServerConnection(server.id)
        connection.foregroundRecoveryInFlight = false

        #expect(attempts == 2)
        #expect(connection.transportPath == .iroh)
        #expect(connection.apiClient != nil)
        #expect(connection.apiClient !== originalAPIClient)
    }

    @Test func explicitRetryQueuesForcedRebuildBehindNonForcedIrohOnlyPreparation() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_forced_join_retry")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        var attempts = 0
        let gate = CoordinatorIrohSetupGate()
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 1 {
                await gate.waitUntilReleased()
                throw IrohTransportError.unavailable("ordinary setup unavailable")
            }
            return (nil, try #require(URL(string: "http://127.0.0.1:42023")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "retry.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let connection = coordinator.activatePairedServerShell(server)
        let ordinaryPreparation = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: server)
        }
        while !gate.isWaiting { await Task.yield() }
        let retry = Task { @MainActor in
            await coordinator.retryServerConnection(server.id)
        }
        await Task.yield()
        gate.release()
        _ = await ordinaryPreparation.value
        await retry.value

        #expect(attempts == 2)
        #expect(connection.transportPath == .iroh)
        #expect(connection.apiClient != nil)
    }

    @Test func rapidModeChangeQueuesOneSerializedFollowUpWithoutTouchingOtherServer() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        coordinator._apiClientFactoryForTesting = { environment, observer in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TestURLProtocol.self]
            return APIClient(
                environment: environment,
                configuration: configuration,
                availabilityObserver: observer
            )
        }
        let credentials = makeIrohPreferredCredentials(token: "dt_rapid_mode")
        var changingServer = try #require(PairedServer(from: credentials, sortOrder: 0))
        changingServer.routeMode = .irohOnly
        let otherServer = makeServer(
            id: "sha256:rapid-mode-other",
            name: "Other",
            host: "other.test"
        )
        coordinator.serverStore.addOrUpdate(changingServer)
        coordinator.serverStore.addOrUpdate(otherServer)

        let otherConnection = coordinator.ensureConnection(for: otherServer)
        let otherAPIClient = otherConnection.apiClient
        let changingConnection = coordinator.activatePairedServerShell(changingServer)
        var commits: [ConnectionTransportPath] = []
        changingConnection._onCommittedCompositionForTesting = { commits.append($0) }
        let gate = CoordinatorIrohSetupGate()
        var irohDials = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohDials += 1
            await gate.waitUntilReleased()
            return (nil, try #require(URL(string: "http://127.0.0.1:42040")))
        }

        let irohOnlyRetry = Task { @MainActor in
            await coordinator.retryServerConnection(changingServer.id)
        }
        while !gate.isWaiting { await Task.yield() }

        coordinator.serverStore.setRouteMode(id: changingServer.id, to: .httpsOnly)
        let httpsOnlyRetry = Task { @MainActor in
            await coordinator.retryServerConnection(changingServer.id)
        }
        await Task.yield()
        gate.release()
        await irohOnlyRetry.value
        await httpsOnlyRetry.value

        #expect(irohDials == 1)
        #expect(commits == [.iroh, .paired])
        #expect(changingConnection.transportPath == .paired)
        #expect(await changingConnection.apiClient?.baseURL.host == "studio.tailnet.ts.net")
        #expect(otherConnection.apiClient === otherAPIClient)
    }

    @Test func ordinaryPreparationAwaitsInFlightForcedIrohOnlyRetry() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_wait_for_forced_retry")
        var server = try #require(PairedServer(from: credentials, sortOrder: 0))
        server.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(server)
        let gate = CoordinatorIrohSetupGate()
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 2 {
                await gate.waitUntilReleased()
            }
            let port = attempts == 1 ? 42031 : 42032
            return (nil, try #require(URL(string: "http://127.0.0.1:\(port)")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "retry.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let connection = await coordinator.ensureConnectionReady(for: server)
        let originalAPIClient = connection.apiClient
        let retry = Task { @MainActor in
            await coordinator.retryServerConnection(server.id)
        }
        while !gate.isWaiting { await Task.yield() }
        var ordinaryCompleted = false
        let ordinary = Task { @MainActor in
            let prepared = await coordinator.ensureConnectionReady(for: server)
            ordinaryCompleted = true
            return prepared
        }
        await Task.yield()

        #expect(!ordinaryCompleted)
        gate.release()
        await retry.value
        let prepared = await ordinary.value

        #expect(attempts == 2)
        #expect(prepared === connection)
        #expect(connection.apiClient !== originalAPIClient)
    }

    @Test func failedExplicitRetryMarksSelectedServerStores() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeTestIrohOnlyCredentials()
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        let connection = coordinator.activatePairedServerShell(server)
        coordinator._irohProxyFactoryForTesting = { _, _ in
            throw IrohTransportError.authentication("peer rejected retry")
        }

        await coordinator.retryServerConnection(server.id)

        #expect(connection.workspaceStore.lastSyncFailed)
        #expect(connection.sessionStore.lastSyncFailed)
    }

    @Test func explicitRetryRebuildsOnlySelectedIrohOnlyServer() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let firstCredentials = makeIrohPreferredCredentials(
            token: "dt_retry_first",
            serverFingerprint: "sha256:RETRYFIRST"
        )
        let secondCredentials = makeIrohPreferredCredentials(
            token: "dt_retry_second",
            serverFingerprint: "sha256:RETRYSECOND"
        )
        var first = try #require(PairedServer(from: firstCredentials, sortOrder: 0))
        var second = try #require(PairedServer(from: secondCredentials, sortOrder: 1))
        first.routeMode = .irohOnly
        second.routeMode = .irohOnly
        coordinator.serverStore.addOrUpdate(first)
        coordinator.serverStore.addOrUpdate(second)
        var attemptsByToken: [String: Int] = [:]
        coordinator._irohProxyFactoryForTesting = { _, token in
            attemptsByToken[token, default: 0] += 1
            let port = token == firstCredentials.token ? 42024 : 42025
            return (nil, try #require(URL(string: "http://127.0.0.1:\(port)")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "retry.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let firstConnection = await coordinator.ensureConnectionReady(for: first)
        let secondConnection = await coordinator.ensureConnectionReady(for: second)
        let untouchedSecondAPI = secondConnection.apiClient

        await coordinator.retryServerConnection(first.id)

        #expect(attemptsByToken[firstCredentials.token] == 2)
        #expect(attemptsByToken[secondCredentials.token] == 1)
        #expect(firstConnection.apiClient != nil)
        #expect(secondConnection.apiClient === untouchedSecondAPI)
    }

    @Test func failedInactivePreparationRemainsEligibleForBoundaryRecovery() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let selected = makeServer(id: "sha256:selected-http", name: "Selected")
        let inactiveCredentials = makeTestIrohOnlyCredentials()
        let inactive = try #require(PairedServer(from: inactiveCredentials, sortOrder: 1))
        coordinator.serverStore.addOrUpdate(selected)
        coordinator.serverStore.addOrUpdate(inactive)
        #expect(coordinator.switchToServer(selected))
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 1 {
                throw IrohTransportError.unavailable("inactive path unavailable")
            }
            return (nil, try #require(URL(string: "http://127.0.0.1:42000")))
        }
        coordinator._onConnectionPreparedForTesting = { serverId, connection in
            guard serverId == inactive.id, connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "inactive.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        await coordinator.prepareInactiveConnectionsReady(excluding: selected.id)
        let inactiveConnection = try #require(coordinator.connection(for: inactive.id))
        #expect(inactiveConnection.credentials == nil)

        await coordinator.recoverUnconfiguredServerAfterBoundary(inactive.id)

        #expect(attempts == 2)
        #expect(inactiveConnection.credentials == inactiveCredentials)
        #expect(inactiveConnection.apiClient != nil)
    }

    @Test func pathBoundaryDuringInitialFailureSchedulesFreshAttempt() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeTestIrohOnlyCredentials()
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        let shellConnection = coordinator.activatePairedServerShell(server)
        let gate = CoordinatorIrohSetupGate()
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 1 {
                await gate.waitUntilReleased()
                throw IrohTransportError.unavailable("old path unavailable")
            }
            return (nil, try #require(URL(string: "http://127.0.0.1:41998")))
        }

        let preparation = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: server)
        }
        while !gate.isWaiting { await Task.yield() }
        await coordinator.recoverUnconfiguredServerAfterBoundary(server.id)
        gate.release()
        _ = await preparation.value

        #expect(attempts == 2)
        #expect(shellConnection.credentials == credentials)
        #expect(shellConnection.apiClient != nil)
    }

    @Test func explicitRetryDuringPreparationRefreshesAfterFreshAttempt() async throws {
        defer { TestURLProtocol.handler = nil }
        installEmptyCatalogHandler()

        let (coordinator, _) = makeCoordinator()
        let credentials = makeTestIrohOnlyCredentials()
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        let shellConnection = coordinator.activatePairedServerShell(server)
        let gate = CoordinatorIrohSetupGate()
        var attempts = 0
        coordinator._irohProxyFactoryForTesting = { _, _ in
            attempts += 1
            if attempts == 1 {
                await gate.waitUntilReleased()
                throw IrohTransportError.unavailable("first path unavailable")
            }
            return (nil, try #require(URL(string: "http://127.0.0.1:42001")))
        }
        coordinator._onConnectionPreparedForTesting = { _, connection in
            guard connection.credentials != nil else { return }
            connection.setAPIClientForTesting(makeTestAPIClient(host: "explicit.test"))
            connection.setSplitStreamCapabilitiesForTesting()
        }

        let preparation = Task { @MainActor in
            await coordinator.ensureConnectionReady(for: server)
        }
        while !gate.isWaiting { await Task.yield() }
        let retry = Task { @MainActor in
            await coordinator.retryServerConnection(server.id)
        }
        await Task.yield()
        gate.release()
        _ = await preparation.value
        await retry.value

        #expect(attempts == 2)
        #expect(shellConnection.credentials == credentials)
        #expect(!shellConnection.workspaceStore.lastSyncFailed)
        #expect(!shellConnection.sessionStore.lastSyncFailed)
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

    @Test func initialIrohPreferredPreparationWaitsForVerifiedLAN() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_lan_first")
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        var lanHookCalled = false
        coordinator._initialLANEndpointForTesting = { serverId in
            lanHookCalled = true
            #expect(serverId == server.id)
            return LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        }
        var irohStarted = false
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohStarted = true
            return (nil, try #require(URL(string: "http://127.0.0.1:41996")))
        }

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(lanHookCalled)
        #expect(!irohStarted)
        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func LANDiscoveredAfterInitialPairedBootstrapWinsBeforePublication() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_late_lan")
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        var discoveryChecks = 0
        coordinator._initialLANEndpointForTesting = { _ in
            discoveryChecks += 1
            guard discoveryChecks > 1 else { return nil }
            return LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        }
        var irohStarted = false
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohStarted = true
            return (nil, try #require(URL(string: "http://127.0.0.1:41996")))
        }

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(!irohStarted)
        #expect(discoveryChecks == 3)
        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func LANRemovedDuringInitialSetupFallsBackToPairedBeforePublication() async throws {
        let (coordinator, _) = makeCoordinator()
        let credentials = makeIrohPreferredCredentials(token: "dt_removed_lan")
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        coordinator.serverStore.addOrUpdate(server)
        var discoveryChecks = 0
        coordinator._initialLANEndpointForTesting = { _ in
            discoveryChecks += 1
            guard discoveryChecks == 1 else { return nil }
            return LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        }
        var irohStarted = false
        coordinator._irohProxyFactoryForTesting = { _, _ in
            irohStarted = true
            return (nil, try #require(URL(string: "http://127.0.0.1:41996")))
        }

        let connection = await coordinator.ensureConnectionReady(for: server)

        #expect(discoveryChecks == 3)
        #expect(!irohStarted)
        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.host == "studio.tailnet.ts.net")
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

    private func makeIrohPreferredCredentials(
        token: String,
        serverFingerprint: String = "sha256:SERVERFINGERPRINTABCDEF"
    ) -> ServerCredentials {
        ServerCredentials(
            host: "studio.tailnet.ts.net",
            port: 7749,
            token: token,
            name: "Studio",
            scheme: .https,
            serverFingerprint: serverFingerprint,
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "iroh-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "studio.tailnet.ts.net",
                    port: 7749,
                    scheme: .https,
                    tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
                )
            )
        )
    }

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
            runtimeUpdate: nil,
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

@MainActor
private final class CoordinatorIrohSetupGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isWaiting = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
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
