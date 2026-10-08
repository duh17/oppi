import Foundation
import os
import Testing
@testable import Oppi

@Suite("LAN-first connection policy", .serialized)
@MainActor
struct LANFirstConnectionPolicyTests {
    @Test func brokenLANExpiresBeforePairedBootstrap() async throws {
        let connection = makeConnection()
        connection.setDiscoveredLANEndpoint(endpoint)
        let expired = OSAllocatedUnfairLock(initialState: false)
        connection.lanBootstrapDeadline = {
            .init(wait: { expired.withLock { $0 = true } })
        }
        var hosts: [String] = []
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, deadline in
            let host = await client.baseURL.host ?? ""
            hosts.append(host)
            if host == self.endpoint.host {
                try await deadline.waitForExpiry()
                throw URLError(.timedOut)
            }
            #expect(expired.withLock { $0 })
            return self.info
        })
        #expect(configured)
        #expect(hosts == [endpoint.host, credentials.host])
        #expect(connection.transportPath == .paired)
        cleanup(connection)
    }

    @Test(arguments: ["cell", "unknown", "other"])
    func staleLANIsNotAttemptedOffLocalNetwork(path: String) async {
        let connection = makeConnection()
        connection.networkPathType = { path }
        connection.setDiscoveredLANEndpoint(endpoint)
        var hosts: [String] = []
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, _ in
            hosts.append(await client.baseURL.host ?? "")
            return self.info
        })
        #expect(configured)
        #expect(hosts == [credentials.host])
        cleanup(connection)
    }

    @Test func healthyLANStreamSurvivesOneHTTPFailureButNotPingTimeout() async throws {
        let connection = makeConnection()
        connection.setDiscoveredLANEndpoint(endpoint)
        var availabilityObserver: APIClientAvailabilityObserver?
        var hosts: [String] = []
        let configured = await connection.configureForUse(credentials: credentials, apiClientFactory: { environment, observer in
            availabilityObserver = observer
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LANPolicyURLProtocol.self]
            return APIClient(environment: environment, configuration: configuration, availabilityObserver: observer)
        }, serverInfoBootstrap: { client, _ in
            hosts.append(await client.baseURL.host ?? "")
            return self.info
        })
        #expect(configured)
        let api = try #require(connection.apiClient)
        let socket = try #require(connection.wsClient)
        socket._setStatusForTesting(.connected)
        let failure = try #require(APIClientAvailabilityFailure(error: URLError(.timedOut)))
        await availabilityObserver?(failure)
        #expect(connection.apiClient === api)
        #expect(connection.wsClient === socket)
        #expect(connection.transportPath == .lan)
        #expect(hosts == [endpoint.host])

        // The same external fixture must answer the new auth-free readiness
        // boundary before the existing authenticated route handoff is allowed.
        connection.automaticRouteReachabilityProbe = { selection, credentials, route in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LANPolicyURLProtocol.self]
            return await ServerConnection.probeAutomaticRoute(
                selection, credentials: credentials, route: route, configuration: configuration
            )
        }
        await connection.handlePersistentStreamHealthFailure(.pingTimeout)
        #expect(connection.transportPath == .paired)
        #expect(connection.apiClient !== api)
        #expect(hosts == [endpoint.host, credentials.host])
        // Discovery churn alone must not retry a demoted LAN route.
        await connection.setDiscoveredLANEndpoint(endpoint)?.value
        #expect(hosts == [endpoint.host, credentials.host])
        cleanup(connection)
    }

    enum ActiveWork: CaseIterable, Sendable { case starting, busy, stopping, pendingTurnSend, dictation }

    /// Paired connection with one piece of active work and a Bonjour LAN
    /// endpoint whose promotion is therefore deferred.
    private func deferredPromotion(
        work: ActiveWork,
        hosts: LANHostLog
    ) async throws -> (ServerConnection, WebSocketClient, DictationStreamClient?) {
        let connection = makeConnection()
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, _ in
            hosts.values.append(await client.baseURL.host ?? "")
            return self.info
        })
        #expect(configured)
        let socket = try #require(connection.wsClient)
        var dictation: DictationStreamClient?
        switch work {
        case .starting, .busy, .stopping:
            var session = makeTestSession(id: "turn", workspaceId: "w1")
            session.status = work == .starting ? .starting : work == .busy ? .busy : .stopping
            connection.sessionStore.upsert(session)
        case .pendingTurnSend:
            connection.commands.registerTurnSend(
                PendingTurnSend(command: "prompt", requestId: "req", clientTurnId: "turn", onAckStage: nil)
            )
        case .dictation:
            dictation = try #require(connection.makeDictationStreamClient())
            dictation?._setStatusForTesting(.connected)
        }
        #expect(connection.setDiscoveredLANEndpoint(endpoint) == nil)
        return (connection, socket, dictation)
    }

    @Test(arguments: ActiveWork.allCases)
    func discoveryNeverTearsDownARouteDuringActiveWork(work: ActiveWork) async throws {
        let hosts = LANHostLog()
        // The dictation provider owns its client in production; keep it alive here.
        let (connection, socket, dictation) = try await deferredPromotion(work: work, hosts: hosts)
        defer { cleanup(connection); withExtendedLifetime(dictation) {} }
        await connection.promoteLANAtIdleBoundary()
        await connection.retryLANAtForegroundBoundary()
        #expect(connection.wsClient === socket)
        #expect(connection.transportPath == .paired)
        #expect(hosts.values == [credentials.host])
    }

    /// Promotion triggers are Bonjour arrival and foreground only. Work that
    /// ends never switches the route in place; the next foreground does.
    @Test(arguments: ActiveWork.allCases)
    func deferredPromotionWaitsForForegroundAfterWorkEnds(work: ActiveWork) async throws {
        let hosts = LANHostLog()
        let (connection, socket, dictation) = try await deferredPromotion(work: work, hosts: hosts)
        defer { cleanup(connection); withExtendedLifetime(dictation) {} }
        let ready = makeTestSession(id: "turn", workspaceId: "w1", status: .ready)
        switch work {
        case .starting:
            connection.applySharedStoreUpdate(for: .state(session: ready), sessionId: "turn")
        case .busy:
            connection.applySharedStoreUpdate(for: .agentSettled, sessionId: "turn")
        case .stopping:
            connection.applySharedStoreUpdate(for: .stopConfirmed(source: .user, reason: nil), sessionId: "turn")
        case .pendingTurnSend:
            connection.commands.unregisterTurnSend(requestId: "req", clientTurnId: "turn")
        case .dictation:
            dictation?._setStatusForTesting(.disconnected)
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(connection.wsClient === socket)
        #expect(connection.transportPath == .paired)
        #expect(hosts.values == [credentials.host])

        await connection.retryLANAtForegroundBoundary()
        #expect(connection.transportPath == .lan)
        #expect(hosts.values == [credentials.host, endpoint.host])
    }

    /// A tailnet route rebuild during active work is not a promotion trigger: it
    /// must stay on the paired host and leave the deferral for the foreground.
    @Test(arguments: ActiveWork.allCases)
    func tailnetRebuildDuringActiveWorkDoesNotPromoteLAN(work: ActiveWork) async throws {
        let hosts = LANHostLog()
        let (connection, socket, dictation) = try await deferredPromotion(work: work, hosts: hosts)
        defer { cleanup(connection); withExtendedLifetime(dictation) {} }
        let original = TailnetTransportRoute.snapshot
        defer { TailnetTransportRoute.publish(original.proxy, generation: original.generation) }
        TailnetTransportRoute.publish(
            TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture"),
            generation: original.generation &+ 50
        )
        #expect(connection.needsTailnetRouteRebuild)
        await connection.reevaluateNetworkEndpointAtBoundary()
        #expect(connection.wsClient !== socket)
        #expect(connection.transportPath == .paired)
        #expect(hosts.values == [credentials.host, credentials.host])

        // Work ends; the deferral survived the rebuild, so foreground promotes.
        let ready = makeTestSession(id: "turn", workspaceId: "w1", status: .ready)
        connection.sessionStore.upsert(ready)
        connection.commands.unregisterTurnSend(requestId: "req", clientTurnId: "turn")
        dictation?._setStatusForTesting(.disconnected)
        await connection.retryLANAtForegroundBoundary()
        #expect(connection.transportPath == .lan)
        #expect(hosts.values == [credentials.host, credentials.host, endpoint.host])
    }

    @Test func failedLANCandidateIsRetriedAtTheNextForegroundBoundary() async {
        let connection = makeConnection()
        defer { cleanup(connection) }
        connection.setDiscoveredLANEndpoint(endpoint)
        var hosts: [String] = []
        var lanShouldFail = true
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, _ in
            let host = await client.baseURL.host ?? ""
            hosts.append(host)
            if host == self.endpoint.host, lanShouldFail { throw URLError(.timedOut) }
            return self.info
        })
        #expect(configured)
        #expect(connection.transportPath == .paired)
        lanShouldFail = false
        await connection.retryLANAtForegroundBoundary()
        #expect(connection.transportPath == .lan)
        #expect(hosts == [endpoint.host, credentials.host, endpoint.host])
    }

    @Test func flappingSOCKSGenerationRestartsAreBounded() async {
        let connection = makeConnection()
        defer { cleanup(connection) }
        let original = TailnetTransportRoute.snapshot
        defer { TailnetTransportRoute.publish(original.proxy, generation: original.generation) }
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture")
        TailnetTransportRoute.publish(proxy, generation: 100)
        var bootstraps = 0
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { _, _ in
            bootstraps += 1
            // A node that republishes after every handshake, up to a safety stop.
            if bootstraps < 12 { TailnetTransportRoute.publish(proxy, generation: UInt64(100 + bootstraps)) }
            return self.info
        })
        #expect(configured)
        #expect(bootstraps == 3)
        #expect(connection.needsTailnetRouteRebuild)
    }

    @Test func pairedClientWaitsForCurrentGenerationProxyBeforeBuilding() async throws {
        let connection = makeConnection()
        let gate = LANPolicyGate()
        let oldProxy = TailnetTransportRoute.proxy
        let oldGeneration = TailnetTransportRoute.generation
        defer { TailnetTransportRoute.publish(oldProxy, generation: oldGeneration) }
        TailnetTransportRoute.publish(nil)
        connection.prepareTailnetProxy = {
            await gate.wait()
            TailnetTransportRoute.publish(TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture"), generation: 42)
        }
        var built = false
        let configuration = Task { await connection.configureForUse(credentials: credentials, apiClientFactory: { environment, observer in
            built = true
            #expect(TailnetTransportRoute.generation == 42)
            return APIClient(environment: environment, availabilityObserver: observer)
        }, serverInfoBootstrap: { _, _ in self.info })
        }
        await gate.waitUntilStarted()
        #expect(!built)
        gate.release()
        #expect(await configuration.value)
        #expect(connection.configuredSOCKSGeneration == 42)
        #expect(!connection.needsTailnetRouteRebuild)
        cleanup(connection)
    }

    @Test func proxyDeadlineAllowsSystemResolverBootstrap() async {
        let connection = makeConnection()
        var waitExpired = false
        connection.prepareTailnetProxy = {
            waitExpired = true
            throw TailnetSameUserPairing.Failure.proxyNotReady
        }
        let configured = await connection.configureForUse(credentials: credentials, apiClientFactory: { environment, observer in
            #expect(waitExpired)
            return APIClient(environment: environment, availabilityObserver: observer)
        }, serverInfoBootstrap: { _, _ in self.info })
        #expect(configured)
        #expect(connection.transportPath == .paired)
        cleanup(connection)
    }

    @Test func firstVerifiedBonjourResultEndsBoundedWait() async {
        let discovery = LANDiscovery()
        let gate = LANPolicyGate()
        let wait = Task { await discovery.waitForEndpoint(deadline: .init(wait: { await gate.wait() })) { endpoints in
            endpoints.first { $0.serverFingerprintPrefix == "server" }
        }
        }
        await gate.waitUntilStarted()
        discovery.publishForTesting([LANDiscoveredEndpoint(host: "unrelated", port: 443, serverFingerprintPrefix: "other", tlsCertFingerprintPrefix: nil)])
        discovery.publishForTesting([endpoint])
        #expect(await wait.value == endpoint)
        gate.release()
    }

    @Test func bonjourDeadlineReturnsWithoutAnEndpoint() async {
        let discovery = LANDiscovery()
        let endpoint = await discovery.waitForEndpoint(deadline: .init(wait: {})) { $0.first }
        #expect(endpoint == nil)
    }

    @Test func bonjourRemovalThenPathChangeRebindsTheStoppedLANStreamOnce() async throws {
        let connection = makeConnection()
        defer { cleanup(connection) }
        connection.setDiscoveredLANEndpoint(endpoint)
        var hosts: [String] = []
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, _ in
            hosts.append(await client.baseURL.host ?? "")
            return self.info
        })
        #expect(configured)
        var opens = 0
        connection._connectStreamForTesting = {
            opens += 1
            return AsyncStream { $0.finish() }
        }
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        let oldAPI = try #require(connection.apiClient)
        let oldSocket = try #require(connection.wsClient)
        oldSocket._setStatusForTesting(.connected)

        // Same MainActor turn: removal clears discovery but its demotion task
        // has not run when the path callback stops the old socket.
        let removal = try #require(connection.setDiscoveredLANEndpoint(nil))
        connection.handleNetworkPathChange()
        #expect(connection.isTransportDemoting)
        #expect(connection.apiClient === oldAPI)
        await removal.value

        #expect(hosts == [endpoint.host, credentials.host])
        #expect(connection.transportPath == .paired)
        #expect(connection.apiClient !== oldAPI)
        #expect(connection.wsClient !== oldSocket)
        #expect(connection.focusedSessionStreamURLForTesting?.host == credentials.host)
        #expect(opens == 1)
        #expect(!connection.isTransportDemoting)
    }

    @Test func removedLANDoesNotPromoteOnReappearanceUntilForegroundBoundary() async {
        let connection = makeConnection()
        defer { cleanup(connection) }
        connection.setDiscoveredLANEndpoint(endpoint)
        var hosts: [String] = []
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { client, _ in
            hosts.append(await client.baseURL.host ?? "")
            return self.info
        })
        #expect(configured)
        await connection.setDiscoveredLANEndpoint(nil)?.value
        #expect(connection.transportPath == .paired)
        await connection.setDiscoveredLANEndpoint(endpoint)?.value
        await connection.promoteLANAtIdleBoundary()
        #expect(connection.transportPath == .paired)
        #expect(hosts == [endpoint.host, credentials.host])

        await connection.retryLANAtForegroundBoundary()
        #expect(connection.transportPath == .lan)
        #expect(hosts == [endpoint.host, credentials.host, endpoint.host])
    }

    @Test func lateAppStreamUsesTheHTTPRouteUntilTheRouteBoundaryRebuildsAllClients() async throws {
        let connection = makeConnection()
        defer { cleanup(connection) }
        let original = TailnetTransportRoute.snapshot
        defer { TailnetTransportRoute.publish(original.proxy, generation: original.generation) }
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture")
        TailnetTransportRoute.publish(proxy, generation: 11)
        connection._appEventWebSocketFactoryForTesting = { _ in
            AppEventWebSocketTransport(
                identity: connection,
                resume: {}, receive: { throw CancellationError() },
                sendPing: { $0(nil) }, cancel: { _, _ in },
                state: { .running }, response: { nil }, closeCode: { .invalid }
            )
        }
        var bootstraps = 0
        let configured = await connection.configureForUse(credentials: credentials, serverInfoBootstrap: { _, _ in
            bootstraps += 1
            return self.makeInfo(appEvents: bootstraps > 1)
        })
        #expect(configured)
        let oldAPI = try #require(connection.apiClient)
        let oldSocket = try #require(connection.wsClient)
        TailnetTransportRoute.publish(proxy, generation: 12)
        connection.setSplitStreamCapabilitiesForTesting(appEventStream: true)
        connection.startAppEventStreamIfAvailable()

        #expect(oldAPI.tailnetRoute.generation == 11)
        #expect(oldSocket.tailnetRoute == oldAPI.tailnetRoute)
        #expect(connection.appEventStreamCoordinator.tailnetRoute == oldAPI.tailnetRoute)
        #expect(connection.needsTailnetRouteRebuild)

        await connection.reevaluateNetworkEndpointAtBoundary()
        let newAPI = try #require(connection.apiClient)
        #expect(newAPI.tailnetRoute.generation == 12)
        #expect(connection.wsClient?.tailnetRoute == newAPI.tailnetRoute)
        #expect(connection.appEventStreamCoordinator.tailnetRoute == newAPI.tailnetRoute)
        #expect(bootstraps == 2)
        #expect(!connection.needsTailnetRouteRebuild)
    }

    private func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.networkPathType = { "wifi" }
        connection.prepareTailnetProxy = { }
        return connection
    }

    private func cleanup(_ connection: ServerConnection) {
        connection._appEventWebSocketFactoryForTesting = nil
        connection.disconnectStream()
        connection.disconnectAppEventStream()
    }

    private var endpoint: LANDiscoveredEndpoint {
        LANDiscoveredEndpoint(host: "192.168.1.42", port: 443, serverFingerprintPrefix: "server", tlsCertFingerprintPrefix: nil)
    }
    private var credentials: ServerCredentials {
        ServerCredentials(host: "studio.tail00000.ts.net", port: 443, token: "at_fixture", name: "Studio", scheme: .https, serverFingerprint: "sha256:server")
    }
    private var info: ServerInfo { makeInfo(appEvents: false) }

    private func makeInfo(appEvents: Bool) -> ServerInfo {
        ServerInfo(
            name: "Fixture", version: "1", uptime: 0, os: "darwin", arch: "arm64",
            hostname: "fixture", nodeVersion: "22", piVersion: "1", configVersion: 1,
            identity: nil, uploadProtocol: nil, images: nil,
            capabilities: .init(sessionStream: .init(version: 1), dictationStream: nil,
                                appEventStream: appEvents ? .init(version: 1) : nil, extensionNativeUI: nil),
            stats: .init(workspaceCount: 0, activeSessionCount: 0, totalSessionCount: 0, skillCount: 0, modelCount: 0)
        )
    }
}

private final class LANPolicyURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        if request.url?.path == "/health" {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            body = #"{"ok":true,"protocol":2}"#
        } else {
            body = #"{"workspaces":[],"sessions":[]}"#
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
private final class LANHostLog {
    var values: [String] = []
}

@MainActor
private final class LANPolicyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isStarted = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isStarted = true
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
