import Testing
import Foundation
@testable import Oppi

/// Tests for WS reconnect + recovery behaviors in SessionStreamCoordinator.
///
/// Covers: deferred queue sync cancellation on reconnect, queue sync
/// re-scheduling after resubscription, recovery queue refresh, and
/// transition table acceptance of streamConnected in mid-recovery states.
@Suite("ServerConnection Reconnect")
struct ServerConnectionReconnectTests {

    // MARK: - handleStreamReconnected cancels deferred queue sync

    @MainActor
    @Test func reconnectCancelsDeferredQueueSync() async {
        let (conn, pipe) = makeTestConnection()

        // Plant a long-running deferred queue sync task and capture its identity
        let staleTask: Task<Void, Never> = Task {
            try? await Task.sleep(for: .seconds(60))
        }
        conn.deferredQueueSyncTask = staleTask
        #expect(conn.deferredQueueSyncTask != nil)

        // Mock: ack subscribe commands (don't ack get_queue — we only care
        // that the stale task was cancelled, not that a new one completes)
        conn._sendMessageForTesting = { message in
            if case .subscribe(let sessionId, _, _, let requestId) = message {
                conn.routeStreamMessage(StreamMessage(
                    sessionId: sessionId,
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))
            }
        }

        // Fire stream_connected → handleStreamReconnected()
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test")
        ))

        // The ORIGINAL stale task should be cancelled
        let cancelled = await waitForTestCondition(timeoutMs: 1_500) {
            staleTask.isCancelled
        }
        #expect(cancelled, "handleStreamReconnected should cancel the stale deferred queue sync before resubscribing")
    }

    // MARK: - Resubscription schedules new queue sync

    @MainActor
    @Test func reconnectSchedulesQueueSyncAfterResubscription() async {
        let (conn, pipe) = makeTestConnection()
        let getQueueCounter = MessageCounter()

        // Mock: ack subscribe, count get_queue sends
        conn._sendMessageForTesting = { message in
            switch message {
            case .subscribe(let sessionId, _, _, let requestId):
                conn.routeStreamMessage(StreamMessage(
                    sessionId: sessionId,
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))

            case .getQueue(let requestId):
                await getQueueCounter.increment()
                // Ack the get_queue so the sync completes
                conn.routeStreamMessage(StreamMessage(
                    sessionId: "s1",
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "get_queue", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))

            default:
                break
            }
        }

        // Fire stream_connected → resubscribe → scheduleQueueSync
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test")
        ))

        // get_queue should be sent after successful resubscription
        let sent = await waitForTestCondition(timeoutMs: 3_000) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent, "After resubscription, a new queue sync should be scheduled and send get_queue")
    }

    // MARK: - Transition table: streamConnected accepted in resubscribing

    @MainActor
    @Test func coordinatorAcceptsStreamConnectedWhileResubscribing() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()

        // Mock: ack subscribe commands
        conn._sendMessageForTesting = { message in
            if case .subscribe(let sessionId, _, _, let requestId) = message {
                await subscribeCounter.increment()
                conn.routeStreamMessage(StreamMessage(
                    sessionId: sessionId,
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))
            }
        }

        // First reconnect
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test")
        ))

        // Wait for first resubscribe to complete
        let firstDone = await waitForTestCondition(timeoutMs: 2_000) {
            await subscribeCounter.count() >= 1
        }
        #expect(firstDone)

        // Second reconnect (WS dropped again immediately)
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test")
        ))

        // Second resubscribe should also succeed
        let secondDone = await waitForTestCondition(timeoutMs: 2_000) {
            await subscribeCounter.count() >= 2
        }
        #expect(secondDone, "Coordinator should accept streamConnected while resubscribing/streaming and handle it normally")

        // Coordinator should end in streaming or queueSync (queue sync is
        // the final async step after resubscription succeeds)
        let state = conn.sessionStreamCoordinator.state
        switch state {
        case .streaming(sessionId: "s1"),
             .queueSync(sessionId: "s1", phase: _):
            break // Expected — both indicate successful double-reconnect
        default:
            Issue.record("After double reconnect, expected streaming or queueSync for s1, got \(state)")
        }
    }

    // MARK: - Stale queue sync doesn't send get_queue before resubscribe

    /// Regression test: before the fix, a deferred queue sync task from the
    /// original streamSession() would survive a WS reconnect and send get_queue
    /// on the new WS before resubscription completed — hitting the server's
    /// "not subscribed at level=full" error.
    @MainActor
    @Test func staleQueueSyncDoesNotRaceAheadOfResubscribe() async {
        let (conn, pipe) = makeTestConnection()
        let commandOrder = CommandOrderTracker()

        // Plant a deferred queue sync that would fire soon
        conn.deferredQueueSyncTask = Task { @MainActor [weak conn] in
            guard let conn else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            // This simulates what scheduleQueueSync does
            try? await conn.requestMessageQueue(timeout: .seconds(1))
        }

        // Mock: track command order, ack everything
        conn._sendMessageForTesting = { message in
            let command = message.typeLabel
            await commandOrder.record(command)

            switch message {
            case .subscribe(let sessionId, _, _, let requestId):
                conn.routeStreamMessage(StreamMessage(
                    sessionId: sessionId,
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))
            case .getQueue(let requestId):
                conn.routeStreamMessage(StreamMessage(
                    sessionId: "s1",
                    streamSeq: nil, seq: nil, currentSeq: nil,
                    message: .commandResult(
                        command: "get_queue", requestId: requestId,
                        success: true, data: nil, error: nil
                    )
                ))
            default:
                break
            }
        }

        // Reconnect — should cancel stale task before resubscribing
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test")
        ))

        // Wait for both subscribe and get_queue to complete
        let bothSent = await waitForTestCondition(timeoutMs: 3_000) {
            let cmds = await commandOrder.commands()
            return cmds.contains("subscribe") && cmds.contains("get_queue")
        }
        #expect(bothSent, "Both subscribe and get_queue should be sent")

        // Verify subscribe always comes before get_queue
        let commands = await commandOrder.commands()
        let subscribeIndex = commands.firstIndex(of: "subscribe")
        let getQueueIndex = commands.firstIndex(of: "get_queue")
        if let si = subscribeIndex, let gi = getQueueIndex {
            #expect(si < gi,
                    "subscribe must come before get_queue — got order: \(commands)")
        }
    }
}

// MARK: - Test Doubles

private actor CommandOrderTracker {
    private var log: [String] = []

    func record(_ command: String) {
        log.append(command)
    }

    func commands() -> [String] {
        log
    }
}
