import Foundation
import Testing
@testable import Oppi

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

// MARK: - Reconnect Delay Curve

@Suite("WebSocket Reconnect Delay Curve")
@MainActor
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
