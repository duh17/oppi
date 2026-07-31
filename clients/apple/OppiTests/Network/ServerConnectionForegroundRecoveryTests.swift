import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Foreground Recovery")
@MainActor
struct ServerConnectionForegroundRecoveryTests {

    @Test func reconnectIfNeededWithoutApiClientIsNoOp() async {
        let conn = ServerConnection()
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func reconnectIfNeededReentrancyGuard() async {
        let conn = makeForegroundRecoveryConnection()

        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight, "Flag should be reset after completion")
    }

    @Test func configuredOfflineConnectionRetriesAtForegroundAndNetworkBoundaries() async throws {
        let conn = ServerConnection()
        let credentials = ServerCredentials(
            host: "recover.example.test",
            port: 443,
            token: "sk_recover",
            name: "Recover",
            scheme: .https,
            serverFingerprint: "sha256:recover"
        )
        var routeReachable = true
        var bootstrapAttempts = 0
        let apiFactory: ServerConnectionAPIClientFactory = { environment, observer in
            makeForegroundRecoveryFailingAPIClient(environment: environment)
        }
        let bootstrap: ServerConnectionInfoBootstrap = { _, _ in
            bootstrapAttempts += 1
            guard routeReachable else { throw URLError(.cannotConnectToHost) }
            return foregroundRecoveryServerInfo()
        }
        let proxyFactory: @MainActor (
            IrohServerTransport,
            String
        ) async throws -> (IrohConnectionManager?, URL) = { _, _ in
            throw IrohTransportError.unavailable("Iroh is not authorized in this fixture")
        }

        #expect(await conn.configureForUse(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: proxyFactory
        ))

        routeReachable = false
        #expect(!(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: proxyFactory
        )))
        #expect(conn.credentials != nil)
        #expect(conn.apiClient == nil)

        routeReachable = true
        let now = Date()
        conn.sessionStore.markSyncSucceeded(at: now)
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)
        await conn.reconnectIfNeeded()
        #expect(conn.apiClient != nil)

        routeReachable = false
        #expect(!(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: .automatic,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap,
            irohProxyFactory: proxyFactory
        )))
        routeReachable = true
        conn.handleNetworkPathChange()
        for _ in 0..<100 where conn.apiClient == nil {
            await Task.yield()
        }

        #expect(conn.apiClient != nil)
        #expect(bootstrapAttempts == 5)
    }

    @Test func reconnectInvalidatesCachedIrohConnectionBeforeRefresh() async throws {
        let conn = ServerConnection()
        let credentials = makeTestIrohOnlyCredentials()
        let iroh = try #require(credentials.transports.iroh)
        let provider = ForegroundRecoveryIrohProvider()
        let manager = IrohConnectionManager(iroh: iroh, provider: provider)
        let localURL = try #require(URL(string: "http://127.0.0.1:41995"))
        let configured = await conn.configureForUse(
            credentials: credentials,
            apiClientFactory: { environment, _ in
                makeForegroundRecoveryFailingAPIClient(environment: environment)
            },
            serverInfoBootstrap: { _, _ in foregroundRecoveryServerInfo() },
            irohProxyFactory: { _, _ in (manager, localURL) }
        )
        #expect(configured)
        conn.setSplitStreamCapabilitiesForTesting(sessionStream: true, appEventStream: true)
        var appEventStarts = 0
        conn._startAppEventStreamForTesting = { _ in appEventStarts += 1 }
        conn.startAppEventStreamIfAvailable()
        #expect(appEventStarts == 1)
        conn._setActiveSessionIdForTesting("s1")
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        let sessionEvents = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }
        conn._connectStreamForTesting = {
            AsyncStream<StreamFrameEvent> { _ in }
        }

        await conn.reconnectIfNeeded()

        #expect(await provider.suspendCount() == 1)
        #expect(await provider.endpointRecycleCount() == 1)
        #expect(conn.sessionEventContinuations["s1"] != nil)
        // The callback observes start requests but does not mark the real
        // coordinator running: initial intent + composition commit + recovery check.
        #expect(appEventStarts == 3)
        _ = sessionEvents
        conn.disconnectStream()
    }

    @Test func reconnectDoesNotTouchReducerTimeline() async {
        // With per-session reducers, the connection has no reducer to touch.
        // This test verifies foreground recovery doesn't crash without one.
        let conn = makeForegroundRecoveryConnection()
        conn._setActiveSessionIdForTesting("s1")

        await conn.reconnectIfNeeded()

        // If we reach here without crash, the connection correctly avoids
        // reducer access during foreground recovery.
    }

    @Test func reconnectRefreshesWithoutActiveSession() async {
        let conn = makeForegroundRecoveryConnection()
        await conn.reconnectIfNeeded()
        #expect(!conn.foregroundRecoveryInFlight)
    }

    @Test func reconnectSkipsFullListRefreshWhenRecentSyncIsFresh() async {
        let conn = makeForegroundRecoveryConnection()

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

    @Test func reconnectPerformsFullListRefreshWhenCachedDataIsStale() async {
        let conn = makeForegroundRecoveryConnection()

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

    @Test func refreshSessionListSkipsNetworkWhenFreshAndNotForced() async {
        let conn = makeForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: false)

        #expect(conn.sessionStore.lastSyncFailed == false)
    }

    @Test func refreshSessionListSkipEmitsStructuredRefreshEvent() async {
        let conn = makeForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        var skipMetadata: [String: String] = [:]
        conn._onRefreshEventForTesting = { message, metadata, _ in
            if message == "session_list.skip" {
                skipMetadata = metadata
            }
        }

        await conn.refreshSessionList(force: false)

        #expect(skipMetadata["force"] == "0")
        #expect(skipMetadata["cachedSessionCount"] == "1")
        #expect(skipMetadata["durationMs"] != nil)
    }

    @Test func refreshSessionListForceRefreshesEvenWhenFresh() async {
        let conn = makeForegroundRecoveryConnection()

        let now = Date()
        conn.sessionStore.applyServerSnapshot([makeTestSession(workspaceId: "w1")])
        conn.sessionStore.markSyncSucceeded(at: now)

        await conn.refreshSessionList(force: true)

        #expect(conn.sessionStore.lastSyncFailed == true)
    }

    @Test func refreshWorkspaceCatalogSkipsNetworkWhenFreshAndNotForced() async {
        let conn = makeForegroundRecoveryConnection()

        let now = Date()
        conn.workspaceStore.workspaces = [makeTestWorkspace()]
        conn.workspaceStore.isLoaded = true
        conn.workspaceStore.markSyncSucceeded(at: now)

        await conn.refreshWorkspaceCatalog(force: false)

        #expect(conn.workspaceStore.lastSyncFailed == false)
    }

    @Test func refreshWorkspaceCatalogForceEmitsEndRefreshEventWithCounts() async {
        let conn = makeForegroundRecoveryConnection()

        var endMetadata: [String: String] = [:]
        var endLevel: ClientLogLevel?
        conn._onRefreshEventForTesting = { message, metadata, level in
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

    private func makeForegroundRecoveryConnection() -> ServerConnection {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "test.local", port: 7749, token: "sk_test", name: "Test"
        ))
        conn.setAPIClientForTesting(makeForegroundRecoveryFailingAPIClient())
        return conn
    }
}


private func makeForegroundRecoveryFailingAPIClient(
    environment: OppiClientEnvironment? = nil
) -> APIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ForegroundRecoveryFailingURLProtocol.self]
    config.timeoutIntervalForRequest = 0.1
    config.timeoutIntervalForResource = 0.1
    config.waitsForConnectivity = false
    return APIClient(
        environment: environment ?? OppiClientEnvironment(
            baseURL: URL(string: "http://test.local:7749")!,
            bearerToken: "sk_test"
        ),
        configuration: config
    )
}

private func foregroundRecoveryServerInfo() -> ServerInfo {
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
            appEventStream: .init(version: 1),
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

private final class ForegroundRecoveryFailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

private actor ForegroundRecoveryIrohProvider: IrohConnectionProviding {
    private var suspends = 0
    private var endpointRecycles = 0

    func openStream(alpn: String) async throws -> any IrohByteStream {
        throw IrohTransportError.unavailable("No stream expected in foreground recovery unit test")
    }

    func suspendConnections() async {
        suspends += 1
    }

    func recycleEndpoint() async throws {
        endpointRecycles += 1
    }

    func shutdown() async {
        await suspendConnections()
    }

    func suspendCount() -> Int {
        suspends
    }

    func endpointRecycleCount() -> Int {
        endpointRecycles
    }
}
