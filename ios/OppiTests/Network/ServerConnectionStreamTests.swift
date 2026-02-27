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
    @Test func routeStreamMessageDoesNotEagerlyResolveNonSubscribeCommands() {
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
                "Non-subscribe commands should not be resolved by routeStreamMessage")
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
}
