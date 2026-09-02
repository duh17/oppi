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

    @Test func withheldPingCallbackTimesOutReportsHealthAndReconnects() async throws {
        let factory = ScriptedAppEventSocketFactory()
        factory.pingBehavior = .withhold
        var healthFailures: [PersistentStreamHealthFailure] = []
        let client = try makeClient(
            factory: factory,
            pingInterval: .milliseconds(1),
            pingTimeout: .milliseconds(20),
            onTransportHealthFailure: { healthFailures.append($0) }
        )
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            healthFailures == [.pingTimeout]
        })
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            if case .reconnecting(attempt: 1) = client.status { return true }
            return false
        })
        #expect(factory.sockets.first?.isCanceling == true)

        client.disconnect()
        await consumer.value
    }

    @Test func repeatedRecoverableFailuresReportUnhealthyTransportAtBoundedThreshold() async throws {
        let factory = ScriptedAppEventSocketFactory()
        var healthFailures: [PersistentStreamHealthFailure] = []
        let client = try makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            onTransportHealthFailure: { healthFailures.append($0) }
        )
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        for expectedSocketCount in 2...5 {
            let socket = try #require(factory.sockets.last)
            socket.fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
            #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
                factory.sockets.count == expectedSocketCount
            })
        }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            healthFailures == [.reconnectThreshold(attempt: 4)]
        })

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

    @Test func authExpiredCloseForcesOneRefreshThenOneReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_fresh"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        let socket = try #require(factory.sockets.first)
        socket.fail(
            URLError(.networkConnectionLost),
            closeCode: URLSessionWebSocketTask.CloseCode(
                rawValue: WebSocketRecoveryPolicy.authExpiredCloseCodeRawValue
            ) ?? .goingAway
        )

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })
        #expect(refreshCounter.current() == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_fresh")
        #expect(client.status != .disconnected)

        let reconnected = try #require(factory.sockets.last)
        reconnected.yield(.string(Self.connectedJSON))
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .connected
        })

        client.disconnect()
        await consumer.value
    }

    @Test func auth401ForcesOneRefreshThenOneReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_fresh"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        let socket = try #require(factory.sockets.first)
        socket.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })
        #expect(refreshCounter.current() == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_fresh")

        // The reconnected socket is live and drives status back to connected.
        let reconnected = try #require(factory.sockets.last)
        reconnected.yield(.string(Self.connectedJSON))
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .connected
        })

        client.disconnect()
        await consumer.value
    }

    @Test func authRefreshFailureDisconnectsTerminallyWithoutReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in
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
        #expect(refreshCounter.current() == 1)
        #expect(factory.sockets.count == 1)

        client.disconnect()
        await consumer.value
    }

    @Test func repeatedAuth401CannotRefreshOrReconnectForever() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_still_rejected"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        let first = try #require(factory.sockets.first)
        first.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })

        let second = try #require(factory.sockets.last)
        second.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .disconnected
        })
        #expect(refreshCounter.current() == 1)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        await consumer.value
    }

    @Test func productionStyleProvidersResolveCurrentBeforeOpenAndForceRefreshAfter401() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let currentCounter = RefreshCounter()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            token: "",
            reconnectDelay: { _ in 0 },
            currentTokenProvider: {
                currentCounter.increment()
                return "at_current"
            },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_refreshed"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")
        #expect(currentCounter.current() == 1)
        #expect(refreshCounter.current() == 0)

        let first = try #require(factory.sockets.first)
        first.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_refreshed")
        #expect(currentCounter.current() == 2)
        #expect(refreshCounter.current() == 1)

        client.disconnect()
        await consumer.value
    }

    @Test func siblingTokenReuseDoesNotSpendTheOneMintThen401StillRefreshes() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let currentCounter = RefreshCounter()
        let refreshCounter = RefreshCounter()
        let client = try makeClient(
            factory: factory,
            token: "",
            reconnectDelay: { _ in 0 },
            currentTokenProvider: {
                let count = currentCounter.incrementAndGet()
                if count == 1 { return "at_current" }
                return "at_sibling"
            },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_minted"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1
        })
        try #require(factory.sockets.first).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 2
        })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_sibling")
        #expect(refreshCounter.current() == 0)

        try #require(factory.sockets.last).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 3
        })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_minted")
        #expect(refreshCounter.current() == 1)
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func leftoverSnapshotDoesNotHandshakeBeforeCurrentTokenResolves() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let gate = TokenGate()
        let client = try makeClient(
            factory: factory,
            token: "at_stale",
            currentTokenProvider: {
                await gate.wait()
                return "at_current"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        try await Task.sleep(for: .milliseconds(30))
        #expect(factory.sockets.isEmpty, "Must not open leftover before currentAccessToken returns")

        await gate.release()
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")

        client.disconnect()
        await consumer.value
    }

    @Test func emptyCurrentTokenKeepsLeftoverAndStillOpens() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(
            factory: factory,
            currentTokenProvider: { "" }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
        await consumer.value
    }

    @Test func expiredLeftoverDoesNotOpenAfterResolutionFailure() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let expiredMs = Int64((Date().timeIntervalSince1970 - 120) * 1000)
        let client = try makeClient(
            factory: factory,
            token: "at_expired_leftover",
            leftoverExpiresAtMs: expiredMs,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            client.status == .disconnected
        })
        #expect(factory.sockets.isEmpty, "Known-expired leftover must not open a socket")

        client.disconnect()
        await consumer.value
    }

    @Test func unexpiredLeftoverCredentialStillOpensAfterResolutionFailure() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let futureMs = Int64((Date().timeIntervalSince1970 + 600) * 1000)
        let client = try makeClient(
            factory: factory,
            token: "at_leftover",
            leftoverExpiresAtMs: futureMs,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1
        })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_leftover")
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test func refreshRejectionKeepsLeftoverAppEventSnapshot() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = try makeClient(
            factory: factory,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            factory.sockets.count == 1 || client.status == .disconnected
        })
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
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
        token: String = "test-token",
        pingInterval: Duration = WebSocketRecoveryPolicy.pingInterval,
        pingTimeout: Duration = WebSocketRecoveryPolicy.pingTimeout,
        reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { _ in 60 },
        onTransportHealthFailure: (@MainActor @Sendable (PersistentStreamHealthFailure) async -> Void)? = nil,
        leftoverExpiresAtMs: Int64? = nil,
        currentTokenProvider: (@Sendable () async throws -> String)? = nil,
        refreshTokenProvider: (@Sendable () async throws -> String)? = nil
    ) throws -> AppEventStreamClient {
        let url = try #require(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        return AppEventStreamClient(
            url: url,
            token: token,
            leftoverExpiresAtMs: leftoverExpiresAtMs,
            currentTokenProvider: currentTokenProvider,
            refreshTokenProvider: refreshTokenProvider,
            pingInterval: pingInterval,
            pingTimeout: pingTimeout,
            reconnectDelay: reconnectDelay,
            onTransportHealthFailure: onTransportHealthFailure,
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
        let coordinator = AppEventStreamCoordinator { connection, _ in
            await gate.waitUntilReleased()
            connection.sessionStore.applyServerSnapshot([snapshotSession])
            return true
        }
        let connection = ServerConnection()
        #expect(connection.configure(credentials: makeTestCredentials(
            host: "snapshot.example",
            fingerprint: "sha256:snapshot"
        )))
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

@Suite("Sticky Refresh Reconciliation", .serialized)
@MainActor
struct StickyRefreshReconciliationTests {
    @Test(arguments: ["workspace", "session"])
    func connectedWithoutSnapshotRepairsPreexistingListFailure(_ failedProjection: String) async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }

        if failedProjection == "workspace" {
            connection.workspaceStore.markSyncFailed()
        } else {
            connection.sessionStore.markSyncFailed()
        }

        let requestCounter = ReconciliationRequestCounter()
        TestURLProtocol.handler = { request in
            requestCounter.record(path: request.url?.path ?? "")
            return Self.reconciliationResponse(for: request)
        }

        _ = try await connectAppEventStream(
            for: connection,
            snapshotRequired: false
        )

        let repaired = await waitForMainActorCondition(timeout: .seconds(2)) {
            requestCounter.count(path: "/workspaces") == 1
                && requestCounter.count(path: "/skills") == 1
                && requestCounter.count(path: "/sessions/recent") == 1
                && !connection.workspaceStore.lastSyncFailed
                && !connection.sessionStore.lastSyncFailed
        }

        #expect(repaired)
        #expect(connection.workspaceStore.lastSyncFailed == false)
        #expect(connection.sessionStore.lastSyncFailed == false)
    }

    @Test func snapshotRequiredRefreshesBothProjectionsBeforeQueuedEvent() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))

        let workspaceGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestCounter.record(path: path)
            if path == "/workspaces" {
                workspaceGate.blockUntilReleased()
            }
            return Self.reconciliationResponse(for: request)
        }

        let factory = try await connectAppEventStream(for: connection, snapshotRequired: true)
        #expect(await waitForTestCondition(timeout: .seconds(1)) { workspaceGate.isStarted })

        let socket = try #require(factory.sockets.first)
        socket.yield(.string(#"{"type":"session_deleted","sessionId":"s1","workspaceId":"w1","emittedAt":43}"#))
        #expect(connection.sessionStore.session(id: "s1") != nil)

        workspaceGate.release()

        let applied = await waitForMainActorCondition(timeout: .seconds(2)) {
            connection.sessionStore.session(id: "s1") == nil
                && requestCounter.count(path: "/workspaces") == 1
                && requestCounter.count(path: "/skills") == 1
                && requestCounter.count(path: "/sessions/recent") == 1
        }
        #expect(applied)
    }

    @Test func lateRefreshFailureAfterAppEventConnectionGetsOneFullFollowUp() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        let requestGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let occurrence = requestCounter.record(path: path)
            if path == "/sessions/recent", occurrence == 1 {
                requestGate.blockUntilReleased()
                throw URLError(.cannotConnectToHost)
            }
            return Self.reconciliationResponse(for: request)
        }

        let initialRefresh = Task { @MainActor in
            await connection.refreshSessionList(force: true)
        }
        #expect(await waitForTestCondition(timeout: .seconds(1)) { requestGate.isStarted })
        _ = try await connectAppEventStream(
            for: connection,
            snapshotRequired: false
        )
        requestGate.release()
        await initialRefresh.value

        let repaired = await waitForMainActorCondition(timeout: .seconds(2)) {
            requestCounter.count(path: "/sessions/recent") == 2
                && requestCounter.count(path: "/workspaces") == 1
                && requestCounter.count(path: "/skills") == 1
                && !connection.sessionStore.lastSyncFailed
                && !connection.workspaceStore.lastSyncFailed
        }

        #expect(repaired)
        #expect(requestCounter.count(path: "/sessions/recent") == 2)
        #expect(connection.sessionStore.lastSyncFailed == false)
        #expect(connection.workspaceStore.lastSyncFailed == false)
    }

    @Test func failedLateRepairIsBoundedWithoutNetworkFanOut() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        let requestGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let occurrence = requestCounter.record(path: path)
            if path == "/sessions/recent", occurrence == 1 {
                requestGate.blockUntilReleased()
            }
            throw URLError(.cannotConnectToHost)
        }

        let initialRefresh = Task { @MainActor in
            await connection.refreshSessionList(force: true)
        }
        #expect(await waitForTestCondition(timeout: .seconds(1)) { requestGate.isStarted })
        _ = try await connectAppEventStream(
            for: connection,
            snapshotRequired: false
        )
        requestGate.release()
        await initialRefresh.value

        let bounded = await waitForMainActorCondition(timeout: .seconds(2)) {
            requestCounter.count(path: "/sessions/recent") == 2
                && requestCounter.count(path: "/workspaces") == 1
                && requestCounter.count(path: "/skills") == 1
                && connection.sessionStore.lastSyncFailed
                && connection.workspaceStore.lastSyncFailed
        }
        #expect(bounded)

        let countsAfterRepair = requestCounter.snapshot()
        try await Task.sleep(for: .milliseconds(150))
        #expect(requestCounter.snapshot() == countsAfterRepair)
        #expect(connection.sessionStore.lastSyncFailed)
        #expect(connection.workspaceStore.lastSyncFailed)
    }

    @Test func installingAPIClientDisconnectsAppEventStream() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        _ = try await connectAppEventStream(for: connection, snapshotRequired: false)
        #expect(connection.appEventStreamTransportState == .connected)

        connection.setAPIClientForTesting(makeReconciliationAPIClient(token: "replacement"))

        #expect(connection.appEventStreamTransportState == .disconnected)
        #expect(connection.appEventStreamCoordinator.isRunning == false)
        #expect(connection.appEventListRepairTask == nil)
    }

    @Test func staleWorkspaceRefreshCannotCommitAfterAPIReplacement() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        connection.workspaceStore.workspaces = [
            makeTestWorkspace(id: "kept", name: "Kept")
        ]
        connection.workspaceStore.isLoaded = true

        let requestGate = BlockingReconciliationRequestGate()
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/workspaces" {
                requestGate.blockUntilReleased()
                let body = #"{"serverNow":1700000000000,"workspaces":[{"id":"stale","name":"Stale","path":"/stale","createdAt":1}],"summaries":[]}"#
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(body.utf8), response)
            }
            return Self.reconciliationResponse(for: request)
        }

        let refresh = Task { @MainActor in
            await connection.refreshWorkspaceCatalog(force: true)
        }
        #expect(await waitForTestCondition(timeout: .seconds(1)) { requestGate.isStarted })
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        requestGate.release()
        await refresh.value

        #expect(connection.workspaceStore.workspaces.map(\.id) == ["kept"])
        #expect(!connection.workspaceStore.isSyncing)
    }

    @Test func staleSessionRefreshBalancesSyncingAfterAPIReplacement() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        connection.sessionStore.upsert(makeTestSession(id: "kept", workspaceId: "w1"))

        let requestGate = BlockingReconciliationRequestGate()
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/sessions/recent" {
                requestGate.blockUntilReleased()
            }
            return Self.reconciliationResponse(for: request)
        }

        let refresh = Task { @MainActor in
            await connection.refreshSessionList(force: true)
        }
        #expect(await waitForTestCondition(timeout: .seconds(1)) { requestGate.isStarted })
        #expect(await waitForMainActorCondition { connection.sessionStore.isSyncing })
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        requestGate.release()
        await refresh.value

        #expect(connection.sessionStore.session(id: "kept") != nil)
        #expect(!connection.sessionStore.isSyncing)
    }

    @Test func cancelingRepairPreventsStartingTheNextListLeg() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        let workspaceGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestCounter.record(path: path)
            if path == "/workspaces" {
                workspaceGate.blockUntilReleased()
            }
            return Self.reconciliationResponse(for: request)
        }

        _ = try await connectAppEventStream(for: connection, snapshotRequired: false)
        let repair = Task { @MainActor in
            await connection.reconcileListSnapshotsAfterAppEventConnection(snapshotRequired: true)
        }
        #expect(await waitForTestCondition(timeout: .seconds(1)) { workspaceGate.isStarted })

        connection.disconnectAppEventStream()
        workspaceGate.release()
        await repair.value

        #expect(requestCounter.count(path: "/sessions/recent") == 0)
        #expect(connection.appEventListRepairTask == nil)
    }

    @Test func refreshFailureTelemetryUsesCoarseErrorMetadata() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        var endMetadata: [String: String] = [:]
        connection._onRefreshEventForTesting = { message, metadata, _ in
            if message == "session_list.end" {
                endMetadata = metadata
            }
        }
        TestURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        await connection.refreshSessionList(force: true)

        #expect(endMetadata["result"] == "failure")
        #expect(endMetadata["error"] == nil)
        #expect(endMetadata["errorKind"] == "url")
        #expect(endMetadata["errorDomain"] == NSURLErrorDomain)
        #expect(endMetadata["errorCode"] != nil)
    }

    @Test func workspaceURLErrorTelemetryOmitsRawFailureDetails() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        var endMetadata: [String: String] = [:]
        connection._onRefreshEventForTesting = { message, metadata, _ in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
            }
        }
        let rawFailure = "https://secret.example.test/token=sk_secret"
        TestURLProtocol.handler = { _ in
            throw URLError(
                .cannotConnectToHost,
                userInfo: [
                    NSURLErrorFailingURLStringErrorKey: rawFailure,
                    NSLocalizedDescriptionKey: "could not connect to \(rawFailure)",
                ]
            )
        }

        await connection.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["result"] == "failure")
        #expect(endMetadata["errorKind"] == "url")
        #expect(endMetadata["errorDomain"] == NSURLErrorDomain)
        #expect(endMetadata["errorCode"] != nil)
        #expect(endMetadata.values.allSatisfy { !$0.contains("secret.example.test") })
        #expect(endMetadata.values.allSatisfy { !$0.contains("sk_secret") })
    }

    @Test func workspaceHTTPStatusTelemetryUsesStatusWithoutRawBody() async throws {
        let connection = makeReconciliationConnection()
        defer { cleanup(connection) }
        var endMetadata: [String: String] = [:]
        connection._onRefreshEventForTesting = { message, metadata, _ in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
            }
        }
        let rawBody = "https://secret.example.test/token=sk_secret"
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://reconcile.example.test:7749")!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data("{\"error\":\"\(rawBody)\"}".utf8), response)
        }

        await connection.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["result"] == "failure")
        #expect(endMetadata["errorKind"] == "http")
        #expect(endMetadata["statusCode"] == "503")
        #expect(endMetadata.values.allSatisfy { !$0.contains("secret.example.test") })
        #expect(endMetadata.values.allSatisfy { !$0.contains("sk_secret") })
    }

    private func makeReconciliationConnection() -> ServerConnection {
        let connection = ServerConnection()
        #expect(connection.configure(credentials: ServerCredentials(
            host: "reconcile.example.test",
            port: 7749,
            token: "sk_reconcile",
            name: "Reconcile",
            scheme: .https,
            serverFingerprint: "sha256:reconcile"
        )))
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.workspaceStore.isLoaded = true
        connection.workspaceStore.markSyncSucceeded(at: Date())
        connection.sessionStore.markSyncSucceeded(at: Date())
        return connection
    }

    private func makeReconciliationAPIClient(token: String = "sk_reconcile") -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://reconcile.example.test:7749")!,
                bearerToken: token
            ),
            configuration: configuration
        )
    }

    private func connectAppEventStream(
        for connection: ServerConnection,
        snapshotRequired: Bool
    ) async throws -> ScriptedAppEventSocketFactory {
        let factory = ScriptedAppEventSocketFactory()
        let url = try #require(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        let client = AppEventStreamClient(
            url: url,
            token: "test-token",
            reconnectDelay: { _ in 60 },
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )
        connection.appEventStreamCoordinator.start(
            connection: connection,
            client: client,
            streamURL: url
        )
        let socket = try #require(factory.sockets.first)
        socket.yield(.string("{\"type\":\"app_events_connected\",\"serverTime\":42,\"snapshotRequired\":\(snapshotRequired) }"))
        #expect(await waitForMainActorCondition {
            connection.appEventStreamTransportState == .connected
        })
        return factory
    }

    private func cleanup(_ connection: ServerConnection) {
        TestURLProtocol.handler = nil
        connection.disconnectAppEventStream()
        connection.disconnectStream()
    }

    private static func reconciliationResponse(
        for request: URLRequest
    ) -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path {
        case "/workspaces":
            body = "{\"serverNow\":1700000000000,\"workspaces\":[],\"summaries\":[]}"
        case "/skills":
            body = "{\"skills\":[]}"
        case "/sessions/recent":
            body = "{\"sessions\":[]}"
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://reconcile.example.test:7749")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}

private final class BlockingReconciliationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func blockUntilReleased() {
        lock.lock()
        started = true
        lock.unlock()
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class ReconciliationRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]

    @discardableResult
    func record(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        paths[path, default: 0] += 1
        return paths[path, default: 0]
    }

    func count(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths[path, default: 0]
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private actor TokenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
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

private enum ScriptedPingBehavior {
    case succeed
    case fail
    case withhold
}

@MainActor
private final class ScriptedAppEventSocketFactory {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [ScriptedAppEventSocket] = []
    var pingBehavior: ScriptedPingBehavior = .succeed

    func makeTransport(for request: URLRequest) -> AppEventWebSocketTransport {
        let socket = ScriptedAppEventSocket(pingBehavior: pingBehavior)
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
    private let pingBehavior: ScriptedPingBehavior

    init(pingBehavior: ScriptedPingBehavior = .succeed) {
        self.pingBehavior = pingBehavior
    }

    var isCanceling: Bool {
        taskState == .canceling
    }

    lazy var transport = AppEventWebSocketTransport(
        identity: self,
        resume: { [weak self] in self?.taskState = .running },
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        sendPing: { [weak self] handler in
            switch self?.pingBehavior {
            case .succeed:
                handler(nil)
            case .fail:
                handler(URLError(.networkConnectionLost))
            case .withhold, nil:
                break
            }
        },
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
