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
        let apiFactory: ServerConnectionAPIClientFactory = { environment, _ in
            makeForegroundRecoveryFailingAPIClient(environment: environment)
        }
        let bootstrap: ServerConnectionInfoBootstrap = { _, _ in
            bootstrapAttempts += 1
            guard routeReachable else { throw URLError(.cannotConnectToHost) }
            return foregroundRecoveryServerInfo()
        }
        #expect(await conn.configureForUse(
            credentials: credentials,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap
        ))

        routeReachable = false
        #expect(!(await conn.reconfigureForExplicitRetry(
            credentials: credentials,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap
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
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap
        )))
        routeReachable = true
        conn.handleNetworkPathChange()
        for _ in 0..<100 where conn.apiClient == nil {
            await Task.yield()
        }

        #expect(conn.apiClient != nil)
        #expect(bootstrapAttempts == 5)
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

    /// Voice features follow their backend: foreground recovery reloads capabilities that are
    /// already loaded, and a failed read aloud reloads them too, so the speaker goes away with
    /// its backend and comes back with it.
    @Test func voiceCapabilitiesReloadOnForegroundAndAfterFailedReadAloud() async throws {
        let speechBackendUp = VoiceBackendSwitch()
        VoiceCapabilityURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/server/info" {
                let base = foregroundRecoveryServerInfo()
                let info = ServerInfo(
                    name: base.name, version: base.version, uptime: base.uptime, os: base.os,
                    arch: base.arch, hostname: base.hostname, nodeVersion: base.nodeVersion,
                    piVersion: base.piVersion, configVersion: base.configVersion,
                    identity: nil, uploadProtocol: nil, images: nil,
                    capabilities: .init(
                        sessionStream: .init(version: 1),
                        dictationStream: nil,
                        appEventStream: nil,
                        extensionNativeUI: nil,
                        speech: speechBackendUp.isUp ? .init(version: 1) : nil
                    ),
                    stats: base.stats
                )
                return (try JSONEncoder().encode(info), 200)
            }
            if url.path == "/speech" {
                return (Data(#"{"error":"Read aloud backend is not reachable"}"#.utf8), 503)
            }
            return (Data(#"{"error":"not found"}"#.utf8), 404)
        }
        defer { VoiceCapabilityURLProtocol.handler = nil }

        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "test.local", port: 7749, token: "sk_test", name: "Test"
        ))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceCapabilityURLProtocol.self]
        conn.setAPIClientForTesting(APIClient(
            baseURL: URL(string: "http://test.local:7749")!,
            token: "sk_test",
            configuration: config
        ))
        conn.setSplitStreamCapabilitiesForTesting(speech: true)

        // The backend stopped while the app was away.
        speechBackendUp.isUp = false
        await conn.reconnectIfNeeded()
        #expect(!conn.speechAvailable)

        speechBackendUp.isUp = true
        await conn.reconnectIfNeeded()
        #expect(conn.speechAvailable)

        // It stops again; the next read aloud fails and takes the speaker with it.
        speechBackendUp.isUp = false
        let read = try #require(conn.sessionContent.speechReader())
        await #expect(throws: (any Error).self) { _ = try await read("Hello.") }
        #expect(await waitForMainActorCondition { !conn.speechAvailable })
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
        uploadProtocol: nil,
        images: nil,
        capabilities: .init(
            sessionStream: .init(version: 1),
            dictationStream: nil,
            appEventStream: .init(version: 1),
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

private final class VoiceBackendSwitch: @unchecked Sendable {
    var isUp = true
}

/// Serves `/server/info` and `/speech` for the one test that installs a handler.
private final class VoiceCapabilityURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, Int))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (data, status) = try handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ForegroundRecoveryFailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
