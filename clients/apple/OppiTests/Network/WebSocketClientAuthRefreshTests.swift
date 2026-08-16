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
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var response: URLResponse?

    lazy var transport = DictationWebSocketTransport(
        identity: self,
        resume: {},
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { self.pending = $0 }
        },
        send: { _ in },
        cancel: { [weak self] _, _ in self?.pending?.resume(throwing: CancellationError()) },
        response: { [weak self] in self?.response }
    )

    func fail401() {
        response = HTTPURLResponse(
            url: URL(string: "wss://server.example.test/dictation/stream")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )
        pending?.resume(throwing: URLError(.userAuthenticationRequired))
        pending = nil
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
        #expect(currentCalls.get() == 1)
        #expect(refreshCalls.get() == 1)

        client.disconnect()
        await consumer.value
    }
}
