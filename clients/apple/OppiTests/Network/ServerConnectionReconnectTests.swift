import Testing
import Foundation
@testable import Oppi

/// Tests for WS reconnect + recovery behaviors in SessionStreamCoordinator.
///
/// Covers: deferred queue sync cancellation on reconnect, queue sync
/// re-scheduling after resubscription, recovery queue refresh, and
/// transition table acceptance of streamConnected in mid-recovery states.
@Suite("ServerConnection Reconnect")
@MainActor
struct ServerConnectionReconnectTests {

    // MARK: - handleStreamReconnected cancels deferred queue sync

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
            if case .subscribe(let sessionId, _, _, let requestId, _) = message {
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
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        // The ORIGINAL stale task should be cancelled
        let cancelled = await waitForTestCondition(timeoutMs: 1_500) {
            staleTask.isCancelled
        }
        #expect(cancelled, "handleStreamReconnected should cancel the stale deferred queue sync before resubscribing")
    }

    // MARK: - Resubscription schedules new queue sync

    @Test func reconnectSchedulesQueueSyncAfterResubscription() async {
        let (conn, pipe) = makeTestConnection()
        let getQueueCounter = MessageCounter()

        // Mock: ack subscribe, count get_queue sends
        conn._sendMessageForTesting = { message in
            switch message {
            case .subscribe(let sessionId, _, _, let requestId, _):
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
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        // get_queue should be sent after successful resubscription
        let sent = await waitForTestCondition(timeoutMs: 3_000) {
            await getQueueCounter.count() >= 1
        }
        #expect(sent, "After resubscription, a new queue sync should be scheduled and send get_queue")
    }

    // MARK: - Transition table: streamConnected accepted in resubscribing

    @Test func coordinatorAcceptsStreamConnectedWhileResubscribing() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()

        // Mock: ack subscribe commands
        conn._sendMessageForTesting = { message in
            if case .subscribe(let sessionId, _, _, let requestId, _) = message {
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
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        // Wait for first resubscribe to complete
        let firstDone = await waitForTestCondition(timeoutMs: 2_000) {
            await subscribeCounter.count() >= 1
        }
        #expect(firstDone)

        // Second reconnect (WS dropped again immediately)
        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
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

    // MARK: - Reconnect restores all tracked subscriptions

    @Test func reconnectResubscribesAllDesiredFullSessions() async {
        let (conn, _) = makeTestConnection()
        let subscribeRecorder = SubscribeRecorder()

        conn.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        conn.sessionStore.upsert(makeTestSession(id: "s2", workspaceId: "w1", status: .busy))
        conn.focusSession("s2")
        conn.subscriptionRegistry.setDesired(.full, for: "s1")
        conn.subscriptionRegistry.setDesired(.full, for: "s2")

        conn._sendMessageForTesting = { message in
            switch message {
            case .subscribe(let sessionId, let level, _, let requestId, _):
                await subscribeRecorder.record(sessionId: sessionId, level: level)
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
                    sessionId: "s2",
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

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let resubscribed = await waitForTestCondition(timeoutMs: 2_000) {
            await subscribeRecorder.sessions(level: .full).count == 2
        }
        #expect(resubscribed)
        let fullSessions = await subscribeRecorder.sessions(level: .full)
        #expect(fullSessions == ["s2", "s1"],
                "Reconnect must restore focused full session first, then background full subscriptions")
    }

    @Test func reconnectResubscribesNotificationSessionsByRecentActivity() async {
        let (conn, _) = makeTestConnection(sessionId: "focus")
        let subscribeRecorder = SubscribeRecorder()

        conn.sessionStore.upsert(makeTestSession(id: "focus", workspaceId: "w1", status: .busy))
        conn.focusSession("focus")

        for index in 1...25 {
            let sessionId = "n\(index)"
            conn.sessionStore.upsert(makeTestSession(
                id: sessionId,
                workspaceId: "w1",
                status: .busy,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(index))
            ))
            conn.subscriptionRegistry.setDesired(.notifications, for: sessionId)
        }

        conn._sendMessageForTesting = { message in
            switch message {
            case .subscribe(let sessionId, let level, _, let requestId, _):
                await subscribeRecorder.record(sessionId: sessionId, level: level)
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
                    sessionId: "focus",
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

        conn.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .streamConnected(userName: "test", asrAvailable: false)
        ))

        let expected = (6...25).reversed().map { "n\($0)" }
        let resubscribed = await waitForTestCondition(timeoutMs: 3_000) {
            await subscribeRecorder.sessions(level: .notifications).count == expected.count
        }
        #expect(resubscribed)
        let notificationSessions = await subscribeRecorder.sessions(level: .notifications)
        #expect(notificationSessions == expected,
                "Reconnect should spend notification slots on the 20 most recent sessions in deterministic order")
    }

    @Test func notificationSyncClearsFailedDesiredEntriesOutsideRecentWindow() async {
        let (conn, _) = makeTestConnection(sessionId: "focus")
        conn.sessionStore.upsert(makeTestSession(id: "focus", workspaceId: "w1", status: .busy))
        conn.focusSession("focus")
        conn.subscriptionRegistry.setDesired(.notifications, for: "stale")
        conn.subscriptionRegistry.markSubscribeSent(sessionId: "stale", requestId: "stale-r1", level: .notifications)
        conn.subscriptionRegistry.markSubscribeFailed(sessionId: "stale", requestId: "stale-r1", reason: "network")

        await conn.sessionStreamCoordinator.syncNotificationSubscriptions(connection: conn)

        #expect(conn.subscriptionRegistry.desiredLevel(for: "stale") == .none,
                "Failed notification subscriptions outside the recent window must not poison reconnect slots forever")
        #expect(conn.subscriptionRegistry.ackState(for: "stale") == .idle)
    }

    // MARK: - Stale queue sync doesn't send get_queue before resubscribe

    /// Regression test: before the fix, a deferred queue sync task from the
    /// original streamSession() would survive a WS reconnect and send get_queue
    /// on the new WS before resubscription completed — hitting the server's
    /// "not subscribed at level=full" error.
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
            case .subscribe(let sessionId, _, _, let requestId, _):
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
            message: .streamConnected(userName: "test", asrAvailable: false)
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

private actor SubscribeRecorder {
    private var log: [(sessionId: String, level: StreamSubscriptionLevel)] = []

    func record(sessionId: String, level: StreamSubscriptionLevel) {
        log.append((sessionId, level))
    }

    func sessions(level: StreamSubscriptionLevel) -> [String] {
        log.compactMap { entry in
            entry.level == level ? entry.sessionId : nil
        }
    }
}
