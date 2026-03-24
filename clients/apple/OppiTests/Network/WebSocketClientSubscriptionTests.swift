import Foundation
import Testing
@testable import Oppi

// MARK: - Subscription Tracking

@Suite("WebSocket Subscription Tracking")
@MainActor
struct WebSocketClientSubscriptionTrackingTests {

    @Test func preTrackSetsSubscriptionForSubscribeMessage() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        let msg = ClientMessage.subscribe(sessionId: "s1", level: .full, requestId: "r1")

        client._preTrackSubscriptionForTesting(msg)

        #expect(client._activeSubscriptionForTesting("s1") == .full)
    }

    @Test func preTrackIgnoresNonSubscribeMessages() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(.getState())
        client._preTrackSubscriptionForTesting(.stop())
        client._preTrackSubscriptionForTesting(
            .unsubscribe(sessionId: "s1", requestId: "r1")
        )

        #expect(client.activeSubscriptions.isEmpty)
    }

    @Test func preTrackReplacesExistingSubscriptionLevel() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .notifications, requestId: "r1")
        )
        #expect(client._activeSubscriptionForTesting("s1") == .notifications)

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r2")
        )
        #expect(client._activeSubscriptionForTesting("s1") == .full)
    }

    @Test func rollbackRemovesSubscription() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        #expect(client._activeSubscriptionForTesting("s1") == .full)

        client._rollbackPreTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        #expect(client._activeSubscriptionForTesting("s1") == nil)
    }

    @Test func rollbackIgnoresNonSubscribeMessages() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        client._rollbackPreTrackSubscriptionForTesting(.getState())
        client._rollbackPreTrackSubscriptionForTesting(.stop())
        client._rollbackPreTrackSubscriptionForTesting(
            .unsubscribe(sessionId: "s1", requestId: "r1")
        )

        #expect(client._activeSubscriptionForTesting("s1") == .full)
    }

    @Test func rollbackForSessionADoesNotAffectSessionB() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s2", level: .full, requestId: "r2")
        )

        client._rollbackPreTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        #expect(client._activeSubscriptionForTesting("s1") == nil)
        #expect(client._activeSubscriptionForTesting("s2") == .full)
    }

    /// BUG PROBE: If a session was previously subscribed at .notifications,
    /// then an upgrade to .full is pre-tracked and rolled back (send failure),
    /// the rollback removes the subscription entirely instead of restoring
    /// the previous .notifications level.
    ///
    /// In the reconnect path this creates a window where the receive loop's
    /// meta guard (activeSubscriptions[sessionId] == .full) rejects incoming
    /// messages. The previous subscription level is permanently lost.
    ///
    /// This is somewhat "by design" since on reconnect the old WS subscription
    /// is dead anyway, but activeSubscriptions briefly misrepresents the state
    /// that cancelReconnectBackoff/attemptReconnect explicitly preserved.
    @Test func rollbackErasesPreExistingSubscriptionLevel() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .notifications, requestId: "r1")
        )
        #expect(client._activeSubscriptionForTesting("s1") == .notifications)

        // Attempt upgrade to .full (pre-track overwrites)
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r2")
        )
        #expect(client._activeSubscriptionForTesting("s1") == .full)

        // Send fails, rollback fires
        client._rollbackPreTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r2")
        )

        // FINDING: Rollback removes the key entirely. The previous .notifications
        // level is not restored. preTrackSubscription doesn't save/restore prior state.
        #expect(
            client._activeSubscriptionForTesting("s1") == nil,
            "Rollback removes subscription entirely, losing the prior .notifications level"
        )
    }

    @Test func multipleSessionsTrackedIndependently() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s2", level: .notifications, requestId: "r2")
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s3", level: .full, requestId: "r3")
        )

        #expect(client.activeSubscriptions.count == 3)
        #expect(client._activeSubscriptionForTesting("s1") == .full)
        #expect(client._activeSubscriptionForTesting("s2") == .notifications)
        #expect(client._activeSubscriptionForTesting("s3") == .full)
    }

    @Test func disconnectClearsAllSubscriptions() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s2", level: .notifications, requestId: "r2")
        )

        client.disconnect()

        #expect(client.activeSubscriptions.isEmpty)
    }
}

// MARK: - Connection Waiters

@Suite("WebSocket Connection Waiters")
@MainActor
struct WebSocketClientConnectionWaiterTests {

    @Test func sendFromDisconnectedFailsImmediately() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(5)
        )
        client._setStatusForTesting(.disconnected)

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Send should have thrown from disconnected state")
        } catch {
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1), "Disconnected send should fail immediately")
        }
    }

    @Test func sendFromReconnectingResolvesOnConnectedStatus() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(10)
        )
        client._setStatusForTesting(.reconnecting(attempt: 1))

        let start = ContinuousClock.now

        let sendTask = Task {
            do {
                try await client.send(.getState())
            } catch {
                // Expected — no real WebSocket
            }
        }

        // Give send() time to enter waitForConnection and suspend
        try? await Task.sleep(for: .milliseconds(50))

        // Resolve waiters by transitioning to connected
        client._setStatusForTesting(.connected)

        await sendTask.value
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(2), "Waiter should resolve on status change, not hit 10s timeout")
    }

    @Test func multipleConcurrentSendsAllResolveOnStatusChange() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(10)
        )
        client._setStatusForTesting(.reconnecting(attempt: 1))

        let start = ContinuousClock.now

        let tasks = (0..<5).map { _ in
            Task {
                do {
                    try await client.send(.getState())
                } catch {
                    // Expected — no real WebSocket
                }
            }
        }

        // Give all sends time to register as waiters
        try? await Task.sleep(for: .milliseconds(100))

        // One status change should resolve all 5 waiters at once
        client._setStatusForTesting(.connected)

        for task in tasks {
            await task.value
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(2), "All 5 waiters should resolve together")
    }

    @Test func sendFromConnectedBypassesWaiterAndHitsGuard() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(10)
        )
        client._setStatusForTesting(.connected)

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Send should throw — no real WebSocket task")
        } catch {
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1), "Connected status should skip waiter entirely")
        }
    }

    /// Rapid status toggles: connected -> disconnected -> connected.
    /// Waiters resolve exactly once on the first transition that calls
    /// resolveConnectionWaiters(). Subsequent transitions find an empty
    /// waiter map and safely no-op. No double-resume should occur.
    @Test func rapidStatusToggleResolvesWaitersExactlyOnce() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(10)
        )
        client._setStatusForTesting(.reconnecting(attempt: 1))

        let sendTask = Task {
            do {
                try await client.send(.getState())
            } catch {
                // Expected
            }
        }

        try? await Task.sleep(for: .milliseconds(50))

        // Rapid toggles. First .connected resolves all waiters.
        // Subsequent calls find no waiters and are safe no-ops.
        client._setStatusForTesting(.connected)
        client._setStatusForTesting(.disconnected)
        client._setStatusForTesting(.connected)

        // Completing without crash proves no double-resume occurred
        await sendTask.value
    }
}

// MARK: - Inbound Meta Queue

@Suite("WebSocket Inbound Meta Queue")
@MainActor
struct WebSocketClientInboundMetaTests {

    @Test func consumeReturnsNilForNeverSubscribedSession() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        let meta = client.consumeInboundMeta(sessionId: "nonexistent")

        #expect(meta == nil, "Should return nil without crashing for unknown session")
    }

    @Test func consumeReturnsNilAfterPreTrackClears() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        #expect(client.consumeInboundMeta(sessionId: "s1") == nil)
    }

    @Test func consumeReturnsNilAfterDisconnect() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        client.disconnect()

        #expect(client.consumeInboundMeta(sessionId: "s1") == nil)
    }

    @Test func resubscribeClearsMetaQueueViaPreTrack() {
        let client = WebSocketClient(credentials: makeTestCredentials())

        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        // Resubscribe — preTrack clears any accumulated meta for a fresh start
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r2")
        )

        #expect(client.consumeInboundMeta(sessionId: "s1") == nil)
    }
}

// MARK: - Cancel Reconnect Backoff

@Suite("WebSocket Cancel Reconnect Backoff")
@MainActor
struct WebSocketClientCancelBackoffTests {

    /// cancelReconnectBackoff preserves activeSubscriptions so the
    /// resubscription path knows what sessions to re-subscribe after
    /// the fresh connection opens.
    @Test func preservesActiveSubscriptions() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s2", level: .notifications, requestId: "r2")
        )
        client._setStatusForTesting(.reconnecting(attempt: 3))

        client.cancelReconnectBackoff()

        #expect(client.activeSubscriptions.count == 2)
        #expect(client._activeSubscriptionForTesting("s1") == .full)
        #expect(client._activeSubscriptionForTesting("s2") == .notifications)
        #expect(client.status == .disconnected)
    }

    /// Contrast: disconnect() clears subscriptions; cancelReconnectBackoff() does not.
    @Test func disconnectClearsSubscriptionsUnlikeCancelBackoff() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )

        client.disconnect()

        #expect(client.activeSubscriptions.isEmpty)
    }

    /// After cancelReconnectBackoff, status is .disconnected, so subsequent
    /// sends fail immediately. The caller must re-establish the connection.
    /// But subscriptions remain preserved for the resubscription path.
    @Test func sendAfterCancelBackoffFailsButSubscriptionsPreserved() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(5)
        )
        client._preTrackSubscriptionForTesting(
            .subscribe(sessionId: "s1", level: .full, requestId: "r1")
        )
        client._setStatusForTesting(.reconnecting(attempt: 3))

        client.cancelReconnectBackoff()

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Send should throw after cancelReconnectBackoff")
        } catch {
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1), "Should fail immediately")
        }

        // Subscriptions preserved despite send failure
        #expect(client._activeSubscriptionForTesting("s1") == .full)
    }
}

// MARK: - Reconnect Delay Curve

@Suite("WebSocket Reconnect Delay Curve")
struct WebSocketClientReconnectDelayCurveTests {

    /// Attempts 1-3: base 500ms (transient: suspension wake, network handoff)
    @Test func tier1to3BasesAt500ms() {
        for attempt in 1...3 {
            for _ in 0..<50 {
                let delay = WebSocketClient.reconnectDelay(attempt: attempt)
                #expect(delay >= 0.375, "Attempt \(attempt): \(delay)s below lower bound (0.5 * 0.75)")
                #expect(delay <= 0.625, "Attempt \(attempt): \(delay)s above upper bound (0.5 * 1.25)")
            }
        }
    }

    /// Attempt 4: base 2s (moderate: server restart, Tailscale reconnect)
    @Test func tier4BasesAt2s() {
        for _ in 0..<50 {
            let delay = WebSocketClient.reconnectDelay(attempt: 4)
            #expect(delay >= 1.5)
            #expect(delay <= 2.5)
        }
    }

    /// Attempt 5: base 4s
    @Test func tier5BasesAt4s() {
        for _ in 0..<50 {
            let delay = WebSocketClient.reconnectDelay(attempt: 5)
            #expect(delay >= 3.0)
            #expect(delay <= 5.0)
        }
    }

    /// Attempt 6: base 8s
    @Test func tier6BasesAt8s() {
        for _ in 0..<50 {
            let delay = WebSocketClient.reconnectDelay(attempt: 6)
            #expect(delay >= 6.0)
            #expect(delay <= 10.0)
        }
    }

    /// Attempts 7+: cap at base 15s (real problems: server down)
    @Test func tier7PlusCapsAt15s() {
        for attempt in [7, 8, 10, 20, 100] {
            for _ in 0..<50 {
                let delay = WebSocketClient.reconnectDelay(attempt: attempt)
                #expect(delay >= 11.25, "Attempt \(attempt): \(delay)s below lower bound")
                #expect(delay <= 18.75, "Attempt \(attempt): \(delay)s above upper bound")
            }
        }
    }

    /// Jitter should produce variation, not a constant.
    @Test func jitterProducesVariation() {
        var seen = Set<Int>()
        for _ in 0..<100 {
            let delay = WebSocketClient.reconnectDelay(attempt: 1)
            seen.insert(Int(delay * 10000))
        }
        #expect(seen.count >= 2, "Jitter should produce variation across 100 samples")
    }

    /// Attempt 0 falls through to the default case (15s cap).
    /// Not a practical scenario but documents the edge case.
    @Test func attemptZeroUsesDefaultTier() {
        for _ in 0..<20 {
            let delay = WebSocketClient.reconnectDelay(attempt: 0)
            #expect(delay >= 11.25)
            #expect(delay <= 18.75)
        }
    }

    /// Negative attempt also falls through to default (15s cap).
    @Test func negativeAttemptUsesDefaultTier() {
        for _ in 0..<20 {
            let delay = WebSocketClient.reconnectDelay(attempt: -1)
            #expect(delay >= 11.25)
            #expect(delay <= 18.75)
        }
    }
}
