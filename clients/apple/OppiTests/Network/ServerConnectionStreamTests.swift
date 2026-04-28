import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Stream")
@MainActor
struct ServerConnectionStreamTests {

    // MARK: - connectStream idempotency

    @Test func connectStreamIsIdempotentWhileActive() {
        let (conn, _) = makeTestConnection()

        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel
        conn.wsClient?._setStatusForTesting(.connected)

        conn.connectStream()

        #expect(!sentinel.isCancelled,
                "Should not cancel existing task when one is active and WS is connected")
    }

    @Test func connectStreamSkipsWhenWSAlreadyConnectedAndNoTask() {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.connected)
        // No consumption task — would normally trigger wsClient.connect()
        conn.streamConsumptionTask = nil

        conn.connectStream()

        // Should NOT have started a new connection — the WS is healthy.
        // wsClient.connect() would have reset status to .connecting.
        #expect(conn.wsClient?.status == .connected,
                "connectStream should not tear down a healthy WS")
    }

    @Test func connectStreamRestartsWhenTaskExistsButWSDisconnected() {
        let (conn, _) = makeTestConnection()

        conn.streamConsumptionTask = Task { }
        conn.wsClient?._setStatusForTesting(.disconnected)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create new task when WS is disconnected")
    }

    @Test func connectStreamCreatesTaskWhenNil() {
        let (conn, _) = makeTestConnection()

        #expect(conn.streamConsumptionTask == nil)

        conn.connectStream()

        #expect(conn.streamConsumptionTask != nil,
                "Should create task when none exists")
    }

    // MARK: - streamConsumptionTask self-cleanup

    @Test func consumptionTaskNilsItselfWhenStreamEnds() async {
        let (conn, _) = makeTestConnection()

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

    @Test func disconnectStreamCleansUpEverything() {
        let (conn, _) = makeTestConnection()
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

    @Test func streamConnectedMessageTriggersResubscribe() {
        let (conn, _) = makeTestConnection()
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
            message: .streamConnected(userName: "test", asrAvailable: false)
        )
        conn.routeStreamMessage(streamMsg)

        #expect(!yieldedToSession,
                "stream_connected should be handled at stream level, not yielded to sessions")
        consumeTask.cancel()
    }

    // MARK: - routeStreamMessage routing

    @Test func routeStreamMessageYieldsToSessionContinuation() async {
        let (conn, _) = makeTestConnection()
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

    @Test func routeStreamMessageYieldsSessionEventWithMetadata() async {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        var receivedEvents: [SessionStreamEvent] = []
        let stream = AsyncStream<SessionStreamEvent> { continuation in
            conn.sessionEventContinuations["s1"] = continuation
        }

        let consumeTask = Task {
            for await event in stream {
                await MainActor.run { receivedEvents.append(event) }
            }
        }

        conn.routeStreamMessage(StreamFrameEvent(
            sessionId: "s1",
            message: .agentStart,
            meta: InboundStreamMeta(
                seq: 42,
                currentSeq: 45,
                receivedAtMs: 123,
                transportPath: .lan
            )
        ))

        let received = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !receivedEvents.isEmpty }
        }

        consumeTask.cancel()

        #expect(received, "Message should be yielded to event continuation")
        #expect(receivedEvents.first?.sessionId == "s1")
        #expect(receivedEvents.first?.meta?.seq == 42)
        #expect(receivedEvents.first?.meta?.currentSeq == 45)
        #expect(receivedEvents.first?.meta?.transportPath == .lan)
    }

    // MARK: - reconnectIfNeeded restarts dead stream

    @Test func reconnectIfNeededRestartsDeadStream() async {
        let (conn, _) = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.disconnected)
        conn.streamConsumptionTask = nil

        #expect(conn.streamConsumptionTask == nil)

        await conn.reconnectIfNeeded()

        #expect(conn.streamConsumptionTask != nil,
                "reconnectIfNeeded should restart a dead stream")
    }

    @Test func reconnectIfNeededSkipsAliveStream() async {
        let (conn, _) = makeTestConnection()

        conn.wsClient?._setStatusForTesting(.connected)
        let sentinel = Task<Void, Never> { }
        conn.streamConsumptionTask = sentinel

        await conn.reconnectIfNeeded()

        #expect(!sentinel.isCancelled,
                "Should not replace an active consumption task")
    }

    // MARK: - routeStreamMessage resolves command waiters at stream boundary

    @Test func routeStreamMessageResolvesSubscribeWaiterBeforePerSessionRouting() async {
        let (conn, _) = makeTestConnection()
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

    @Test func routeStreamMessageResolvesGetQueueWaiterEagerly() async {
        let (conn, _) = makeTestConnection()
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

    @Test func routeStreamMessageResolvesNonSetupCommandAtBoundary() async {
        let (conn, _) = makeTestConnection()
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

        let result = try? await pending.waiter.wait()
        #expect(result != nil, "All requestId command results should resolve at stream boundary")
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
    @Test func streamSessionCompletesWithinTimeBudget() async {
        let (conn, _) = makeTestConnection()
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
    @Test func streamSessionDoesNotBlockOnMissingGetQueueAck() async {
        let (conn, _) = makeTestConnection()
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

    @Test func pendingUnsubscribeCancelledWhenReenteringSameSession() {
        let (conn, _) = makeTestConnection()
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

    @Test func disconnectStreamCancelsPendingUnsubscribes() {
        let (conn, _) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        conn.disconnectSession()
        #expect(!conn.pendingUnsubscribeTasks.isEmpty)

        conn.disconnectStream()
        #expect(conn.pendingUnsubscribeTasks.isEmpty,
                "disconnectStream should cancel all pending unsubscribes")
    }

}
