import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Stream")
struct ServerConnectionStreamTests {

    // MARK: - connectStream idempotency

    @MainActor
    @Test func connectStreamIsIdempotentWhileActive() {
        let conn = makeTestConnection()

        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel
        conn.wsClient?._setStatusForTesting(.connected)

        conn.connectStream()

        #expect(!sentinel.isCancelled,
                "Should not cancel existing task when one is active and WS is connected")
    }

    @MainActor
    @Test func connectStreamSkipsWhenWSAlreadyConnectedAndNoTask() {
        let conn = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        // No consumption task — would normally trigger wsClient.connect()
        conn.streamConsumptionTask = nil

        conn.connectStream()

        // Should NOT have started a new connection — the WS is healthy.
        // wsClient.connect() would have reset status to .connecting.
        #expect(conn.wsClient?.status == .connected,
                "connectStream should not tear down a healthy WS")
    }

    @MainActor
    @Test func connectStreamRestartsWhenTaskExistsButWSDisconnected() {
        let conn = makeTestConnection()

        conn.streamConsumptionTask = Task { }
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create new task when WS is disconnected")
    }

    @MainActor
    @Test func connectStreamCreatesTaskWhenNil() {
        let conn = makeTestConnection()

        #expect(conn.streamConsumptionTask == nil)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create task when none exists")
    }

    // MARK: - streamConsumptionTask self-cleanup

    @MainActor
    @Test func consumptionTaskNilsItselfWhenStreamEnds() async {
        let conn = makeTestConnection()

        let (stream, continuation) = AsyncStream<StreamMessage>.makeStream()
        continuation.finish()

        conn.streamConsumptionTask = Task { [weak conn] in
            for await msg in stream {
                conn?.routeStreamMessage(msg)
            }
            await MainActor.run { [weak conn] in
                conn?.streamConsumptionTask = nil
            }
        }

        let cleaned = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { conn.streamConsumptionTask == nil }
        }

        #expect(cleaned, "streamConsumptionTask should nil itself after stream ends")
    }

    // MARK: - disconnectStream cleanup

    @MainActor
    @Test func disconnectStreamCleansUpEverything() {
        let conn = makeTestConnection()
        conn.streamConsumptionTask = Task { }

        let (_, continuation) = AsyncStream<ServerMessage>.makeStream()
        conn.sessionContinuations["s1"] = continuation

        conn.disconnectStream()

        #expect(conn.streamConsumptionTask == nil,
                "Should nil out consumption task")
        #expect(conn.sessionContinuations.isEmpty,
                "Should clear all session continuations")
    }

    // MARK: - handleStreamReconnected re-subscribes

    @MainActor
    @Test func streamConnectedMessageTriggersResubscribe() {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var yieldedToSession = false
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }
        let consumeTask = Task {
            for await _ in stream {
                await MainActor.run { yieldedToSession = true }
            }
        }

        let streamMsg = StreamMessage(
            sessionId: nil,
            streamSeq: nil,
            seq: nil,
            currentSeq: nil,
            message: .streamConnected(userName: "test")
        )
        conn.routeStreamMessage(streamMsg)

        #expect(!yieldedToSession,
                "stream_connected should be handled at stream level, not yielded to sessions")
        consumeTask.cancel()
    }

    // MARK: - routeStreamMessage routing

    @MainActor
    @Test func routeStreamMessageYieldsToSessionContinuation() async {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedMessages: [ServerMessage] = []
        let stream = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await msg in stream {
                await MainActor.run { receivedMessages.append(msg) }
            }
        }

        let permRequest = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "test", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
            currentSeq: nil,
            message: .permissionRequest(permRequest)
        )
        conn.routeStreamMessage(streamMsg)

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedMessages.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to session continuation")
    }

    // MARK: - reconnectIfNeeded restarts dead stream

    @MainActor
    @Test func reconnectIfNeededRestartsDeadStream() async {
        let conn = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a dead stream")
    }

    @MainActor
    @Test func reconnectIfNeededSkipsAliveStream() async {
        let conn = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.connected)
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel

        await conn.reconnectIfNeeded()

        #expect(!sentinel.isCancelled,
                "Should not replace an active consumption task")
    }

    // MARK: - routeStreamMessage resolves subscribe waiter eagerly

    @MainActor
    @Test func routeStreamMessageResolvesSubscribeWaiterBeforePerSessionRouting() async {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "subscribe", requestId: "req-1")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
            currentSeq: nil,
            message: .commandResult(
                command: "subscribe", requestId: "req-1",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "Subscribe waiter should be resolved eagerly by routeStreamMessage")
    }

    @MainActor
    @Test func routeStreamMessageResolvesGetQueueWaiterEagerly() async {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "get_queue", requestId: "req-q")
        conn.commands.registerCommand(pending)

        // Per-session stream exists but nobody is consuming it — same as
        // in streamSession() where get_queue blocks before returning.
        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
            currentSeq: nil,
            message: .commandResult(
                command: "get_queue", requestId: "req-q",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "get_queue waiter should be resolved eagerly by routeStreamMessage")
    }

    @MainActor
    @Test func routeStreamMessageDoesNotEagerlyResolveNonSetupCommands() {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let pending = PendingCommand(command: "set_model", requestId: "req-m")
        conn.commands.registerCommand(pending)

        _ = AsyncStream<ServerMessage> { continuation in
            conn.sessionContinuations["s1"] = continuation
        }

        let streamMsg = StreamMessage(
            sessionId: "s1",
            streamSeq: 1,
            seq: nil,
            currentSeq: nil,
            message: .commandResult(
                command: "set_model", requestId: "req-m",
                success: true, data: nil, error: nil
            )
        )
        conn.routeStreamMessage(streamMsg)

        #expect(conn.commands.pendingCommandsByRequestId["req-m"] != nil,
                "Non-setup commands should not be resolved eagerly by routeStreamMessage")
    }

    // MARK: - streamSession timing budget (regression gate)

    /// Integration test: streamSession() must complete within a tight time budget.
    ///
    /// Regression gate for the 8s delay bug where:
    /// 1. get_queue command_result was not eagerly resolved in routeStreamMessage
    /// 2. waitForConnectionTimeout was bumped from 3s to 8s
    ///
    /// The mock simulates instant server responses — any delay beyond a
    /// few hundred ms means the setup path is blocking on something it shouldn't.
    @MainActor
    @Test func streamSessionCompletesWithinTimeBudget() async {
        let conn = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)

        // Keep consumption task alive so connectStream() is a no-op
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }

        // Mock send: intercept outgoing commands and simulate server responses
        conn._sendMessageForTesting = { [weak conn] message in
            guard let conn else { return }
            let typeLabel = message.typeLabel

            // Extract requestId via JSON round-trip (no pattern matching on associated values)
            let requestId: String? = {
                guard let data = try? JSONEncoder().encode(message),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return dict["requestId"] as? String
            }()

            guard let requestId else { return }

            let response = StreamMessage(
                sessionId: "s1",
                streamSeq: 1,
                seq: nil,
                currentSeq: nil,
                message: .commandResult(
                    command: typeLabel,
                    requestId: requestId,
                    success: true,
                    data: nil,
                    error: nil
                )
            )
            conn.routeStreamMessage(response)
        }

        let start = ContinuousClock.now
        let stream = await conn.streamSession("s1", workspaceId: "w1")
        let elapsed = ContinuousClock.now - start

        #expect(stream != nil, "streamSession should return a stream")
        #expect(elapsed < .seconds(2),
                "streamSession should complete within 2s budget, took \(elapsed) — check eager command resolution and waitForConnection")

        conn.streamConsumptionTask?.cancel()
    }

    /// Regression gate: if get_queue never returns command_result (older server
    /// behavior during full-subscription races), streamSession must remain
    /// non-blocking and return quickly while queue sync retries in background.
    @MainActor
    @Test func streamSessionDoesNotBlockOnMissingGetQueueAck() async {
        let conn = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)

        // Keep consumption task alive so connectStream() is a no-op
        conn.streamConsumptionTask = Task { try? await Task.sleep(for: .seconds(60)) }

        conn._sendMessageForTesting = { [weak conn] message in
            guard let conn else { return }
            guard message.typeLabel == "subscribe" else {
                // Simulate missing get_queue command_result (legacy server race)
                return
            }

            let requestId: String? = {
                guard let data = try? JSONEncoder().encode(message),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return dict["requestId"] as? String
            }()

            guard let requestId else { return }
            conn.routeStreamMessage(
                StreamMessage(
                    sessionId: "s1",
                    streamSeq: 1,
                    seq: nil,
                    currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe",
                        requestId: requestId,
                        success: true,
                        data: nil,
                        error: nil
                    )
                )
            )
        }

        let start = ContinuousClock.now
        let stream = await conn.streamSession("s1", workspaceId: "w1")
        let elapsed = ContinuousClock.now - start

        #expect(stream != nil, "streamSession should still return a stream")
        #expect(
            elapsed < .seconds(1),
            "streamSession should not block on queue sync and should return in <1s when get_queue ack is missing; took \(elapsed)"
        )

        conn.streamConsumptionTask?.cancel()
        conn.disconnectSession()
    }

    // MARK: - Pending unsubscribe cancelled on resubscribe

    @MainActor
    @Test func pendingUnsubscribeCancelledWhenReenteringSameSession() {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        conn.disconnectSession()

        #expect(conn.pendingUnsubscribeTasks["s1"] != nil,
                "disconnectSession should track pending unsubscribe")

        if let pendingUnsub = conn.pendingUnsubscribeTasks.removeValue(forKey: "s1") {
            pendingUnsub.cancel()
        }

        #expect(conn.pendingUnsubscribeTasks["s1"] == nil,
                "Pending unsubscribe should be cancelled before resubscribe")
    }

    @MainActor
    @Test func disconnectStreamCancelsPendingUnsubscribes() {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        conn.disconnectSession()
        #expect(!conn.pendingUnsubscribeTasks.isEmpty)

        conn.disconnectStream()
        #expect(conn.pendingUnsubscribeTasks.isEmpty,
                "disconnectStream should cancel all pending unsubscribes")
    }

    // MARK: - Pre-track subscription for inbound meta

    @MainActor
    @Test func subscribePreTracksActiveSubscriptionSynchronously() throws {
        let conn = makeTestConnection()
        let ws = try #require(conn.wsClient)

        // Before pre-track: no subscription
        #expect(ws._activeSubscriptionForTesting("pre-track-session") == nil)

        // Simulate what send() does: pre-track synchronously
        ws._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "pre-track-session", level: .full, requestId: "r1")
        )

        #expect(
            ws._activeSubscriptionForTesting("pre-track-session") == .full,
            "preTrackSubscription should set activeSubscriptions synchronously before the actual send, so the receive loop meta guard passes for the server's immediate response"
        )
    }

    @MainActor
    @Test func subscribePreTrackRolledBackOnFailure() throws {
        let conn = makeTestConnection()
        let ws = try #require(conn.wsClient)

        // Pre-track then rollback (simulates send failure path)
        ws._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "rollback-session", level: .full, requestId: "r1")
        )
        #expect(ws._activeSubscriptionForTesting("rollback-session") == .full)

        ws._rollbackPreTrackSubscriptionForTesting(
            .subscribe(sessionId: "rollback-session", level: .full, requestId: "r1")
        )
        #expect(
            ws._activeSubscriptionForTesting("rollback-session") == nil,
            "rollbackPreTrackSubscription should remove the pre-tracked subscription"
        )
    }

    @MainActor
    @Test func preTrackIsNoOpForNonSubscribeMessages() throws {
        let conn = makeTestConnection()
        let ws = try #require(conn.wsClient)

        // Pre-track with a non-subscribe message should be a no-op
        ws._preTrackSubscriptionForTesting(
            .unsubscribe(sessionId: "some-session", requestId: "r1")
        )
        #expect(ws._activeSubscriptionForTesting("some-session") == nil)
    }
}
