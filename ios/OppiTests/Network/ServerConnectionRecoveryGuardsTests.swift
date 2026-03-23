import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Recovery Guards")
struct ServerConnectionRecoveryGuardsTests {

    actor RecoveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen {
                return
            }

            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    @Test func streamReconnectRetriesWhenSubscribeAckFails() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()

        conn._sendMessageForTesting = { message in
            guard case .subscribe(let sessionId, let level, _, let requestId) = message else {
                return
            }

            await subscribeCounter.increment()
            let attempt = await subscribeCounter.count()

            #expect(sessionId == "s1")
            #expect(level == .full)

            guard let requestId else {
                Issue.record("Expected subscribe requestId for retryable resubscribe")
                return
            }

            let success = attempt > 1
            conn.routeStreamMessage(
                StreamMessage(
                    sessionId: sessionId,
                    streamSeq: nil,
                    seq: nil,
                    currentSeq: nil,
                    message: .commandResult(
                        command: "subscribe",
                        requestId: requestId,
                        success: success,
                        data: nil,
                        error: success ? nil : "subscribe rejected"
                    )
                )
            )
        }

        conn.routeStreamMessage(
            StreamMessage(
                sessionId: nil,
                streamSeq: nil,
                seq: nil,
                currentSeq: nil,
                message: .streamConnected(userName: "tester")
            )
        )

        #expect(
            await waitForTestCondition(timeoutMs: 2_500) {
                await subscribeCounter.count() == 2
            },
            "Resubscribe must wait for subscribe ACK and retry on command_result failure"
        )
    }

    @MainActor
    @Test func typedMissingFullSubscriptionCodeTriggersRecovery() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()

        conn._sendMessageForTesting = { message in
            guard case .subscribe(let sessionId, let level, _, let requestId) = message else {
                return
            }

            await subscribeCounter.increment()
            #expect(sessionId == "s1")
            #expect(level == .full)

            pipe.handle(
                .commandResult(
                    command: "subscribe",
                    requestId: requestId,
                    success: true,
                    data: nil,
                    error: nil
                ),
                sessionId: sessionId
            )
        }

        pipe.handle(
            .error(
                message: "server wording changed",
                code: ServerConnection.missingFullSubscriptionErrorCode,
                fatal: false
            ),
            sessionId: "s1"
        )

        #expect(await waitForTestCondition(timeoutMs: 500) { await subscribeCounter.count() == 1 })

        // With per-session reducers, timeline items are on ChatSessionManager,
        // not ServerConnection. The important invariant is that the recovery
        // path was triggered (verified by the subscribe count above).
    }

    @MainActor
    @Test func triggerFullSubscriptionRecoverySkipsWhenRecoveryAlreadyInFlight() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()
        let gate = RecoveryGate()

        conn._sendMessageForTesting = { message in
            guard case .subscribe(let sessionId, let level, _, let requestId) = message else {
                return
            }

            await subscribeCounter.increment()
            #expect(sessionId == "s1")
            #expect(level == .full)

            await gate.wait()

            pipe.handle(
                .commandResult(
                    command: "subscribe",
                    requestId: requestId,
                    success: true,
                    data: nil,
                    error: nil
                ),
                sessionId: sessionId
            )
        }

        conn.triggerFullSubscriptionRecovery(sessionId: "s1", serverError: "first")
        conn.triggerFullSubscriptionRecovery(sessionId: "s1", serverError: "second")

        #expect(await waitForTestCondition(timeoutMs: 500) { await subscribeCounter.count() == 1 })

        await gate.open()

        #expect(
            await waitForTestCondition(timeoutMs: 500) {
                await MainActor.run { conn.fullSubscriptionRecoveryTask == nil }
            },
            "Recovery task should complete and clear in-flight guard"
        )
    }

    @MainActor
    @Test func triggerFullSubscriptionRecoveryRespectsCooldown() async {
        let (conn, pipe) = makeTestConnection()
        let subscribeCounter = MessageCounter()

        conn.lastFullSubscriptionRecoveryAt = Date()
        conn._sendMessageForTesting = { message in
            if case .subscribe = message {
                await subscribeCounter.increment()
            }
        }

        conn.triggerFullSubscriptionRecovery(sessionId: "s1", serverError: "cooldown")

        #expect(await waitForTestCondition(timeoutMs: 300) { await subscribeCounter.count() == 0 })
        #expect(conn.fullSubscriptionRecoveryTask == nil)
    }
}
