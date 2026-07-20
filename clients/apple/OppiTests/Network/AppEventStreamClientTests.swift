import Foundation
import Testing
@testable import Oppi

@Suite("AppEventStreamClient", .serialized)
@MainActor
struct AppEventStreamClientTests {
    @Test func decodesStringAndDataFramesWhileSkippingMalformedInput() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory)
        let stream = client.connect()
        var received: [AppEventMessage] = []
        let consumer = Task { @MainActor in
            for await event in stream {
                received.append(event)
            }
        }

        let socket = try #require(factory.sockets.first)
        socket.yield(.string("not-json"))
        socket.yield(.data(Data(Self.connectedJSON.utf8)))
        socket.yield(.string(#"{"type":"future_app_event"}"#))

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            received.count == 2
        })
        #expect(received == [
            .connected(serverTime: 42, snapshotRequired: false),
            .ignored(type: "future_app_event"),
        ])
        #expect(client.status == .connected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
        await consumer.value
    }

    @Test func recoverableFailureReconnectsAndContinuesOriginalStream() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory, reconnectDelay: { _ in 0 })
        let stream = client.connect()
        var received: [AppEventMessage] = []
        let consumer = Task { @MainActor in
            for await event in stream {
                received.append(event)
            }
        }

        let firstSocket = try #require(factory.sockets.first)
        firstSocket.fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })
        let secondSocket = try #require(factory.sockets.last)
        secondSocket.yield(.string(Self.connectedJSON))
        secondSocket.yield(.string(#"{"type":"after_reconnect"}"#))

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            received.count == 2
        })
        #expect(received.last == .ignored(type: "after_reconnect"))
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func recoverableFailuresContinuePastFormerRetryCeiling() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory, reconnectDelay: { _ in 0 })
        let stream = client.connect()
        var received: [AppEventMessage] = []
        let consumer = Task { @MainActor in
            for await event in stream {
                received.append(event)
            }
        }

        for expectedSocketCount in 2...12 {
            let socket = try #require(factory.sockets.last)
            socket.fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
            #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
                factory.sockets.count == expectedSocketCount
            })
        }

        let recoveredSocket = try #require(factory.sockets.last)
        recoveredSocket.yield(.string(Self.connectedJSON))

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            received == [.connected(serverTime: 42, snapshotRequired: false)]
        })
        #expect(client.status == .connected)

        client.disconnect()
        await consumer.value
    }

    @Test func nonRetryableHandshakeFailureFinishesWithoutOpeningAnotherSocket() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory, reconnectDelay: { _ in 0 })
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        let socket = try #require(factory.sockets.first)
        socket.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        await consumer.value
    }

    @Test func terminalCloseCodeWithoutHTTPResponseFinishesWithoutRetrying() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory, reconnectDelay: { _ in 0 })
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        let socket = try #require(factory.sockets.first)
        socket.fail(URLError(.badServerResponse), closeCode: .protocolError)

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        await consumer.value
    }

    @Test func disconnectCancelsScheduledReconnectAndFinishesConsumer() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory, reconnectDelay: { _ in 60 })
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        let socket = try #require(factory.sockets.first)
        socket.fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            if case .reconnecting(attempt: 1) = client.status { return true }
            return false
        })

        client.disconnect()
        await consumer.value
        for _ in 0..<5 { await Task.yield() }

        #expect(client.status == .disconnected)
        #expect(factory.sockets.count == 1)
    }

    @Test func staleStreamTerminationCannotDisconnectReplacementConnection() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(factory: factory)

        let firstStream = client.connect()
        let firstConsumer = Task {
            for await _ in firstStream {}
        }
        let secondStream = client.connect()
        var secondEvents: [AppEventMessage] = []
        let secondConsumer = Task { @MainActor in
            for await event in secondStream {
                secondEvents.append(event)
            }
        }

        let replacementSocket = try #require(factory.sockets.last)
        replacementSocket.yield(.string(Self.connectedJSON))

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            secondEvents == [.connected(serverTime: 42, snapshotRequired: false)]
        })
        await firstConsumer.value
        for _ in 0..<5 { await Task.yield() }

        #expect(client.status == .connected)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        await secondConsumer.value
    }

    private func makeClient(
        factory: ScriptedAppEventSocketFactory,
        reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { _ in 60 }
    ) throws -> AppEventStreamClient {
        let url = try #require(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        return AppEventStreamClient(
            url: url,
            token: "test-token",
            reconnectDelay: reconnectDelay,
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
    }

    private static let connectedJSON = #"{"type":"app_events_connected","serverTime":42,"snapshotRequired":false}"#
}

@Suite("AppEventStreamCoordinator", .serialized)
@MainActor
struct AppEventStreamCoordinatorTests {
    @Test func prolongedOutageReconnectSnapshotCompletesBeforeQueuedLiveEventsApply() async throws {
        let gate = AppEventSnapshotGate()
        let snapshotSession = makeTestSession(id: "s1", workspaceId: "w1", status: .ready)
        let coordinator = AppEventStreamCoordinator { connection in
            await gate.waitUntilReleased()
            connection.sessionStore.applyServerSnapshot([snapshotSession])
        }
        let connection = ServerConnection()
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        let factory = ScriptedAppEventSocketFactory()
        let url = try #require(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        let client = AppEventStreamClient(
            url: url,
            token: "test-token",
            reconnectDelay: { _ in 0 },
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )

        coordinator.start(connection: connection, client: client, streamURL: url)
        for expectedSocketCount in 2...12 {
            let failedSocket = try #require(factory.sockets.last)
            failedSocket.fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
            #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
                factory.sockets.count == expectedSocketCount
            })
        }

        let recoveredSocket = try #require(factory.sockets.last)
        recoveredSocket.yield(.string(#"{"type":"app_events_connected","serverTime":42,"snapshotRequired":true}"#))

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            gate.hasStarted
        })
        recoveredSocket.yield(.string(#"{"type":"session_deleted","sessionId":"s1","workspaceId":"w1","emittedAt":43}"#))
        #expect(connection.sessionStore.session(id: "s1") != nil)

        gate.release()

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            connection.sessionStore.session(id: "s1") == nil
        })
        #expect(connection.appEventStreamTransportState == .connected)

        coordinator.disconnect()
    }

    @Test func serverReconfigurationCancelsOldStreamAndIgnoresItsStaleEvents() async throws {
        let connection = ServerConnection()
        #expect(connection.configure(credentials: makeTestCredentials(
            host: "server-a.example",
            fingerprint: "sha256:server-a"
        )))
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        let oldServerId = connection.currentServerId
        let factory = ScriptedAppEventSocketFactory()
        let oldURL = try #require(URL(string: "wss://server-a.example:7749/app/events/stream"))
        let oldClient = AppEventStreamClient(
            url: oldURL,
            token: "test-token",
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )

        connection.appEventStreamCoordinator.start(
            connection: connection,
            client: oldClient,
            streamURL: oldURL
        )
        let oldSocket = try #require(factory.sockets.first)
        oldSocket.yield(.string(#"{"type":"app_events_connected","serverTime":42,"snapshotRequired":false}"#))
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            connection.appEventStreamTransportState == .connected
        })

        #expect(connection.configure(credentials: makeTestCredentials(
            host: "server-b.example",
            fingerprint: "sha256:server-b"
        )))
        oldSocket.yield(.string(#"{"type":"session_deleted","sessionId":"s1","workspaceId":"w1","emittedAt":43}"#))
        for _ in 0..<5 { await Task.yield() }

        #expect(connection.currentServerId != oldServerId)
        #expect(!connection.appEventStreamCoordinator.isRunning)
        #expect(connection.appEventStreamTransportState == .disconnected)
        #expect(connection.sessionStore.session(id: "s1") != nil)
    }
}

@MainActor
private final class AppEventSnapshotGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class ScriptedAppEventSocketFactory {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [ScriptedAppEventSocket] = []

    func makeTransport(for request: URLRequest) -> AppEventWebSocketTransport {
        let socket = ScriptedAppEventSocket()
        requests.append(request)
        sockets.append(socket)
        return socket.transport
    }
}

@MainActor
private final class ScriptedAppEventSocket {
    typealias Message = URLSessionWebSocketTask.Message

    private var queuedResults: [Result<Message, Error>] = []
    private var pendingReceive: CheckedContinuation<Message, Error>?
    private var taskState: URLSessionTask.State = .suspended
    private var taskResponse: URLResponse?
    private var taskCloseCode: URLSessionWebSocketTask.CloseCode = .invalid

    lazy var transport = AppEventWebSocketTransport(
        identity: self,
        resume: { [weak self] in self?.taskState = .running },
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
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
                url: URL(string: "ws://127.0.0.1:7749/app/events/stream")!,
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
