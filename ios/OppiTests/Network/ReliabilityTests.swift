import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_try force_unwrapping

/// Tests for reliability and server interaction hardening.
///
/// Fix 1: Reconnect jitter (WebSocketClient backoff)
/// Fix 2: Extension dialog timeout (auto-dismiss)
/// Fix 3: Extension dialog cleared on disconnect
/// Fix 4: Stop reconciliation (tested indirectly — timer setup/teardown)
/// Fix 5: Timeline item cap (bounded memory growth)
@Suite("Reliability")
struct ReliabilityTests {

    // MARK: - Fix 1: Reconnect Jitter

    @Test func reconnectDelayBoundsWithJitter() {
        // Fast tier (1-3): base=0.5, with ±25% jitter → [0.375, 0.625]
        // Moderate tier (5): base=4, with ±25% jitter → [3.0, 5.0]
        // Slow tier (10): base=15 cap, with ±25% → [11.25, 18.75]
        for _ in 0..<50 {
            let d1 = WebSocketClient.reconnectDelay(attempt: 1)
            #expect(d1 >= 0.375 && d1 <= 0.625, "Attempt 1 delay out of range: \(d1)")

            let d3 = WebSocketClient.reconnectDelay(attempt: 3)
            #expect(d3 >= 0.375 && d3 <= 0.625, "Attempt 3 (fast tier) delay out of range: \(d3)")

            let d5 = WebSocketClient.reconnectDelay(attempt: 5)
            #expect(d5 >= 3.0 && d5 <= 5.0, "Attempt 5 delay out of range: \(d5)")

            let d10 = WebSocketClient.reconnectDelay(attempt: 10)
            #expect(d10 >= 11.25 && d10 <= 18.75, "Attempt 10 (capped) delay out of range: \(d10)")
        }
    }

    @Test func reconnectDelayHasVariance() {
        var delays = Set<Int>()
        for _ in 0..<100 {
            let d = WebSocketClient.reconnectDelay(attempt: 5)
            delays.insert(Int(d * 1000)) // millisecond precision
        }
        #expect(delays.count > 1, "Delays should have variance from jitter")
    }

    @Test func reconnectDelayCapsAt15() {
        // Very high attempt numbers should be bounded at 15s base
        for _ in 0..<20 {
            let d = WebSocketClient.reconnectDelay(attempt: 100)
            #expect(d <= 18.75, "Delay should be capped: \(d)") // 15 * 1.25
            #expect(d >= 11.25, "Delay should have minimum: \(d)") // 15 * 0.75
        }
    }

    @MainActor
    @Test func sendWhileConnectingHonorsConfiguredWaitTimeout() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .milliseconds(150),
            sendTimeout: .milliseconds(150)
        )
        client._setStatusForTesting(.connecting)

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Expected send failure while connecting")
        } catch let error as WebSocketError {
            switch error {
            case .notConnected:
                break
            default:
                Issue.record("Expected notConnected, got \(error)")
            }
        } catch {
            Issue.record("Expected WebSocketError, got \(error)")
        }

        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "Send should fail fast while connecting")
    }

    @MainActor
    @Test func sendWhileReconnectingHonorsConfiguredWaitTimeout() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .milliseconds(150),
            sendTimeout: .milliseconds(150)
        )
        client._setStatusForTesting(.reconnecting(attempt: 1))

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Expected send failure while reconnecting")
        } catch let error as WebSocketError {
            switch error {
            case .notConnected:
                break
            default:
                Issue.record("Expected notConnected, got \(error)")
            }
        } catch {
            Issue.record("Expected WebSocketError, got \(error)")
        }

        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "Send should fail fast while reconnecting")
    }

    // MARK: - Event-Driven Connection Waiting

    @MainActor
    @Test func waitForConnectionResolvesImmediatelyWhenConnected() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .milliseconds(500),
            sendTimeout: .milliseconds(500)
        )
        client._setStatusForTesting(.connected)

        let start = ContinuousClock.now
        // send() returns immediately when already connected (no socket = throws, but fast)
        do {
            try await client.send(.getState())
        } catch {
            // Expected — no real socket
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100), "Should not poll when already connected (\(elapsed))")
    }

    @MainActor
    @Test func waitForConnectionResolvesOnStatusTransition() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(5),
            sendTimeout: .seconds(5)
        )
        client._setStatusForTesting(.connecting)

        // Simulate connection completing after 50ms
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            client._setStatusForTesting(.connected)
        }

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
        } catch {
            // Expected — no real socket, but waited for connected first
        }
        let elapsed = ContinuousClock.now - start

        // Should resolve in ~50ms (when status changes), not 5s (timeout)
        #expect(elapsed < .milliseconds(500), "Should resolve on status change, not timeout (\(elapsed))")
        #expect(elapsed >= .milliseconds(40), "Should wait for status change (\(elapsed))")
    }

    @MainActor
    @Test func waitForConnectionResolvesOnDisconnect() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(5),
            sendTimeout: .seconds(5)
        )
        client._setStatusForTesting(.reconnecting(attempt: 1))

        // Simulate disconnect after 50ms
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            client._setStatusForTesting(.disconnected)
        }

        let start = ContinuousClock.now
        do {
            try await client.send(.getState())
            Issue.record("Expected send failure on disconnect")
        } catch {
            // Expected
        }
        let elapsed = ContinuousClock.now - start

        // Should resolve in ~50ms, not 5s
        #expect(elapsed < .milliseconds(500), "Should resolve on disconnect, not timeout (\(elapsed))")
    }

    // MARK: - Fix 2: Extension Dialog Timeout

    @MainActor
    @Test func extensionDialogSetOnRequest() {
        let (conn, pipe) = makeTestConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input",
            title: "Enter value", message: "Please enter a value", timeout: 30
        )
        pipe.handle(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext1")
    }

    @MainActor
    @Test func extensionDialogReplacedByNewRequest() {
        let (conn, pipe) = makeTestConnection()

        let req1 = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "First", timeout: 30
        )
        pipe.handle(.extensionUIRequest(req1), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext1")

        let req2 = ExtensionUIRequest(
            id: "ext2", sessionId: "s1", method: "confirm", title: "Second"
        )
        pipe.handle(.extensionUIRequest(req2), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext2", "New request should replace old")
    }

    // MARK: - Fix 3: Extension Dialog Cleared on Disconnect

    @MainActor
    @Test func extensionDialogClearedOnDisconnect() {
        let (conn, pipe) = makeTestConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "confirm", title: "Confirm?"
        )
        pipe.handle(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog != nil)

        conn.disconnectSession()

        #expect(conn.activeExtensionDialog == nil,
            "Extension dialog should be cleared when session disconnects")
    }

    @MainActor
    @Test func extensionDialogClearedOnSessionSwitch() {
        let (conn, pipe) = makeTestConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "Test"
        )
        pipe.handle(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog != nil)

        // Simulate streamSession switching from s1 -> s2 without opening a real socket.
        conn.disconnectSession()
        conn._setActiveSessionIdForTesting("s2")

        #expect(conn.activeExtensionDialog == nil,
            "Extension dialog should be cleared on session switch")
    }

    @MainActor
    @Test func extensionDialogSurvivedWhenStreamAlive() {
        let (conn, pipe) = makeTestConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "Test"
        )
        pipe.handle(.extensionUIRequest(request), sessionId: "s1")

        // flushAndSuspend does NOT clear the dialog (background transition)
        pipe.flushNow()

        #expect(conn.activeExtensionDialog?.id == "ext1",
            "Dialog should survive background transition")
    }

    // MARK: - Thinking lifecycle recovery

    @MainActor
    @Test func stopConfirmedWithoutAgentEndFinalizesThinking() {
        let (conn, pipe) = makeTestConnection()
        pipe.handle(.connected(session: makeTestSession(status: .busy)), sessionId: "s1")

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.thinkingDelta(delta: "thinking..."), sessionId: "s1")
        pipe.handle(
            .stopRequested(source: .user, reason: "Stopping current turn"),
            sessionId: "s1"
        )
        pipe.handle(
            .stopConfirmed(source: .user, reason: nil),
            sessionId: "s1"
        )

        // Force flush in case the coalescer still has buffered deltas.
        pipe.flushNow()

        let thinkingStates = pipe.reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }

        #expect(thinkingStates.count == 1)
        #expect(thinkingStates[0] == true)
    }

    @MainActor
    @Test func stateReadyWithoutAgentEndFinalizesThinking() {
        let (conn, pipe) = makeTestConnection()
        pipe.handle(.connected(session: makeTestSession(status: .busy)), sessionId: "s1")

        pipe.handle(.agentStart, sessionId: "s1")
        pipe.handle(.thinkingDelta(delta: "thinking..."), sessionId: "s1")
        pipe.handle(.state(session: makeTestSession(status: .ready)), sessionId: "s1")

        pipe.flushNow()

        let thinkingStates = pipe.reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }

        #expect(thinkingStates.count == 1)
        #expect(thinkingStates[0] == true)
    }

    // MARK: - Fix 5: Timeline preserves all items (no trimming)

    @MainActor
    @Test func timelinePreservesAllItems() {
        let reducer = TimelineReducer()

        for i in 0..<600 {
            reducer.appendUserMessage("msg-\(i)")
        }

        #expect(reducer.items.count == 600, "All items should be preserved, got \(reducer.items.count)")

        guard case .userMessage(_, let firstText, _, _) = reducer.items.first else {
            Issue.record("Expected userMessage as first item")
            return
        }
        #expect(firstText == "msg-0", "First item should be msg-0")

        guard case .userMessage(_, let lastText, _, _) = reducer.items.last else {
            Issue.record("Expected userMessage as last item")
            return
        }
        #expect(lastText == "msg-599", "Last item should be msg-599")
    }

    @MainActor
    @Test func timelinePreservesToolCallsWithConversation() {
        let reducer = TimelineReducer()

        let turnCount = 200
        for i in 0..<turnCount {
            reducer.appendUserMessage("msg-\(i)")
            let toolId = "t\(i)"
            reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))
            reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))
        }

        let userMessages = reducer.items.filter {
            if case .userMessage = $0 { return true }; return false
        }
        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }; return false
        }

        #expect(userMessages.count == turnCount, "All user messages preserved")
        #expect(toolItems.count == turnCount, "All tool calls preserved")
    }

    @MainActor
    @Test func loadSessionPreservesAllEvents() {
        let reducer = TimelineReducer()

        var events: [TraceEvent] = []
        for i in 0..<600 {
            events.append(makeTraceEvent(id: "e\(i)", text: "msg \(i)"))
        }

        reducer.loadSession(events)

        #expect(reducer.items.count == 600,
            "loadSession should preserve all items, got \(reducer.items.count)")
    }

    @MainActor
    @Test func processBatchPreservesAllEvents() {
        let reducer = TimelineReducer()

        var events: [AgentEvent] = []
        for i in 0..<600 {
            events.append(.agentStart(sessionId: "s1"))
            events.append(.textDelta(sessionId: "s1", delta: "msg \(i)"))
            events.append(.agentEnd(sessionId: "s1"))
        }

        reducer.processBatch(events)

        #expect(reducer.items.count == 600,
            "processBatch should preserve all items, got \(reducer.items.count)")
    }

    // MARK: - Helpers

    private func makeTraceEvent(id: String, text: String) -> TraceEvent {
        let json = """
        {"id":"\(id)","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"\(text)"}
        """
        return try! JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
    }

}
