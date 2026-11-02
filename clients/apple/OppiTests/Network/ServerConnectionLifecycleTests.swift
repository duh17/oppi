import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Lifecycle", .serialized)
@MainActor
struct ServerConnectionLifecycleTests {

    @Test func configureWithValidCredentials() async {
        let conn = ServerConnection()
        let result = await configureTestConnection(conn, credentials: ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_abc", name: "Test"
        ))
        #expect(result == true)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.credentials?.host == "192.168.1.10")
    }

    @Test func persistentHealthFailureWithoutAlternateRoutePreservesRetryOwner() async {
        let conn = ServerConnection()
        #expect(await conn.route.configureForUse(
            credentials: makeHTTPOnlyCredentials(),
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))

        let retryOwner = conn.wsClient
        retryOwner?._setStatusForTesting(.reconnecting(attempt: 4))
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(conn.transportPath == .paired)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient === retryOwner)
        #expect(conn.wsClient?.status == .reconnecting(attempt: 4))
        #expect(!conn.route.isTransportDemoting)
        #expect(conn.isFocusedStreamBindReady())
    }

    @Test func failedAlternateBootstrapEndsDemotingWithoutClients() async {
        let conn = ServerConnection()
        // Off the local network the discovered LAN endpoint is recorded but
        // not promoted, so it is still an eligible alternate after the path
        // returns to Wi-Fi.
        conn.route.networkPathType = { "cellular" }
        let credentials = ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        var hosts: [String] = []
        conn.route.automaticRouteReachabilityProbe = { _, _, _ in true }
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                let host = await client.baseURL.host ?? ""
                hosts.append(host)
                if host == "192.168.1.42" { throw URLError(.cannotConnectToHost) }
                return successfulServerInfo()
            }
        ))
        await conn.route.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))?.value
        conn.route.networkPathType = { "wifi" }
        #expect(hosts == [credentials.host])

        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))

        #expect(hosts == [credentials.host, "192.168.1.42"])
        #expect(conn.apiClient == nil)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func unavailableAlternativeKeepsRetryOwnerThenHealthyProbeHandsOffOnce() async throws {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        var pairedAvailable = false
        var pairedProbes = 0
        var bootstraps = 0
        conn.route.automaticRouteReachabilityProbe = { _, _, _ in
            pairedProbes += 1
            if pairedAvailable {
                // Focus can change while the auth-free probe is in flight.
                conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s2", workspaceId: "w1")
            }
            return pairedAvailable
        }
        #expect(await conn.route.configureForUse(credentials: makeHTTPOnlyCredentials(), serverInfoBootstrap: { _, _ in
            bootstraps += 1
            return successfulServerInfo()
        }))
        defer { conn.disconnectStream() }
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        let oldClient = try #require(conn.wsClient)
        oldClient._setStatusForTesting(.reconnecting(attempt: 4))
        let oldAPI = conn.apiClient
        var rebinds = 0
        conn._connectStreamForTesting = {
            rebinds += 1
            return AsyncStream { _ in }
        }
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        #expect(pairedProbes == 1)
        #expect(bootstraps == 1, "An unhealthy probe must not create an authenticated candidate")
        #expect(conn.apiClient === oldAPI)
        #expect(conn.wsClient === oldClient)
        #expect(oldClient.status == .reconnecting(attempt: 4))
        #expect(conn.isFocusedStreamBindReady())
        #expect(rebinds == 0)

        pairedAvailable = true
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 6))
        #expect(pairedProbes == 2)
        #expect(bootstraps == 2)
        #expect(conn.transportPath == .paired)
        #expect(conn.wsClient !== oldClient)
        #expect(oldClient.status == .disconnected)
        #expect(conn.focusedStreamBinder.streamURL?.host == "my-server.tail00000.ts.net")
        #expect(conn.focusedStreamBinder.streamURL?.path == "/workspaces/w1/sessions/s2/stream")
        #expect(rebinds == 1)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func terminalFailureDuringAutomaticProbeCannotHandOffTransport() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        var bootstraps = 0
        #expect(await conn.route.configureForUse(credentials: makeHTTPOnlyCredentials(), serverInfoBootstrap: { _, _ in
            bootstraps += 1
            return successfulServerInfo()
        }))
        conn.route.automaticRouteReachabilityProbe = { _, _, _ in
            conn.failTransportTerminallyForTesting()
            return true
        }
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        #expect(bootstraps == 1)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
        #expect(!conn.route.canAutomaticallyRetryInitialTransport)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func automaticProbeMakesNoAuthenticatedRequestOrCredentialWrite() async throws {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        let device = DeviceCredential(deviceId: "probe-device", accessToken: "expired", expiresAt: 0, refreshChallenge: nil)
        let credentials = makeHTTPOnlyCredentials().withDeviceCredential(device)
        var bootstraps = 0
        var credentialWrites = 0
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { _, _ in bootstraps += 1; return successfulServerInfo() },
            deviceCredentialDidChange: { _ in credentialWrites += 1 }
        ))
        let oldAPI = conn.apiClient
        let oldSocket = conn.wsClient
        AutomaticProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomaticProbeURLProtocol.self]
        conn.route.automaticRouteReachabilityProbe = { selection, credentials, route in
            await ServerRouteController.probeAutomaticRoute(selection, credentials: credentials, route: route, configuration: configuration)
        }
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        let request = try #require(AutomaticProbeURLProtocol.requests.first)
        #expect(AutomaticProbeURLProtocol.requests.count == 1)
        #expect(request.url?.path == "/health")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(bootstraps == 1, "An unhealthy Oppi response must not start authenticated bootstrap")
        #expect(credentialWrites == 0)
        #expect(conn.credentials == credentials)
        #expect(conn.apiClient === oldAPI)
        #expect(conn.wsClient === oldSocket)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func staleTailnetProbeDoesNotSpendRestartBudgetOrReplaceSocket() async throws {
        let original = TailnetTransportRoute.snapshot
        defer { TailnetTransportRoute.publish(original.proxy, generation: original.generation) }
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture")
        TailnetTransportRoute.publish(proxy, generation: 501)
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        var bootstraps = 0
        var proxyPreparations = 0
        conn.route.prepareTailnetProxy = { proxyPreparations += 1 }
        #expect(await conn.route.configureForUse(credentials: makeHTTPOnlyCredentials(), serverInfoBootstrap: { _, _ in
            bootstraps += 1
            return successfulServerInfo()
        }))
        let oldSocket = try #require(conn.wsClient)
        conn.route.automaticRouteReachabilityProbe = { _, _, captured in
            #expect(captured.generation == 501)
            TailnetTransportRoute.publish(proxy, generation: 502)
            return true
        }
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        #expect(bootstraps == 1)
        #expect(proxyPreparations == 0)
        #expect(conn.wsClient === oldSocket)
        #expect(conn.transportPath == .lan)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func supersededProbeCannotTearDownExplicitReplacement() async throws {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        var bootstraps = 0
        #expect(await conn.route.configureForUse(credentials: makeHTTPOnlyCredentials(), serverInfoBootstrap: { _, _ in
            bootstraps += 1
            return successfulServerInfo()
        }))
        defer { conn.disconnectStream() }
        conn._connectStreamForTesting = { AsyncStream { _ in } }
        var replacement: WebSocketClient?
        conn.route.automaticRouteReachabilityProbe = { _, _, _ in
            #expect(await conn.route.reconfigureForExplicitRetry(
                credentials: self.makeHTTPOnlyCredentials(),
                serverInfoBootstrap: { _, _ in bootstraps += 1; return successfulServerInfo() }
            ))
            replacement = conn.wsClient
            return true
        }
        await conn.route.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 4))
        #expect(bootstraps == 2)
        #expect(replacement != nil)
        #expect(conn.wsClient === replacement)
        #expect(!conn.route.isTransportDemoting)
    }

    @Test func unixTransportPathIsNotARouteCandidate() {
        let conn = ServerConnection()
        #expect(ServerRouteController.routeCandidateKind(for: .unix) == nil)
        #expect(ServerRouteController.routeCandidateKind(for: .lan) == .lan)
        #expect(ServerRouteController.routeCandidateKind(for: .paired) == .paired)
    }

    @Test func transportGenerationPreventsTurnRetryAcrossReplacement() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }

        // The frame went out before the replacement, so delivery is unconfirmed
        // (not "never sent"); it must still not be replayed on the new transport.
        do {
            try await conn.sendPrompt("do not replay")
            Issue.record("Expected the replacement to fence the send")
        } catch let error as TurnSendUnconfirmedError {
            #expect(error.underlying is CancellationError)
        } catch {
            Issue.record("Expected TurnSendUnconfirmedError, got \(error)")
        }

        #expect(attempts == 1)
    }

    @Test func explicitReconfigurationFencesTurnRetryDuringRetryDelay() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        conn._turnSendRetryDelayForTesting = .milliseconds(1)
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            throw WebSocketError.notConnected
        }
        conn.sender._onTurnRetryDelayForTesting = {
            // configureForUse advances the transport generation before its first
            // await, so the replacement fences the retry while its delay runs.
            Task { @MainActor in
                _ = await configureTestConnection(conn, credentials: ServerCredentials(
                    host: "replacement.ts.net",
                    port: 7749,
                    token: "dt_replacement",
                    name: "Replacement",
                    scheme: .https
                ))
            }
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("must stay on its original transport")
        }

        #expect(attempts == 1)
    }

    @Test func unavailableLANCandidateDoesNotOverwritePairedRoute() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        let credentials = ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        var lanBootstraps = 0
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    lanBootstraps += 1
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ))
        let transition = conn.route.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        await transition?.value

        #expect(lanBootstraps == 1)
        #expect(conn.transportPath == .paired)
        #expect(await conn.apiClient?.baseURL.host == "my-server.tail00000.ts.net")
    }

    @Test func freshVerifiedLANConnectsWithoutTryingPaired() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        let credentials = makeHTTPOnlyCredentials()
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        var lanBootstraps = 0
        var pairedBootstraps = 0
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    lanBootstraps += 1
                    return successfulServerInfo()
                }
                pairedBootstraps += 1
                throw URLError(.cannotFindHost)
            }
        ))
        #expect(lanBootstraps == 1)
        #expect(pairedBootstraps == 0)
        #expect(conn.transportPath == .lan)
        #expect(conn.route.canAutomaticallyRetryInitialTransport)
        #expect(await conn.apiClient?.baseURL.host == "192.168.1.42")
    }

    @Test func tlsOnLANFallsBackToPairedCandidate() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        let credentials = makeHTTPOnlyCredentials()
        conn.route.setDiscoveredLANEndpoint(makeLANCandidate(host: "192.168.1.42"))
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    throw URLError(.serverCertificateUntrusted)
                }
                return successfulServerInfo()
            }
        ))
        #expect(conn.transportPath == .paired)
        #expect(conn.route.canAutomaticallyRetryInitialTransport)
        #expect(await conn.apiClient?.baseURL.host == credentials.host)
    }

    @Test func pairedOnlyDNSMissStaysRetryableAndRecoversOnNextBootstrap() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { _, _ in throw URLError(.cannotFindHost) }
        ) == false)
        #expect(conn.apiClient == nil)
        #expect(conn.route.canAutomaticallyRetryInitialTransport)

        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))
        #expect(conn.apiClient != nil)
        #expect(conn.route.canAutomaticallyRetryInitialTransport)
    }

    @Test func tlsBootstrapFailureStillFailCloses() async {
        let conn = ServerConnection()
        #expect(await conn.route.configureForUse(
            credentials: makeHTTPOnlyCredentials(),
            serverInfoBootstrap: { _, _ in throw URLError(.serverCertificateUntrusted) }
        ) == false)
        #expect(conn.apiClient == nil)
        #expect(!conn.route.canAutomaticallyRetryInitialTransport)
    }

    @Test func replacingLANCandidateCannotAdoptStaleBootstrapResult() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        let credentials = makeHTTPOnlyCredentials()
        let gate = LANCandidateProbeGate(
            reachableHost: "192.168.1.43",
            firstProbeResult: true
        )
        #expect(await configureTestConnection(conn, credentials: credentials) == true)
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                let url = await client.baseURL
                guard url.host?.hasPrefix("192.168.1.") == true else {
                    throw URLError(.cannotConnectToHost)
                }
                let selection = EndpointSelection(baseURL: url, transportPath: .lan)
                guard await gate.probe(selection) else {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ) == false)

        let staleTransition = conn.route.setDiscoveredLANEndpoint(
            makeLANCandidate(host: "192.168.1.42")
        )
        await gate.waitForFirstProbe()
        let currentTransition = conn.route.setDiscoveredLANEndpoint(
            makeLANCandidate(host: "192.168.1.43")
        )
        await currentTransition?.value
        await gate.releaseFirstProbe()
        await staleTransition?.value

        #expect(conn.transportPath == .lan)
        #expect(await conn.apiClient?.baseURL.host == "192.168.1.43")
        #expect(await gate.probeCount == 2)
    }

    @Test func repeatedIdenticalLANCandidateStartsOneBootstrap() async {
        let conn = ServerConnection()
        conn.route.networkPathType = { "wifi" }
        let credentials = makeHTTPOnlyCredentials()
        let counter = LANProbeCounter()
        let candidate = makeLANCandidate(host: "192.168.1.42")
        conn.route.setDiscoveredLANEndpoint(candidate)
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    await counter.increment()
                    return successfulServerInfo()
                }
                throw URLError(.cannotConnectToHost)
            }
        ))
        let transition = conn.route.setDiscoveredLANEndpoint(candidate)
        conn.route.setDiscoveredLANEndpoint(candidate)
        await transition?.value

        #expect(await counter.value == 1)
        #expect(conn.transportPath == .lan)
    }

    @Test func LANToPairedTransitionFencesSleepingTurnRetry() async {
        let conn = ServerConnection()
        let credentials = ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        #expect(await conn.route.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))
        await discoverTestLANEndpoint(on: conn, LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        #expect(conn.transportPath == .lan)
        conn._setActiveSessionIdForTesting("session-1")
        conn._turnSendRetryDelayForTesting = .milliseconds(1)
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            throw WebSocketError.notConnected
        }
        conn.sender._onTurnRetryDelayForTesting = {
            conn.route.setDiscoveredLANEndpoint(nil)
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("never retry across LAN handoff")
        }

        #expect(attempts == 1)
        #expect(conn.transportPath == .paired)
    }

    @Test func stopRetryIsFencedAcrossTransportGeneration() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendStop()
        }

        #expect(attempts == 1)
    }

    @Test func disconnectSessionClearsActiveId() async {
        let scenario = await EventFlowServerConnectionScenario()
        let conn = scenario.connection

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        scenario.whenHandle(.connected(session: makeTestSession(status: .busy)))
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @Test func flushAndSuspendDelivers() async {
        let scenario = await EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenHandle(.textDelta(delta: "buffered"))
            .whenFlush()

        #expect(scenario.timelineItemCount(of: .assistantMessage) == 1)
    }

    @Test func requestStateUsesDispatchSendHook() async throws {
        let conn = ServerConnection()
        var sawGetState = false

        conn._sendMessageForTesting = { message in
            if case .getState = message {
                sawGetState = true
            }
        }

        try await conn.requestState()
        #expect(sawGetState)
    }

    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }

    @Test func ordinarySessionListWaitersJoinOnceAndNeverRetry() async throws {
        let startCount = JoinPassStartCounter()
        let conn = try await makeSessionListJoinConnection(
            failNetwork: true,
            onSessionListStart: { startCount.increment() }
        )
        defer { TestURLProtocol.handler = nil }

        let gate = RoutingGate()
        let gated = Task { @MainActor in
            defer { conn.sessionListRefreshTask = nil }
            await gate.waitUntilReleased()
            conn.sessionStore.markSyncFailed()
        }
        conn.sessionListRefreshTask = gated

        // Ordinary callers (default retryAfterJoinedFailure: false) only join.
        let waiters = (0..<4).map { _ in
            Task { @MainActor in await conn.refreshSessionList(force: true) }
        }
        await gate.waitUntilBlocked()
        await gate.release()
        for waiter in waiters { await waiter.value }

        #expect(startCount.value == 0)
        #expect(conn.sessionStore.lastSyncFailed == true)
        #expect(conn.sessionListRefreshTask == nil)
    }

    @Test func recoveryOwnerJoinsFailedPassAndPerformsExactlyOneRefresh() async throws {
        let startCount = JoinPassStartCounter()
        let conn = try await makeSessionListJoinConnection(
            failNetwork: false,
            onSessionListStart: { startCount.increment() }
        )
        defer { TestURLProtocol.handler = nil }

        let gate = RoutingGate()
        let gated = Task { @MainActor in
            defer { conn.sessionListRefreshTask = nil }
            await gate.waitUntilReleased()
            conn.sessionStore.markSyncFailed()
        }
        conn.sessionListRefreshTask = gated

        // Mirrors performAutomaticRouteRecovery's refresh flags only.
        let recoveryRefresh = Task { @MainActor in
            await conn.refreshSessionList(force: true, retryAfterJoinedFailure: true)
        }
        // Ordinary waiters must still not amplify.
        let ordinary = (0..<3).map { _ in
            Task { @MainActor in await conn.refreshSessionList(force: true) }
        }
        await gate.waitUntilBlocked()
        await gate.release()
        await recoveryRefresh.value
        for waiter in ordinary { await waiter.value }

        #expect(startCount.value == 1)
        #expect(conn.sessionStore.lastSyncFailed == false)
        #expect(conn.sessionListRefreshTask == nil)
    }

    @Test func recoveryOwnerJoinsPeerReplacementInsteadOfOverwriting() async throws {
        let startCount = JoinPassStartCounter()
        let conn = try await makeSessionListJoinConnection(
            failNetwork: false,
            onSessionListStart: { startCount.increment() }
        )
        defer { TestURLProtocol.handler = nil }

        let originalGate = RoutingGate()
        let replacementGate = RoutingGate()
        var replacementRan = false

        // A completes failed, then installs peer B on the shared property before
        // ending. Recovery is still awaiting A (local handle); its post-join
        // recheck must join B rather than install C.
        let original = Task { @MainActor in
            await originalGate.waitUntilReleased()
            conn.sessionStore.markSyncFailed()
            let replacement = Task { @MainActor in
                defer { conn.sessionListRefreshTask = nil }
                replacementRan = true
                await replacementGate.waitUntilReleased()
                conn.sessionStore.markSyncSucceeded(at: Date())
            }
            conn.sessionListRefreshTask = replacement
        }
        conn.sessionListRefreshTask = original

        let recoveryRefresh = Task { @MainActor in
            await conn.refreshSessionList(force: true, retryAfterJoinedFailure: true)
        }
        await originalGate.waitUntilBlocked()
        await originalGate.release()
        await replacementGate.waitUntilBlocked()

        #expect(replacementRan)
        #expect(startCount.value == 0)

        await replacementGate.release()
        await recoveryRefresh.value

        #expect(startCount.value == 0)
        #expect(conn.sessionStore.lastSyncFailed == false)
        #expect(conn.sessionListRefreshTask == nil)
    }

    @MainActor
    private func makeSessionListJoinConnection(
        failNetwork: Bool,
        onSessionListStart: @escaping @MainActor () -> Void
    ) async throws -> ServerConnection {
        let conn = ServerConnection()
        let configured = await configureTestConnection(conn, credentials: ServerCredentials(
            host: "join.example.test",
            port: 443,
            token: "sk_join",
            name: "Join",
            scheme: .https,
            serverFingerprint: "sha256:join"
        ))
        precondition(configured)

        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        conn.setAPIClientForTesting(APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "https://join.example.test")!,
                bearerToken: "sk_join"
            ),
            configuration: configuration
        ))
        conn.setSplitStreamCapabilitiesForTesting()
        conn.workspaceStore.workspaces = []
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: Date())

        conn._onRefreshEventForTesting = { message, _, _ in
            if message == "session_list.start" {
                onSessionListStart()
            }
        }

        TestURLProtocol.handler = { request in
            if failNetwork {
                throw URLError(.cannotConnectToHost)
            }
            let body: String
            switch request.url?.path {
            case "/sessions/recent":
                body = #"{"sessions":[]}"#
            case "/workspaces":
                body = #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#
            case "/skills":
                body = #"{"skills":[]}"#
            default:
                body = #"{}"#
            }
            let response = (try #require(HTTPURLResponse(
                url: request.url ?? URL(string: "https://join.example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )))
            return (Data(body.utf8), response)
        }

        return conn
    }

    /// The app-event stream starts inside `configureForUse`, and the catalog is cached
    /// per server only. The stream's first event refreshes the catalog while setup is
    /// still returning: it must land under the server, and nothing is loaded or cached
    /// server-less.
    @Test func catalogRefreshFromTheFirstAppEventLandsUnderItsServerOnly() async throws {
        defer { TestURLProtocol.handler = nil }
        let serverId = "sha256:SERVERFINGERPRINTABCDEF"
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "catalog-race-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }
        let cache = TimelineCache(rootURL: root)

        TestURLProtocol.handler = { request in
            switch request.url?.path {
            case "/workspaces":
                return try mockJSONResponse(
                    json: #"{"workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}]}"#,
                    for: request
                )
            case "/skills":
                return try mockJSONResponse(json: #"{"skills":[]}"#, for: request)
            default:
                return try mockJSONResponse(status: 404, json: "{}", for: request)
            }
        }
        let conn = ServerConnection()
        conn.workspaceStore._cacheForTesting = cache
        conn._startAppEventStreamForTesting = { _ in
            Task { @MainActor in await conn.refreshWorkspaceCatalog(force: true) }
        }

        #expect(await conn.route.configureForUse(
            credentials: makeHTTPOnlyCredentials(),
            apiClientFactory: { environment, observer in
                let configuration = URLSessionConfiguration.ephemeral
                TestURLProtocol.install(in: configuration)
                return APIClient(environment: environment, configuration: configuration, availabilityObserver: observer)
            },
            serverInfoBootstrap: { _, _ in successfulServerInfo(appEventStream: true) }
        ))
        #expect(await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { conn.workspaceStore.workspacesByServer[serverId]?.map(\.id) == ["w1"] }
        })
        var cached: [Workspace]?
        for _ in 0..<200 where cached == nil {
            cached = await cache.loadWorkspaces(serverId: serverId)
            if cached == nil { try await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(cached?.map(\.id) == ["w1"])
        #expect(conn.workspaceStore.workspacesByServer[""] == nil)
        #expect(!fileManager.fileExists(atPath: root.appending(path: "workspaces.json").path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: "skills.json").path))
    }

    private func makeHTTPOnlyCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
    }

    private func makeLANCandidate(host: String) -> LANDiscoveredEndpoint {
        LANDiscoveredEndpoint(
            host: host,
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )
    }

}
enum RoutingBootstrapFailure: Sendable {
    case authentication
    case decoding

    func throwError() throws -> ServerInfo {
        switch self {
        case .authentication:
            throw APIError.server(status: 401, message: "unauthorized")
        case .decoding:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "invalid server info"
            ))
        }
    }
}

@MainActor
private func successfulServerInfoBootstrap(
    _: APIClient,
    _: APIClient.BootstrapDeadline
) async throws -> ServerInfo {
    successfulServerInfo()
}

@MainActor
private func successfulServerInfo(appEventStream: Bool = false) -> ServerInfo {
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
            appEventStream: appEventStream ? .init(version: 1) : nil,
            extensionNativeUI: nil
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

private final class CandidateDeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _httpFactoryCount = 0
    private var _httpDeadlineExpirations = 0

    var httpFactoryCount: Int { lock.withLock { _httpFactoryCount } }
    var httpDeadlineExpirations: Int { lock.withLock { _httpDeadlineExpirations } }

    func recordHTTPFactory() {
        lock.withLock { _httpFactoryCount += 1 }
    }

    func expireHTTPDeadline() {
        lock.withLock { _httpDeadlineExpirations += 1 }
    }

}

private actor CandidateDeadlineGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForExpiry() async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(3_600))
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor RoutingGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor LANCandidateProbeGate {
    let reachableHost: String
    let firstProbeResult: Bool?
    private var firstProbeContinuation: CheckedContinuation<Void, Never>?
    private(set) var firstProbeIsWaiting = false
    private(set) var probeCount = 0

    init(reachableHost: String, firstProbeResult: Bool? = nil) {
        self.reachableHost = reachableHost
        self.firstProbeResult = firstProbeResult
    }

    func probe(_ selection: EndpointSelection) async -> Bool {
        probeCount += 1
        if probeCount == 1 {
            firstProbeIsWaiting = true
            await withCheckedContinuation { firstProbeContinuation = $0 }
            if let firstProbeResult { return firstProbeResult }
        }
        return selection.baseURL.host == reachableHost
    }

    func waitForFirstProbe() async {
        while !firstProbeIsWaiting {
            await Task.yield()
        }
    }

    func releaseFirstProbe() {
        firstProbeContinuation?.resume()
        firstProbeContinuation = nil
    }
}

private actor LANProbeCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class ListRefreshRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(host: String, path: String)] = []

    func append(host: String, path: String) {
        lock.lock()
        entries.append((host, path))
        lock.unlock()
    }

    func sessionListHits(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.host == host && $0.path.hasPrefix("/sessions/recent") }.count
    }
}

/// The health peer says HTTP 200 but not ready. Production must validate the
/// body, leave installed auth alone, and avoid an authenticated candidate.
private final class AutomaticProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.withLock { Self.recorded.append(request) }
            let response = (try #require(HTTPURLResponse(url: (testUnwrap(request.url)), statusCode: 200, httpVersion: nil, headerFields: nil)))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok":false,"protocol":2}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class JoinPassStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
