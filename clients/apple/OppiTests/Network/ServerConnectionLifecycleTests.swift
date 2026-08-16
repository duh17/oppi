import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Lifecycle")
@MainActor
struct ServerConnectionLifecycleTests {

    @Test func configureWithValidCredentials() {
        let conn = ServerConnection()
        let result = conn.configure(credentials: ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_abc", name: "Test"
        ))
        #expect(result == true)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.credentials?.host == "192.168.1.10")
    }

    @Test func persistentHealthFailureOnHTTPOnlyConnectionFailsOfflineWithoutExpandingRoutes() async {
        let conn = ServerConnection()
        #expect(await conn.configureForUse(
            credentials: makeHTTPOnlyCredentials(),
            serverInfoBootstrap: successfulServerInfoBootstrap
        ))

        await conn.handlePersistentStreamHealthFailure(.reconnectThreshold(attempt: 7))

        #expect(conn.transportPath == .paired)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func transportGenerationPreventsTurnRetryAcrossReplacement() async {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("session-1")
        var attempts = 0
        conn._sendMessageForTesting = { _ in
            attempts += 1
            conn.sender.advanceTransportGeneration()
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("do not replay")
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
            _ = conn.configure(credentials: ServerCredentials(
                host: "replacement.ts.net",
                port: 7749,
                token: "dt_replacement",
                name: "Replacement",
                scheme: .https
            ))
        }

        await #expect(throws: CancellationError.self) {
            try await conn.sendPrompt("must stay on its original transport")
        }

        #expect(attempts == 1)
    }

    @Test func unavailableLANCandidateDoesNotOverwritePairedRoute() async {
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
        var lanBootstraps = 0
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    lanBootstraps += 1
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ))
        let transition = conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
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

    @Test func replacingLANCandidateCannotAdoptStaleBootstrapResult() async {
        let conn = ServerConnection()
        let credentials = makeHTTPOnlyCredentials()
        let gate = LANCandidateProbeGate(
            reachableHost: "192.168.1.43",
            firstProbeResult: true
        )
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                let url = await client.baseURL
                guard url.host?.hasPrefix("192.168.1.") == true else {
                    return successfulServerInfo()
                }
                let selection = EndpointSelection(baseURL: url, transportPath: .lan)
                guard await gate.probe(selection) else {
                    throw URLError(.cannotConnectToHost)
                }
                return successfulServerInfo()
            }
        ))

        let staleTransition = conn.setDiscoveredLANEndpoint(
            makeLANCandidate(host: "192.168.1.42")
        )
        await gate.waitForFirstProbe()
        let currentTransition = conn.setDiscoveredLANEndpoint(
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
        let credentials = makeHTTPOnlyCredentials()
        let counter = LANProbeCounter()
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: { client, _ in
                if await client.baseURL.host == "192.168.1.42" {
                    await counter.increment()
                }
                return successfulServerInfo()
            }
        ))
        let candidate = makeLANCandidate(host: "192.168.1.42")

        let transition = conn.setDiscoveredLANEndpoint(candidate)
        conn.setDiscoveredLANEndpoint(candidate)
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
        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        ))
        #expect(await conn.configureForUse(
            credentials: credentials,
            serverInfoBootstrap: successfulServerInfoBootstrap
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
            conn.setDiscoveredLANEndpoint(nil)
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

    @Test func disconnectSessionClearsActiveId() {
        let scenario = EventFlowServerConnectionScenario()
        let conn = scenario.connection

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        scenario.whenHandle(.connected(session: makeTestSession(status: .busy)))
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @Test func flushAndSuspendDelivers() {
        let scenario = EventFlowServerConnectionScenario()

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

    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:studio-fp")
        #expect(conn.serverResourceStore.activeServerId == "sha256:studio-fp")
        #expect(conn.apiClient != nil)
    }

    @Test func switchServerSkipsIfAlreadyTargeting() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:same-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server)
        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:same-fp")
    }

    @Test func switchServerChangesTarget() {
        let conn = ServerConnection()
        let creds1 = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:fp-a"
        )
        let creds2 = ServerCredentials(
            host: "mini.ts.net", port: 7749, token: "sk_b",
            name: "mini", serverFingerprint: "sha256:fp-b"
        )
        guard let server1 = PairedServer(from: creds1),
              let server2 = PairedServer(from: creds2)
        else {
            Issue.record("Expected PairedServer values to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server1)
        #expect(conn.currentServerId == "sha256:fp-a")

        _ = conn.switchServer(to: server2)
        #expect(conn.currentServerId == "sha256:fp-b")
    }

    @Test func ordinarySessionListWaitersJoinOnceAndNeverRetry() async throws {
        let startCount = JoinPassStartCounter()
        let conn = makeSessionListJoinConnection(
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
        let conn = makeSessionListJoinConnection(
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
        let conn = makeSessionListJoinConnection(
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
    ) -> ServerConnection {
        let conn = ServerConnection()
        precondition(conn.configure(credentials: ServerCredentials(
            host: "join.example.test",
            port: 443,
            token: "sk_join",
            name: "Join",
            scheme: .https,
            serverFingerprint: "sha256:join"
        )))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
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
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://join.example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }

        return conn
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
