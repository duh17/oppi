import Testing
import Foundation
import Network
@testable import Oppi

/// Tests for focused session stream reconnect + queue recovery behavior.
@Suite("ServerConnection Reconnect")
@MainActor
struct ServerConnectionReconnectTests {

    /// Real URLSession upgrades and the installed ServerConnection health callback:
    /// lose an established socket, reject three upgrades, then accept the next one.
    @Test func threeTransient503sThenAcceptReconnectsWithoutWatchdog() async throws {
        let fixture = try await ReconnectWebSocketFixture.start()
        defer { fixture.stop() }
        let conn = try await makeLoopbackConnection(fixture)
        defer { conn.disconnectStream() }
        conn.connectStream()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) { conn.wsClient?.status == .connected })
        let retryOwner = try #require(conn.wsClient)
        let started = ContinuousClock.now
        fixture.rejectThenDisconnect([503, 503, 503])

        let recovered = await waitForMainActorCondition(timeout: .seconds(8)) {
            fixture.upgradeCount >= 5 && conn.wsClient?.status == .connected
        }
        #expect(recovered, "Must reopen the session WebSocket without HTTP watchdog recovery")
        #expect(fixture.rejectedStatuses == [503, 503, 503])
        #expect(conn.wsClient === retryOwner)
        #expect(!conn.isTransportDemoting)
        #expect(conn.isFocusedStreamBindReady())
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    private func makeLoopbackConnection(_ fixture: ReconnectWebSocketFixture) async throws -> ServerConnection {
        let conn = ServerConnection()
        conn.networkPathType = { "cellular" }
        let credentials = ServerCredentials(host: "127.0.0.1", port: Int(fixture.port), token: "test", name: "Loopback", scheme: .https)
        #expect(await conn.configureForUse(credentials: credentials, serverInfoBootstrap: { _, _ in
            try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"Test","version":"1","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{"sessionStream":{"version":1}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}"#.utf8))
        }))
        conn.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        // Only the external fixture is plaintext loopback; route selection,
        // receive/retry/backoff and the owner's health callback are production.
        try #require(conn.wsClient).setStreamURL(URL(string: "ws://127.0.0.1:\(fixture.port)/workspaces/w1/sessions/s1/stream")!, sessionId: "s1", workspaceId: "w1")
        return conn
    }

    // MARK: - handleStreamReconnected cancels deferred queue sync

    @Test func reconnectCancelsDeferredQueueSync() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        let staleTask = makeCancellableNeverCompletingTaskForTesting()
        conn.deferredQueueSyncTask = staleTask
        #expect(conn.deferredQueueSyncTask != nil)
        conn._sendMessageForTesting = { _ in }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        ))

        let cancelled = await waitForTestCondition(timeoutMs: 500) {
            staleTask.isCancelled
        }
        #expect(cancelled, "handleStreamReconnected should cancel stale deferred queue sync before scheduling a fresh one")
    }

    // MARK: - Reconnect schedules new queue sync

    @Test func reconnectSchedulesQueueSyncAfterBoundStreamReconnect() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        let getQueueCounter = MessageCounter()

        conn._sendMessageForTesting = { message in
            guard case .getQueue(let requestId) = message else { return }
            await getQueueCounter.increment()
            conn.routeStreamMessage(StreamMessage(
                sessionId: "s1",
                seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        ))

        let sent = await waitForTestCondition(timeoutMs: 500) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent, "After a bound stream reconnect, queue sync should send get_queue")
        #expect(await conn.waitForFocusedFullSubscription(sessionId: "s1", timeout: .milliseconds(100)))
    }

    // MARK: - Transition table: streamConnected accepted while streaming

    @Test func coordinatorAcceptsRepeatedStreamConnectedForBoundStream() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        let getQueueCounter = MessageCounter()

        conn._sendMessageForTesting = { message in
            guard case .getQueue(let requestId) = message else { return }
            await getQueueCounter.increment()
            conn.routeStreamMessage(StreamMessage(
                sessionId: "s1",
                seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        ))
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        ))

        let sent = await waitForTestCondition(timeoutMs: 500) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent)

        let state = conn.sessionStreamCoordinator.state
        switch state {
        case .streaming(sessionId: "s1"),
             .queueSync(sessionId: "s1", phase: _):
            break
        default:
            Issue.record("After repeated reconnect, expected streaming or queueSync for s1, got \(state)")
        }
    }


    // MARK: - Stale queue sync doesn't race after reconnect

    @Test func staleQueueSyncCancelledBeforeBoundReconnectSync() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        let getQueueCounter = MessageCounter()

        let staleTask: Task<Void, Never> = Task { @MainActor [weak conn] in
            guard let conn else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            try? await conn.requestMessageQueue(timeout: .seconds(1))
        }
        conn.deferredQueueSyncTask = staleTask

        conn._sendMessageForTesting = { message in
            guard case .getQueue(let requestId) = message else { return }
            await getQueueCounter.increment()
            conn.routeStreamMessage(StreamMessage(
                sessionId: "s1",
                seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", serverDictationAvailable: false)
        ))

        let cancelled = await waitForTestCondition(timeoutMs: 500) {
            staleTask.isCancelled
        }
        #expect(cancelled)
        let sent = await waitForTestCondition(timeoutMs: 500) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent, "Fresh reconnect queue sync should still run after stale task cancellation")
    }
}

/// A real loopback HTTP-upgrade peer. It controls only the external server;
/// URLSession and the installed reconnect/health owners run unchanged.
private final class ReconnectWebSocketFixture: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var pendingStatuses: [Int] = []
    private var rejections: [Int] = []
    private var upgrades = 0
    private var startResolved = false

    private init(listener: NWListener) { self.listener = listener }
    var port: UInt16 { listener.port!.rawValue }
    var upgradeCount: Int { lock.withLock { upgrades } }
    var rejectedStatuses: [Int] { lock.withLock { rejections } }

    static func start() async throws -> ReconnectWebSocketFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let fixture = ReconnectWebSocketFixture(listener: listener)
        let queue = DispatchQueue(label: "oppi.tests.ws-reconnect")
        listener.newConnectionHandler = { [weak fixture] connection in
            guard let fixture else { connection.cancel(); return }
            fixture.lock.withLock { fixture.connections.append(connection) }
            connection.start(queue: queue)
            fixture.receive(connection)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if fixture.claimStart() { ready.resume() }
                case .failed(let error): if fixture.claimStart() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return fixture
    }

    private func claimStart() -> Bool {
        lock.withLock {
            if startResolved { return false }
            startResolved = true
            return true
        }
    }

    func rejectThenDisconnect(_ statuses: [Int]) {
        let active = lock.withLock {
            pendingStatuses = statuses
            return connections
        }
        active.forEach { $0.cancel() }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            var request = accumulated
            request.append(data ?? Data())
            guard error == nil, request.count < 16_384 else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { receive(connection, accumulated: request) }
                return
            }
            let status = lock.withLock {
                upgrades += 1
                if pendingStatuses.isEmpty { return 101 }
                let status = pendingStatuses.removeFirst()
                rejections.append(status)
                return status
            }
            guard status == 101 else {
                let response = "HTTP/1.1 \(status) Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let key = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let accept = WebSocketFrameCodec.acceptKey(for: key)
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            let message = Data(#"{"type":"agent_start","sessionId":"s1"}"#.utf8)
            var bytes = Data(response.utf8)
            bytes.append(contentsOf: [0x81, UInt8(message.count)])
            bytes.append(message)
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
    }
}
