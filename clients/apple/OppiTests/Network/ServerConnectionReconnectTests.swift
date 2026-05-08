import Testing
import Foundation
@testable import Oppi

/// Tests for focused session stream reconnect + queue recovery behavior.
@Suite("ServerConnection Reconnect")
@MainActor
struct ServerConnectionReconnectTests {

    // MARK: - handleStreamReconnected cancels deferred queue sync

    @Test func reconnectCancelsDeferredQueueSync() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")

        let staleTask: Task<Void, Never> = Task {
            try? await Task.sleep(for: .seconds(60))
        }
        conn.deferredQueueSyncTask = staleTask
        #expect(conn.deferredQueueSyncTask != nil)
        conn._sendMessageForTesting = { _ in }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let cancelled = await waitForTestCondition(timeoutMs: 1_500) {
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
                streamSeq: nil, seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let sent = await waitForTestCondition(timeoutMs: 3_000) {
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
                streamSeq: nil, seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let sent = await waitForTestCondition(timeoutMs: 3_000) {
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

    @Test func reconnectMarksFocusedSessionFullWithoutLegacySubscribe() async {
        let (conn, _) = makeTestConnection()
        conn.setFocusedSessionStreamEndpointKindForTesting("split_session")
        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        conn.sessionStore.upsert(makeTestSession(id: "s2", workspaceId: "w1", status: .busy))
        conn.focusSession("s2")
        conn.subscriptionRegistry.setDesired(.full, for: "s1")
        conn.subscriptionRegistry.setDesired(.full, for: "s2")

        var sentTypes: [String] = []
        conn._sendMessageForTesting = { message in
            sentTypes.append(message.typeLabel)
            if case .getQueue(let requestId) = message {
                conn.routeStreamMessage(StreamMessage(
                    sessionId: "s2",
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "get_queue", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))
            }
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        #expect(await conn.waitForFocusedFullSubscription(sessionId: "s2", timeout: .milliseconds(100)))
        #expect(!sentTypes.contains("subscribe"))
        #expect(conn.subscriptionRegistry.sessionIds(acked: .full) == ["s2"])
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
                streamSeq: nil, seq: nil, currentSeq: nil,
                message: .commandResult(
                    command: "get_queue", requestId: requestId,
                    success: true, data: nil, error: nil
                )
            ))
        }

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let cancelled = await waitForTestCondition(timeoutMs: 1_500) {
            staleTask.isCancelled
        }
        #expect(cancelled)
        let sent = await waitForTestCondition(timeoutMs: 3_000) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent, "Fresh reconnect queue sync should still run after stale task cancellation")
    }
}
