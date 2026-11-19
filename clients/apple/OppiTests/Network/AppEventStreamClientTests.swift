import Foundation
import Observation
import Testing
@testable import Oppi

@Suite("AppEventStreamClient", .serialized)
@MainActor
struct AppEventStreamClientTests {
    // The stream is the signal: awaiting its two events needs no wall-clock deadline, which a
    // polling wait lost on a loaded shard. `.timeLimit` is only a hang guard.
    @Test(.timeLimit(.minutes(1)))
    func decodesStringAndDataFramesWhileSkippingMalformedInput() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory)
        let stream = client.connect()

        let socket = try #require(factory.sockets.first)
        socket.yield(.string("not-json"))
        socket.yield(.data(Data(Self.connectedJSON.utf8)))
        socket.yield(.string(#"{"type":"future_app_event"}"#))

        var received: [AppEventMessage] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received == [
            .connected(serverTime: 42, snapshotRequired: false),
            .ignored(type: "future_app_event"),
        ])
        #expect(client.status == .connected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
    }

    // These tests await the events they need: a socket the fake factory opened, a frame or the
    // end of the client's stream (the client sets `.connected` before it yields a frame and
    // `.disconnected` as it finishes the stream), or a callback the client makes. A polling wait
    // on a fixed deadline lost those races on loaded unit shards. `.timeLimit` is only a hang guard.
    // A test reads its stream to the end, or drains it in a task, because dropping the stream
    // early terminates it and the client disconnects.
    @Test(.timeLimit(.minutes(1)))
    func recoverableFailureReconnectsAndContinuesOriginalStream() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory, reconnectDelay: { _ in 0 })
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)

        let secondSocket = try await factory.socket(1)
        secondSocket.yield(.string(Self.connectedJSON))
        secondSocket.yield(.string(#"{"type":"after_reconnect"}"#))

        #expect(await events.next() == .connected(serverTime: 42, snapshotRequired: false))
        #expect(await events.next() == .ignored(type: "after_reconnect"))
        #expect(client.status == .connected)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        #expect(await events.next() == nil)
    }

    // The health report is the signal. The watchdog only reaches it after real 1 ms and 20 ms
    // sleeps, which a loaded shard can stretch past any fixed poll deadline. It reconnects in
    // the same main-actor turn the report returns in, so the state is set once the await
    // resumes. `.timeLimit` is only a hang guard.
    @Test(.timeLimit(.minutes(1)))
    func withheldPingCallbackTimesOutReportsHealthAndReconnects() async throws {
        let factory = ScriptedAppEventSocketFactory()
        factory.pingBehavior = .withhold
        let (healthFailures, reportHealthFailure) = AsyncStream<PersistentStreamHealthFailure>.makeStream()
        let client = makeClient(
            factory: factory,
            pingInterval: .milliseconds(1),
            pingTimeout: .milliseconds(20),
            onTransportHealthFailure: { reportHealthFailure.yield($0) }
        )
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        var failures = healthFailures.makeAsyncIterator()
        #expect(await failures.next() == .pingTimeout)
        #expect(client.status == .reconnecting(attempt: 1))
        #expect(factory.sockets.first?.isCanceling == true)

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedRecoverableFailuresReportUnhealthyTransportAtBoundedThreshold() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let (healthFailures, reportHealthFailure) = AsyncStream<PersistentStreamHealthFailure>.makeStream()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            onTransportHealthFailure: { reportHealthFailure.yield($0) }
        )
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        for index in 0..<4 {
            try await factory.socket(index).fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
        }
        _ = try await factory.socket(4)

        var failures = healthFailures.makeAsyncIterator()
        #expect(await failures.next() == .reconnectThreshold(attempt: 4))
        #expect(factory.sockets.count == 5)

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func recoverableFailuresContinuePastFormerRetryCeiling() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory, reconnectDelay: { _ in 0 })
        var events = client.connect().makeAsyncIterator()

        for index in 0..<11 {
            try await factory.socket(index).fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
        }
        try await factory.socket(11).yield(.string(Self.connectedJSON))

        #expect(await events.next() == .connected(serverTime: 42, snapshotRequired: false))
        #expect(client.status == .connected)
        #expect(factory.sockets.count == 12)

        client.disconnect()
        #expect(await events.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func nonRetryableHandshakeFailureFinishesWithoutOpeningAnotherSocket() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory, reconnectDelay: { _ in 0 })
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await events.next() == nil)
        #expect(client.status == .disconnected)
        #expect(factory.sockets.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func authExpiredCloseForcesOneRefreshThenOneReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_fresh"
            }
        )
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(
            URLError(.networkConnectionLost),
            closeCode: URLSessionWebSocketTask.CloseCode(
                rawValue: WebSocketRecoveryPolicy.authExpiredCloseCodeRawValue
            ) ?? .goingAway
        )

        let reconnected = try await factory.socket(1)
        #expect(refreshCounter.current() == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_fresh")
        #expect(client.status != .disconnected)

        reconnected.yield(.string(Self.connectedJSON))
        #expect(await events.next() == .connected(serverTime: 42, snapshotRequired: false))
        #expect(client.status == .connected)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        #expect(await events.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func auth401ForcesOneRefreshThenOneReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_fresh"
            }
        )
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        let reconnected = try await factory.socket(1)
        #expect(refreshCounter.current() == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_fresh")

        // The reconnected socket is live and drives status back to connected.
        reconnected.yield(.string(Self.connectedJSON))
        #expect(await events.next() == .connected(serverTime: 42, snapshotRequired: false))
        #expect(client.status == .connected)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        #expect(await events.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func authRefreshFailureDisconnectsTerminallyWithoutReconnect() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await events.next() == nil)
        #expect(client.status == .disconnected)
        #expect(refreshCounter.current() == 1)
        #expect(factory.sockets.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedAuth401CannotRefreshOrReconnectForever() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_still_rejected"
            }
        )
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        try await factory.socket(1).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )

        #expect(await events.next() == nil)
        #expect(client.status == .disconnected)
        #expect(refreshCounter.current() == 1)
        #expect(factory.sockets.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func productionStyleProvidersResolveCurrentBeforeOpenAndForceRefreshAfter401() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let currentCounter = RefreshCounter()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
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

        let first = try await factory.socket(0)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")
        #expect(currentCounter.current() == 1)
        #expect(refreshCounter.current() == 0)

        first.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        _ = try await factory.socket(1)
        #expect(factory.sockets.count == 2)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_refreshed")
        #expect(currentCounter.current() == 2)
        #expect(refreshCounter.current() == 1)

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func siblingTokenReuseDoesNotSpendTheOneMintThen401StillRefreshes() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let currentCounter = RefreshCounter()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
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

        try await factory.socket(0).fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        let second = try await factory.socket(1)
        #expect(factory.sockets.count == 2)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_sibling")
        #expect(refreshCounter.current() == 0)

        second.fail(
            URLError(.userAuthenticationRequired),
            responseStatusCode: 401,
            closeCode: .policyViolation
        )
        _ = try await factory.socket(2)
        #expect(factory.sockets.count == 3)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_minted")
        #expect(refreshCounter.current() == 1)
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func leftoverSnapshotDoesNotHandshakeBeforeCurrentTokenResolves() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let gate = TokenGate()
        let client = makeClient(
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
        _ = try await factory.socket(0)
        #expect(factory.sockets.count == 1)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current")

        client.disconnect()
        await consumer.value
    }

    // A regression that disconnects instead of opening fails by the time limit.
    @Test(.timeLimit(.minutes(1)))
    func emptyCurrentTokenKeepsLeftoverAndStillOpens() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(
            factory: factory,
            currentTokenProvider: { "" }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        _ = try await factory.socket(0)
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func expiredLeftoverDoesNotOpenAfterResolutionFailure() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let expiredMs = Int64((Date().timeIntervalSince1970 - 120) * 1000)
        let client = makeClient(
            factory: factory,
            token: "at_expired_leftover",
            leftoverExpiresAtMs: expiredMs,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        var events = client.connect().makeAsyncIterator()

        #expect(await events.next() == nil)
        #expect(client.status == .disconnected)
        #expect(factory.sockets.isEmpty, "Known-expired leftover must not open a socket")
    }

    @Test(.timeLimit(.minutes(1)))
    func unexpiredLeftoverCredentialStillOpensAfterResolutionFailure() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let futureMs = Int64((Date().timeIntervalSince1970 + 600) * 1000)
        let client = makeClient(
            factory: factory,
            token: "at_leftover",
            leftoverExpiresAtMs: futureMs,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        _ = try await factory.socket(0)
        #expect(factory.sockets.count == 1)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_leftover")
        #expect(client.status != .disconnected)

        client.disconnect()
        await consumer.value
    }

    // A regression that disconnects instead of opening fails by the time limit.
    @Test(.timeLimit(.minutes(1)))
    func refreshRejectionKeepsLeftoverAppEventSnapshot() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(
            factory: factory,
            currentTokenProvider: {
                throw DeviceAuthError.refreshRejected(code: "revoked")
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }

        _ = try await factory.socket(0)
        #expect(factory.sockets.count == 1)
        #expect(client.status != .disconnected)
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        client.disconnect()
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalCloseCodeWithoutHTTPResponseFinishesWithoutRetrying() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory, reconnectDelay: { _ in 0 })
        var events = client.connect().makeAsyncIterator()

        try await factory.socket(0).fail(URLError(.badServerResponse), closeCode: .protocolError)

        #expect(await events.next() == nil)
        #expect(client.status == .disconnected)
        #expect(factory.sockets.count == 1)
    }

    // The client asks for the reconnect delay right after it enters `.reconnecting`, so that
    // call is the event the test awaits before it disconnects.
    @Test(.timeLimit(.minutes(1)))
    func disconnectCancelsScheduledReconnectAndFinishesConsumer() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let (scheduledAttempts, scheduleAttempt) = AsyncStream<Int>.makeStream()
        let client = makeClient(factory: factory, reconnectDelay: { attempt in
            scheduleAttempt.yield(attempt)
            return 60
        })
        let stream = client.connect()
        let consumer = Task {
            for await _ in stream {}
        }

        try await factory.socket(0).fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)

        var attempts = scheduledAttempts.makeAsyncIterator()
        #expect(await attempts.next() == 1)
        #expect(client.status == .reconnecting(attempt: 1))

        client.disconnect()
        await consumer.value
        for _ in 0..<5 { await Task.yield() }

        #expect(client.status == .disconnected)
        #expect(factory.sockets.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleStreamTerminationCannotDisconnectReplacementConnection() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let client = makeClient(factory: factory)

        let firstStream = client.connect()
        let firstConsumer = Task {
            for await _ in firstStream {}
        }
        var secondEvents = client.connect().makeAsyncIterator()

        try await factory.socket(1).yield(.string(Self.connectedJSON))

        #expect(await secondEvents.next() == .connected(serverTime: 42, snapshotRequired: false))
        await firstConsumer.value
        for _ in 0..<5 { await Task.yield() }

        #expect(client.status == .connected)
        #expect(factory.sockets.count == 2)

        client.disconnect()
        #expect(await secondEvents.next() == nil)
    }

    @Test func reconnectOpensWithTheSessionsNewestTokenWithoutSpendingA401() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let currentCounter = RefreshCounter()
        let refreshCounter = RefreshCounter()
        let client = makeClient(
            factory: factory,
            reconnectDelay: { _ in 0 },
            currentTokenProvider: { "at_current_\(currentCounter.incrementAndGet())" },
            refreshTokenProvider: {
                refreshCounter.increment()
                return "at_minted"
            }
        )
        let stream = client.connect()
        let consumer = Task { @MainActor in for await _ in stream {} }
        #expect(await waitForMainActorCondition { factory.sockets.count == 1 })
        #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current_1")

        // A drop that is not an auth close: the session has moved on since this socket opened.
        try #require(factory.sockets.first).fail(URLError(.networkConnectionLost), closeCode: .invalid)
        #expect(await waitForMainActorCondition { factory.sockets.count == 2 })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_current_2")
        #expect(refreshCounter.current() == 0)

        client.disconnect()
        await consumer.value
    }

    @Test func renewalRunsOnTheOpenSocketAndItsAnswerIsNotAnAppEvent() async throws {
        let factory = ScriptedAppEventSocketFactory()
        let clock = ManualRenewalClock()
        let tokens = RenewalTokenSource(
            expiries: ["test-token": clock.now.addingTimeInterval(600)],
            fresh: ["at_renewed"]
        )
        let renewer = StreamAuthRenewer(source: tokens.source, streamRole: "test", now: { clock.now }, sleep: clock.sleep)
        let client = makeClient(factory: factory, reconnectDelay: { _ in 0 }, authRenewer: renewer)
        let stream = client.connect()
        var received: [AppEventMessage] = []
        let consumer = Task { @MainActor in
            for await event in stream {
                received.append(event)
            }
        }
        let socket = try #require(factory.sockets.first)

        #expect(await waitForMainActorCondition { clock.sleeps == [540] })
        clock.elapse()
        #expect(await waitForMainActorCondition {
            socket.sentTexts == [#"{"token":"at_renewed","type":"auth_renew"}"#]
                || socket.sentTexts == [#"{"type":"auth_renew","token":"at_renewed"}"#]
        })

        let expiresAtMs = Int64(clock.now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
        socket.yield(.string(#"{"type":"auth_renew_result","ok":true,"expiresAt":\#(expiresAtMs)}"#))
        socket.yield(.string(Self.connectedJSON))
        #expect(await waitForMainActorCondition { received.count == 1 })
        #expect(received == [.connected(serverTime: 42, snapshotRequired: false)])
        #expect(await waitForMainActorCondition { clock.sleeps == [540, StreamAuthRenewer.retryDelay, 540] })

        // The renewed token is the socket's now: a later reconnect opens with it.
        socket.fail(URLError(.networkConnectionLost), closeCode: .invalid)
        #expect(await waitForMainActorCondition { factory.sockets.count == 2 })
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at_renewed")

        client.disconnect()
        await consumer.value
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
        refreshTokenProvider: (@Sendable () async throws -> String)? = nil,
        authRenewer: StreamAuthRenewer? = nil
    ) -> AppEventStreamClient {
        let url = testUnwrap(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        return AppEventStreamClient(
            url: url,
            token: token,
            leftoverExpiresAtMs: leftoverExpiresAtMs,
            currentTokenProvider: currentTokenProvider,
            refreshTokenProvider: refreshTokenProvider,
            authRenewer: authRenewer,
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
    // Awaits each socket open, the snapshot starting, and the session store change instead of
    // polling 500 ms deadlines, which a loaded unit shard missed. `.timeLimit` is only a hang guard.
    @Test(.timeLimit(.minutes(1)))
    func prolongedOutageReconnectSnapshotCompletesBeforeQueuedLiveEventsApply() async throws {
        let gate = AppEventSnapshotGate()
        let snapshotSession = makeTestSession(id: "s1", workspaceId: "w1", status: .ready)
        let coordinator = AppEventStreamCoordinator { connection, _ in
            await gate.waitUntilReleased()
            connection.sessionStore.applyServerSnapshot([snapshotSession])
            return true
        }
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection, credentials: makeTestCredentials(
            host: "snapshot.example",
            fingerprint: "sha256:snapshot"
        )))
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        let factory = ScriptedAppEventSocketFactory()
        let url = testUnwrap(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
        let client = AppEventStreamClient(
            url: url,
            token: "test-token",
            reconnectDelay: { _ in 0 },
            webSocketFactory: { request in factory.makeTransport(for: request) }
        )

        coordinator.start(connection: connection, client: client, streamURL: url)
        for index in 0..<11 {
            try await factory.socket(index).fail(URLError(.networkConnectionLost), closeCode: .abnormalClosure)
        }
        let recoveredSocket = try await factory.socket(11)
        #expect(factory.sockets.count == 12)
        recoveredSocket.yield(.string(#"{"type":"app_events_connected","serverTime":42,"snapshotRequired":true}"#))

        await gate.waitUntilStarted()
        recoveredSocket.yield(.string(#"{"type":"session_deleted","sessionId":"s1","workspaceId":"w1","emittedAt":43}"#))
        #expect(connection.sessionStore.session(id: "s1") != nil)

        gate.release()

        await waitForObservedCondition { connection.sessionStore.session(id: "s1") == nil }
        #expect(connection.sessionStore.session(id: "s1") == nil)
        #expect(connection.appEventStreamTransportState == .connected)

        coordinator.disconnect()
    }

    @Test func serverReconfigurationCancelsOldStreamAndIgnoresItsStaleEvents() async throws {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection, credentials: makeTestCredentials(
            host: "server-a.example",
            fingerprint: "sha256:server-a"
        )))
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        let oldServerId = connection.currentServerId
        let factory = ScriptedAppEventSocketFactory()
        let oldURL = testUnwrap(URL(string: "wss://server-a.example:7749/app/events/stream"))
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

        #expect(await configureTestConnection(connection, credentials: makeTestCredentials(
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
    // `.timeLimit` is a hang guard, not the test's completion signal: the await below is the
    // verdict, and a handshake that never reports must fail the test instead of stalling the
    // whole unit shard.
    @Test(.timeLimit(.minutes(1)), arguments: ["workspace", "session"])
    func connectedWithoutSnapshotRepairsPreexistingListFailure(_ failedProjection: String) async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }

        if failedProjection == "workspace" {
            connection.workspaceStore.markSyncFailed()
        } else {
            connection.sessionStore.markSyncFailed()
        }

        let requestCounter = ReconciliationRequestCounter()
        TestURLProtocol.handler = { request in
            requestCounter.record(path: request.url?.path ?? "")
            return try Self.reconciliationResponse(for: request)
        }

        // `connectAppEventStream(awaitHandshake:)` returns once the coordinator's handshake —
        // including the repair this test is about — has settled, so these assert its outcome
        // rather than race it. One pass refreshed both projections and cleared the failure it
        // was asked to repair; a second pass would mean the handshake fetched twice.
        _ = try await connectAppEventStream(
            for: connection,
            snapshotRequired: false,
            awaitHandshake: true
        )

        // A failed session list repairs the session list; the catalog reloads only when it
        // failed itself (a fresh, healthy one follows its freshness window).
        let catalogReads = failedProjection == "workspace" ? 1 : 0
        #expect(requestCounter.count(path: "/workspaces") == catalogReads)
        #expect(requestCounter.count(path: "/skills") == catalogReads)
        #expect(requestCounter.count(path: "/sessions/recent") == 1)
        #expect(connection.workspaceStore.lastSyncFailed == false)
        #expect(connection.sessionStore.lastSyncFailed == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func snapshotRequiredRefreshesBothProjectionsBeforeQueuedEvent() async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        makeCatalogStale(connection)
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))

        let workspaceGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestCounter.record(path: path)
            if path == "/workspaces" {
                workspaceGate.blockUntilReleased()
            }
            return try Self.reconciliationResponse(for: request)
        }

        let factory = try await connectAppEventStream(for: connection, snapshotRequired: true)
        await workspaceGate.started()

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

    @Test(.timeLimit(.minutes(1)))
    func lateRefreshFailureAfterAppEventConnectionGetsOneFullFollowUp() async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        makeCatalogStale(connection)
        let requestGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let occurrence = requestCounter.record(path: path)
            if path == "/sessions/recent", occurrence == 1 {
                requestGate.blockUntilReleased()
                throw URLError(.cannotConnectToHost)
            }
            return try Self.reconciliationResponse(for: request)
        }

        let initialRefresh = Task { @MainActor in
            await connection.refreshSessionList(force: true)
        }
        await requestGate.started()
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

    @Test(.timeLimit(.minutes(1)))
    func failedLateRepairIsBoundedWithoutNetworkFanOut() async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        makeCatalogStale(connection)
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
        await requestGate.started()
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
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        _ = try await connectAppEventStream(for: connection, snapshotRequired: false)
        #expect(connection.appEventStreamTransportState == .connected)

        connection.setAPIClientForTesting(makeReconciliationAPIClient(token: "replacement"))

        #expect(connection.appEventStreamTransportState == .disconnected)
        #expect(connection.appEventStreamCoordinator.isRunning == false)
        #expect(connection.appEventListRepair.task == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleWorkspaceRefreshCannotCommitAfterAPIReplacement() async throws {
        let connection = await makeReconciliationConnection()
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
                let response = (try #require(HTTPURLResponse(
                    url: (testUnwrap(request.url)),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )))
                return (Data(body.utf8), response)
            }
            return try Self.reconciliationResponse(for: request)
        }

        let refresh = Task { @MainActor in
            await connection.refreshWorkspaceCatalog(force: true)
        }
        await requestGate.started()
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        requestGate.release()
        await refresh.value

        #expect(connection.workspaceStore.workspaces.map(\.id) == ["kept"])
        #expect(!connection.workspaceStore.isSyncing)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleSessionRefreshBalancesSyncingAfterAPIReplacement() async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        connection.sessionStore.upsert(makeTestSession(id: "kept", workspaceId: "w1"))

        let requestGate = BlockingReconciliationRequestGate()
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/sessions/recent" {
                requestGate.blockUntilReleased()
            }
            return try Self.reconciliationResponse(for: request)
        }

        let refresh = Task { @MainActor in
            await connection.refreshSessionList(force: true)
        }
        await requestGate.started()
        #expect(await waitForMainActorCondition { connection.sessionStore.isSyncing })
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        requestGate.release()
        await refresh.value

        #expect(connection.sessionStore.session(id: "kept") != nil)
        #expect(!connection.sessionStore.isSyncing)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelingRepairPreventsStartingTheNextListLeg() async throws {
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        makeCatalogStale(connection)
        let workspaceGate = BlockingReconciliationRequestGate()
        let requestCounter = ReconciliationRequestCounter()

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestCounter.record(path: path)
            if path == "/workspaces" {
                workspaceGate.blockUntilReleased()
            }
            return try Self.reconciliationResponse(for: request)
        }

        _ = try await connectAppEventStream(for: connection, snapshotRequired: false)
        let repair = Task { @MainActor in
            await connection.reconcileListSnapshotsAfterAppEventConnection(snapshotRequired: true)
        }
        await workspaceGate.started()

        connection.disconnectAppEventStream()
        workspaceGate.release()
        await repair.value

        #expect(requestCounter.count(path: "/sessions/recent") == 0)
        #expect(connection.appEventListRepair.task == nil)
    }

    @Test func refreshFailureTelemetryUsesCoarseErrorMetadata() async throws {
        let connection = await makeReconciliationConnection()
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
        let connection = await makeReconciliationConnection()
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
        let connection = await makeReconciliationConnection()
        defer { cleanup(connection) }
        var endMetadata: [String: String] = [:]
        connection._onRefreshEventForTesting = { message, metadata, _ in
            if message == "workspace_catalog.end" {
                endMetadata = metadata
            }
        }
        let rawBody = "https://secret.example.test/token=sk_secret"
        TestURLProtocol.handler = { request in
            let response = (try #require(HTTPURLResponse(
                url: request.url ?? URL(string: "http://reconcile.example.test:7749")!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )))
            return (Data("{\"error\":\"\(rawBody)\"}".utf8), response)
        }

        await connection.refreshWorkspaceCatalog(force: true)

        #expect(endMetadata["result"] == "failure")
        #expect(endMetadata["errorKind"] == "http")
        #expect(endMetadata["statusCode"] == "503")
        #expect(endMetadata.values.allSatisfy { !$0.contains("secret.example.test") })
        #expect(endMetadata.values.allSatisfy { !$0.contains("sk_secret") })
    }

    /// A catalog past its freshness window: the handshake's repair reads it again, where a fresh
    /// one is left alone.
    private func makeCatalogStale(_ connection: ServerConnection) {
        connection.workspaceStore.markSyncSucceeded(
            at: Date().addingTimeInterval(-ServerConnection.listRefreshMinimumInterval - 1)
        )
    }

    private func makeReconciliationConnection() async -> ServerConnection {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection, credentials: ServerCredentials(
            host: "reconcile.example.test",
            port: 7749,
            token: "sk_reconcile",
            name: "Reconcile",
            scheme: .https,
            serverFingerprint: "sha256:reconcile"
        )))
        connection.setAPIClientForTesting(makeReconciliationAPIClient())
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        // A `.connected` app event refreshes pending pairing approvals. These tests answer no
        // `GET /auth/pairing-approvals`, and the request outlived its test: it reached the double after the
        // handler was cleared and failed the whole run. The seam answers it in memory instead.
        connection._listPairingApprovalsForTesting = { [] }
        connection.workspaceStore.isLoaded = true
        connection.workspaceStore.markSyncSucceeded(at: Date())
        connection.sessionStore.markSyncSucceeded(at: Date())
        return connection
    }

    private func makeReconciliationAPIClient(token: String = "sk_reconcile") -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
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
        snapshotRequired: Bool,
        awaitHandshake: Bool = false
    ) async throws -> ScriptedAppEventSocketFactory {
        var handshake: AsyncStream<Void>?
        if awaitHandshake {
            // The coordinator handles an event only after it has awaited the `.connected`
            // snapshot repair, and that event's handler then refreshes pending pairing
            // approvals. This seam firing is therefore the handshake's completion, repair
            // included — a real signal, where polling `appEventStreamTransportState` raced a
            // one-second deadline on a loaded host. Callers that hold a repair response on
            // purpose (a gated request) must keep the default: they would deadlock here.
            let (stream, sink) = AsyncStream<Void>.makeStream()
            handshake = stream
            connection._listPairingApprovalsForTesting = {
                sink.yield()
                return []
            }
        }
        let factory = ScriptedAppEventSocketFactory()
        let url = testUnwrap(URL(string: "ws://127.0.0.1:7749/app/events/stream"))
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
        if let handshake {
            for await _ in handshake { break }
        } else {
            #expect(await waitForMainActorCondition {
                connection.appEventStreamTransportState == .connected
            })
        }
        return factory
    }

    private func cleanup(_ connection: ServerConnection) {
        TestURLProtocol.handler = nil
        connection.disconnectAppEventStream()
        connection.disconnectStream()
    }

    private static func reconciliationResponse(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
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
        let response = (try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "http://reconcile.example.test:7749")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )))
        return (Data(body.utf8), response)
    }
}

/// Holds a request on URLProtocol's thread until the test releases it. The test awaits
/// `started()`, the request reaching the gate, rather than polling for it on a deadline a
/// loaded unit shard can miss; each test's `.timeLimit` is the hang guard.
private final class BlockingReconciliationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func started() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isStarted {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func blockUntilReleased() {
        lock.lock()
        isStarted = true
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
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

/// Wakes the tests waiting on a fake's main-actor event. A waiter re-checks its condition after
/// each wake, so it awaits the event itself instead of polling a wall-clock deadline. A cancelled
/// wait returns, so a test's `.timeLimit` can end one that never sees its event.
@MainActor
private final class TestEventSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let waiters = waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }

    func wait(until isDone: () -> Bool) async {
        while !isDone(), !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { @MainActor in self.fire() }
            }
        }
    }
}

/// Awaits an `@Observable` main-actor condition: each change it reads wakes the wait to re-check.
@MainActor
private func waitForObservedCondition(_ isDone: @escaping @MainActor () -> Bool) async {
    let changed = TestEventSignal()
    await changed.wait {
        withObservationTracking { isDone() } onChange: { Task { @MainActor in changed.fire() } }
    }
}

@MainActor
private final class AppEventSnapshotGate {
    private var hasStarted = false
    private let started = TestEventSignal()
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        await started.wait { hasStarted }
    }

    func waitUntilReleased() async {
        hasStarted = true
        started.fire()
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
    private let socketOpened = TestEventSignal()

    func makeTransport(for request: URLRequest) -> PersistentWebSocketTransport {
        let socket = ScriptedAppEventSocket(pingBehavior: pingBehavior)
        requests.append(request)
        sockets.append(socket)
        socketOpened.fire()
        return socket.transport
    }

    /// The socket the client opened at `index` (0 is the first open), once it has opened it.
    func socket(_ index: Int) async throws -> ScriptedAppEventSocket {
        await socketOpened.wait { sockets.count > index }
        try Task.checkCancellation()
        return sockets[index]
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
    private(set) var sentTexts: [String] = []

    init(pingBehavior: ScriptedPingBehavior = .succeed) {
        self.pingBehavior = pingBehavior
    }

    var isCanceling: Bool {
        taskState == .canceling
    }

    lazy var transport = PersistentWebSocketTransport(
        identity: self,
        resume: { [weak self] in self?.taskState = .running },
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        send: { [weak self] message in
            if case .string(let text) = message { self?.sentTexts.append(text) }
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
