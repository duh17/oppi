import Foundation
import Testing
@testable import Oppi

// MARK: - Fakes

private actor RecordingDeviceAuthTransport: DeviceAuthTransport {
    private var refreshCalls = 0
    let nextToken: String
    let refreshError: DeviceAuthError?

    init(nextToken: String, refreshError: DeviceAuthError? = nil) {
        self.nextToken = nextToken
        self.refreshError = refreshError
    }

    func requestChallenge(deviceId: String) async throws -> DeviceAuthChallenge {
        DeviceAuthChallenge(
            nonce: "n",
            audience: DeviceAuthSession.refreshAudience,
            expiresAt: Int(Date().timeIntervalSince1970 * 1000 + 60_000)
        )
    }

    func refresh(
        deviceId: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult {
        refreshCalls += 1
        if let refreshError { throw refreshError }
        return DeviceAuthRefreshResult(
            accessToken: nextToken,
            expiresAt: Int(Date().timeIntervalSince1970 * 1000 + 3_600_000),
            refreshChallenge: nil
        )
    }

    func refreshCallCount() -> Int { refreshCalls }
}

@MainActor
private final class ScriptedFocusedWebSocketFactory {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [ScriptedFocusedWebSocket] = []

    func makeTransport(for request: URLRequest) -> FocusedWebSocketTransport {
        let socket = ScriptedFocusedWebSocket()
        requests.append(request)
        sockets.append(socket)
        return socket.transport
    }
}

@MainActor
private final class ScriptedFocusedWebSocket {
    typealias Message = URLSessionWebSocketTask.Message

    private var queuedResults: [Result<Message, Error>] = []
    private var pendingReceive: CheckedContinuation<Message, Error>?
    private var taskState: URLSessionTask.State = .suspended
    private var taskResponse: URLResponse?
    private var taskCloseCode: URLSessionWebSocketTask.CloseCode = .invalid

    lazy var transport = FocusedWebSocketTransport(
        identity: self,
        resume: { [weak self] in self?.taskState = .running },
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        send: { _, handler in handler(nil) },
        sendPing: { handler in handler(nil) },
        cancel: { [weak self] code, _ in self?.cancel(code: code) },
        state: { [weak self] in self?.taskState ?? .completed },
        response: { [weak self] in self?.taskResponse },
        closeCode: { [weak self] in self?.taskCloseCode ?? .invalid }
    )

    func yield(_ message: Message) {
        resolve(.success(message))
    }

    func fail(
        _ error: Error,
        responseStatusCode: Int? = nil,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        if let responseStatusCode {
            taskResponse = HTTPURLResponse(
                url: URL(string: "ws://127.0.0.1:7749/session/stream")!,
                statusCode: responseStatusCode,
                httpVersion: nil,
                headerFields: nil
            )
        }
        taskCloseCode = closeCode
        taskState = .completed
        resolve(.failure(error))
    }

    private func receive() async throws -> Message {
        if !queuedResults.isEmpty {
            return try queuedResults.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceive = continuation
        }
    }

    private func cancel(code: URLSessionWebSocketTask.CloseCode) {
        taskCloseCode = code
        taskState = .canceling
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Message, Error>) {
        if let pendingReceive {
            self.pendingReceive = nil
            pendingReceive.resume(with: result)
        } else {
            queuedResults.append(result)
        }
    }
}

// MARK: - Auth refresh behavior

@Suite("WebSocketClient Auth Refresh", .serialized)
@MainActor
struct WebSocketClientAuthRefreshTests {

    @Test func auth401ForcesOneRefreshThenOneReconnect() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(nextToken: "at_fresh")
        let client = makeClient(factory: factory, transport: transport)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        let socket = try #require(factory.sockets.first)
        socket.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })
        #expect(await transport.refreshCallCount() == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_fresh")

        client.disconnect()
        await consumer.value
    }

    @Test func authRefreshFailureDisconnectsTerminallyWithoutReconnect() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(
            nextToken: "at_fresh",
            refreshError: .refreshRejected(code: "revoked")
        )
        let client = makeClient(factory: factory, transport: transport)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        let socket = try #require(factory.sockets.first)
        socket.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            client.status == .disconnected
        })
        #expect(await transport.refreshCallCount() == 1)
        #expect(factory.sockets.count == 1)

        client.disconnect()
        await consumer.value
    }

    @Test func repeatedAuth401CannotRefreshOrReconnectForever() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(nextToken: "at_still_rejected")
        let client = makeClient(factory: factory, transport: transport)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        let first = try #require(factory.sockets.first)
        first.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })

        let second = try #require(factory.sockets.last)
        second.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            client.status == .disconnected
        })
        #expect(await transport.refreshCallCount() == 1)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        await consumer.value
    }

    @Test func refreshRejectionOpensWithLeftoverStaticToken() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(
            nextToken: "at_fresh",
            refreshError: .refreshRejected(code: "revoked")
        )
        let authSession = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_expired",
            expiresAt: Date().addingTimeInterval(-1),
            transport: transport
        )
        let client = WebSocketClient(
            credentials: makeTestCredentials(token: "dt_leftover"),
            authSession: authSession,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        client.setStreamURL(URL(string: "ws://127.0.0.1:7749/session/stream")!)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(await transport.refreshCallCount() == 1)
        #expect(factory.sockets.count == 1)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer dt_leftover")
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func siblingSessionTokenReuseDoesNotSpendMintBudget() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(nextToken: "at_minted")
        let authSession = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_stale",
            expiresAt: Date().addingTimeInterval(600),
            transport: transport
        )
        let client = WebSocketClient(
            credentials: makeTestCredentials(token: "at_stale"),
            authSession: authSession,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        client.setStreamURL(URL(string: "ws://127.0.0.1:7749/session/stream")!)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        _ = try await authSession.refreshAccessToken()
        #expect(await transport.refreshCallCount() == 1)

        try #require(factory.sockets.first).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })
        #expect(await transport.refreshCallCount() == 1)

        try #require(factory.sockets.last).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 3
        })
        #expect(await transport.refreshCallCount() == 2)
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func unexpiredLeftoverCredentialStillOpensAfterRefreshRejection() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(
            nextToken: "at_fresh",
            refreshError: .refreshRejected(code: "revoked")
        )
        let authSession = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_expired",
            expiresAt: Date().addingTimeInterval(-1),
            transport: transport
        )
        let futureMs = Int64((Date().timeIntervalSince1970 + 600) * 1000)
        let client = WebSocketClient(
            credentials: ServerCredentials(
                host: "localhost",
                port: 7749,
                token: "at_leftover",
                name: "Test",
                deviceCredential: DeviceCredential(
                    deviceId: "dev_1",
                    accessToken: "at_leftover",
                    expiresAt: futureMs,
                    refreshChallenge: nil
                )
            ),
            authSession: authSession,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        client.setStreamURL(URL(string: "ws://127.0.0.1:7749/session/stream")!)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_leftover")
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func expiredLeftoverDoesNotOpenAfterRefreshRejection() async throws {
        let factory = ScriptedFocusedWebSocketFactory()
        let transport = RecordingDeviceAuthTransport(
            nextToken: "at_fresh",
            refreshError: .refreshRejected(code: "revoked")
        )
        let authSession = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_expired",
            expiresAt: Date().addingTimeInterval(-1),
            transport: transport
        )
        let expiredMs = Int64((Date().timeIntervalSince1970 - 120) * 1000)
        let client = WebSocketClient(
            credentials: ServerCredentials(
                host: "localhost",
                port: 7749,
                token: "at_expired_leftover",
                name: "Test",
                deviceCredential: DeviceCredential(
                    deviceId: "dev_1",
                    accessToken: "at_expired_leftover",
                    expiresAt: expiredMs,
                    refreshChallenge: nil
                )
            ),
            authSession: authSession,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        client.setStreamURL(URL(string: "ws://127.0.0.1:7749/session/stream")!)
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            client.status == .disconnected
        })
        #expect(await transport.refreshCallCount() == 1)
        #expect(factory.sockets.isEmpty, "Known-expired leftover must not open a socket")

        client.disconnect()
        await consumer.value
    }

    private func makeClient(
        factory: ScriptedFocusedWebSocketFactory,
        transport: any DeviceAuthTransport
    ) -> WebSocketClient {
        let authSession = DeviceAuthSession(
            deviceId: "dev_1",
            key: InMemoryP256DeviceKey(),
            accessToken: "at_stale",
            expiresAt: Date().addingTimeInterval(600),
            transport: transport
        )
        let client = WebSocketClient(
            credentials: makeTestCredentials(token: "at_stale"),
            authSession: authSession,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        client.setStreamURL(URL(string: "ws://127.0.0.1:7749/session/stream")!)
        return client
    }
}

@MainActor
private final class ScriptedDictationSocket {
    typealias Message = URLSessionWebSocketTask.Message

    private var pending: CheckedContinuation<Message, Error>?
    private var queuedResults: [Result<Message, Error>] = []
    private var response: URLResponse?
    private var sendFailure: Error?
    private(set) var closeCode: URLSessionWebSocketTask.CloseCode?
    private(set) var sentTexts: [String] = []

    var sentDictationStartCount: Int {
        sentTexts.filter { $0.contains("\"type\":\"dictation_start\"") }.count
    }

    lazy var transport = DictationWebSocketTransport(
        identity: self,
        resume: {},
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        send: { [weak self] message in
            guard let self else { throw CancellationError() }
            try await self.recordSend(message)
        },
        cancel: { [weak self] code, _ in self?.cancel(code) },
        response: { [weak self] in self?.response }
    )

    func fail401() {
        sendFailure = URLError(.userAuthenticationRequired)
        response = HTTPURLResponse(
            url: URL(string: "wss://server.example.test/dictation/stream")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )
        resolve(.failure(URLError(.userAuthenticationRequired)))
    }

    func failSend(_ error: Error) {
        sendFailure = error
    }

    private func receive() async throws -> Message {
        if !queuedResults.isEmpty {
            return try queuedResults.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func cancel(_ code: URLSessionWebSocketTask.CloseCode) {
        closeCode = code
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Message, Error>) {
        if let pending {
            self.pending = nil
            pending.resume(with: result)
        } else {
            queuedResults.append(result)
        }
    }

    private func recordSend(_ message: URLSessionWebSocketTask.Message) throws {
        if let sendFailure {
            throw sendFailure
        }
        switch message {
        case .string(let text):
            sentTexts.append(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                sentTexts.append(text)
            }
        @unknown default:
            break
        }
    }
}

@MainActor
private final class ScriptedDictationFactory {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [ScriptedDictationSocket] = []

    func make(_ request: URLRequest) -> DictationWebSocketTransport {
        let socket = ScriptedDictationSocket()
        requests.append(request)
        sockets.append(socket)
        return socket.transport
    }
}

private final class LockedCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func get() -> Int { lock.withLock { value } }
}

/// Holds `currentTokenProvider` until the 401-refresh socket is installed,
/// then releases so `applyResolvedToken` can resolve a stale snapshot late.
private actor LateTokenGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !entered {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@Suite("Dictation device auth", .serialized)
@MainActor
struct DictationDeviceAuthTests {
    @Test func resolvesCurrentTokenBeforeOpenAndUsesForcedRefreshAfter401() async throws {
        let factory = ScriptedDictationFactory()
        let currentCalls = LockedCallCount()
        let refreshCalls = LockedCallCount()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                currentCalls.increment()
                return "at_current"
            },
            refreshTokenProvider: { @Sendable in
                refreshCalls.increment()
                return "at_refreshed"
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")
        #expect(currentCalls.get() == 1)
        #expect(refreshCalls.get() == 0)

        let first = try #require(factory.sockets.first)
        first.fail401()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_refreshed")
        #expect(currentCalls.get() == 2)
        #expect(refreshCalls.get() == 1)

        client.disconnect()
        await consumer.value
    }

    @Test func leftoverStaticTokenOpensWithoutADeviceSession() async throws {
        let factory = ScriptedDictationFactory()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(factory.sockets.count == 1)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer dt_leftover")
        #expect(client.status == .connecting)

        try await client.sendDictation(.dictationStart)
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func emptyCurrentTokenKeepsLeftoverAndStillOpens() async throws {
        let factory = ScriptedDictationFactory()
        let currentCalls = LockedCallCount()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                currentCalls.increment()
                return ""
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer dt_leftover")

        try await client.sendDictation(.dictationStart)
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func refreshRejectionKeepsLeftoverDictationSnapshot() async throws {
        let factory = ScriptedDictationFactory()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                throw DeviceAuthError.refreshRejected(code: "revoked")
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        try await client.sendDictation(.dictationStart)
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func challengeUnavailableKeepsLeftoverDictationSnapshot() async throws {
        let factory = ScriptedDictationFactory()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                throw DeviceAuthError.challengeUnavailable
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        try await client.sendDictation(.dictationStart)
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func postMigrateSnapshotOpensWithReplacementTokenWithoutWaiting() async throws {
        let factory = ScriptedDictationFactory()
        let currentStarted = LockedCallCount()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "at_replacement",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                currentStarted.increment()
                try await Task.sleep(for: .milliseconds(200))
                return "at_replacement"
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        // After dt_ -> at_ migrate the constructor already holds the replacement
        // snapshot. dictation_start is queued until currentAccessToken() resolves
        // so the first writable socket still receives start.
        try await client.sendDictation(.dictationStart)

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1 && factory.sockets.first?.sentDictationStartCount == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_replacement")
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func lateResolvedStaleTokenDoesNotRegressAfter401Refresh() async throws {
        let factory = ScriptedDictationFactory()
        let refreshCalls = LockedCallCount()
        let gate = LateTokenGate()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "at_stale",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                await gate.wait()
                return "at_stale"
            },
            refreshTokenProvider: { @Sendable in
                refreshCalls.increment()
                return "at_refreshed"
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        // Resolve-first: first socket waits for currentAccessToken. After 401
        // refresh, stay on the recovered token; do not open a third socket.
        await gate.waitUntilEntered()
        await gate.release()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_stale")

        let first = try #require(factory.sockets.first)
        first.fail401()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_refreshed")
        #expect(refreshCalls.get() == 1)
        #expect(factory.sockets.count == 2)
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func leftoverSnapshotRotateReplaysDictationStartOnSurvivingSocket() async throws {
        let factory = ScriptedDictationFactory()
        let gate = LateTokenGate()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "at_leftover",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                await gate.wait()
                return "at_current"
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        // given start is sent while leftover != currentAccessToken is still resolving
        await gate.waitUntilEntered()
        try await client.sendDictation(.dictationStart)

        // when the live device token is used for the first socket (no leftover-open)
        await gate.release()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
                && factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current"
                && factory.sockets.last?.sentDictationStartCount == 1
        })

        let surviving = try #require(factory.sockets.last)
        #expect(factory.sockets.count == 1, "Leftover snapshot must not open a first socket")
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")
        #expect(
            surviving.sentDictationStartCount == 1,
            "The current-token socket must receive dictation_start"
        )
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func leftoverSnapshot401RefreshReplaysDictationStartOnRecoveredSocket() async throws {
        let factory = ScriptedDictationFactory()
        let refreshCalls = LockedCallCount()
        let refreshGate = LateTokenGate()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "at_expired",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in "at_expired" },
            refreshTokenProvider: { @Sendable in
                refreshCalls.increment()
                await refreshGate.wait()
                return "at_refreshed"
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_expired")

        // when the leftover handshake 401s, send start during refresh (no writable socket yet)
        let first = try #require(factory.sockets.first)
        first.fail401()
        await refreshGate.waitUntilEntered()
        #expect(refreshCalls.get() == 1)
        #expect(factory.sockets.count == 1)

        var sendError: Error?
        do {
            try await client.sendDictation(.dictationStart)
        } catch {
            sendError = error
        }

        await refreshGate.release()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            factory.sockets.count == 2
        })

        let recovered = try #require(factory.sockets.last)
        #expect(sendError == nil, "First handshake 401 must not fail enable after the client recovered")
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_refreshed")
        #expect(
            recovered.sentDictationStartCount == 1,
            "Recovered socket must receive dictation_start after leftover 401 refresh"
        )
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func nonAuthHandshakeSendFailureFailsDictationStartImmediately() async throws {
        let factory = ScriptedDictationFactory()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(factory.sockets.count == 1)
        let socket = try #require(factory.sockets.first)
        socket.failSend(URLError(.secureConnectionFailed))

        var sendError: Error?
        do {
            try await client.sendDictation(.dictationStart)
        } catch {
            sendError = error
        }

        #expect(sendError != nil, "TLS/network handshake send failure must fail enable immediately")
        #expect(socket.sentDictationStartCount == 0)
        #expect(factory.sockets.count == 1)

        client.disconnect()
        await consumer.value
    }

    @Test func failedCurrentTokenResolveDoesNotOpenAfterDisconnect() async throws {
        let factory = ScriptedDictationFactory()
        let gate = LateTokenGate()
        guard let client = DictationStreamClient(
            baseURL: URL(string: "https://server.example.test")!,
            token: "dt_leftover",
            tlsCertFingerprint: nil,
            currentTokenProvider: { @Sendable in
                await gate.wait()
                throw DeviceAuthError.challengeUnavailable
            },
            webSocketFactory: { factory.make($0) }
        ) else {
            Issue.record("Expected a valid dictation stream URL")
            return
        }

        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        await gate.waitUntilEntered()
        #expect(factory.sockets.count == 0)
        client.disconnect()
        await gate.release()

        _ = await waitForMainActorCondition(timeout: .seconds(1)) {
            factory.sockets.count == 1
        }
        #expect(factory.sockets.count == 0, "Disconnect during a failed currentAccessToken() must not leftover-open")
        #expect(client.status == .disconnected)

        await consumer.value
    }
}
