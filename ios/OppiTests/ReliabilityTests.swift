import Testing
import Foundation
@testable import Oppi

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
        // Attempt 1: base=1, with ±25% jitter → [0.75, 1.25]
        // Attempt 3: base=4, with ±25% jitter → [3.0, 5.0]
        // Attempt 10: base=512→capped at 30, with ±25% → [22.5, 37.5]
        for _ in 0..<50 {
            let d1 = WebSocketClient.reconnectDelay(attempt: 1)
            #expect(d1 >= 0.75 && d1 <= 1.25, "Attempt 1 delay out of range: \(d1)")

            let d3 = WebSocketClient.reconnectDelay(attempt: 3)
            #expect(d3 >= 3.0 && d3 <= 5.0, "Attempt 3 delay out of range: \(d3)")

            let d10 = WebSocketClient.reconnectDelay(attempt: 10)
            #expect(d10 >= 22.5 && d10 <= 37.5, "Attempt 10 (capped) delay out of range: \(d10)")
        }
    }

    @Test func reconnectDelayHasVariance() {
        var delays = Set<Int>()
        for _ in 0..<100 {
            let d = WebSocketClient.reconnectDelay(attempt: 3)
            delays.insert(Int(d * 1000)) // millisecond precision
        }
        #expect(delays.count > 1, "Delays should have variance from jitter")
    }

    @Test func reconnectDelayCapsAt30() {
        // Very high attempt numbers should still be bounded
        for _ in 0..<20 {
            let d = WebSocketClient.reconnectDelay(attempt: 100)
            #expect(d <= 37.5, "Delay should be capped: \(d)") // 30 * 1.25
            #expect(d >= 22.5, "Delay should have minimum: \(d)") // 30 * 0.75
        }
    }

    @MainActor
    @Test func sendWhileConnectingHonorsConfiguredWaitTimeout() async {
        let client = WebSocketClient(
            credentials: makeCredentials(),
            waitForConnectionTimeout: .milliseconds(150),
            waitPollInterval: .milliseconds(25),
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
            credentials: makeCredentials(),
            waitForConnectionTimeout: .milliseconds(150),
            waitPollInterval: .milliseconds(25),
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

    // MARK: - Fix 2: Extension Dialog Timeout

    @MainActor
    @Test func extensionDialogSetOnRequest() {
        let conn = makeConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input",
            title: "Enter value", message: "Please enter a value", timeout: 30
        )
        conn.handleServerMessage(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext1")
    }

    @MainActor
    @Test func extensionDialogReplacedByNewRequest() {
        let conn = makeConnection()

        let req1 = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "First", timeout: 30
        )
        conn.handleServerMessage(.extensionUIRequest(req1), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext1")

        let req2 = ExtensionUIRequest(
            id: "ext2", sessionId: "s1", method: "confirm", title: "Second"
        )
        conn.handleServerMessage(.extensionUIRequest(req2), sessionId: "s1")
        #expect(conn.activeExtensionDialog?.id == "ext2", "New request should replace old")
    }

    // MARK: - Fix 3: Extension Dialog Cleared on Disconnect

    @MainActor
    @Test func extensionDialogClearedOnDisconnect() {
        let conn = makeConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "confirm", title: "Confirm?"
        )
        conn.handleServerMessage(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog != nil)

        conn.disconnectSession()

        #expect(conn.activeExtensionDialog == nil,
            "Extension dialog should be cleared when session disconnects")
    }

    @MainActor
    @Test func extensionDialogClearedOnSessionSwitch() {
        let conn = makeConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "Test"
        )
        conn.handleServerMessage(.extensionUIRequest(request), sessionId: "s1")
        #expect(conn.activeExtensionDialog != nil)

        // Simulate streamSession switching from s1 -> s2 without opening a real socket.
        conn.disconnectSession()
        conn._setActiveSessionIdForTesting("s2")

        #expect(conn.activeExtensionDialog == nil,
            "Extension dialog should be cleared on session switch")
    }

    @MainActor
    @Test func extensionDialogSurvivedWhenStreamAlive() {
        let conn = makeConnection()

        let request = ExtensionUIRequest(
            id: "ext1", sessionId: "s1", method: "input", title: "Test"
        )
        conn.handleServerMessage(.extensionUIRequest(request), sessionId: "s1")

        // flushAndSuspend does NOT clear the dialog (background transition)
        conn.flushAndSuspend()

        #expect(conn.activeExtensionDialog?.id == "ext1",
            "Dialog should survive background transition")
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

    private func makeCredentials() -> ServerCredentials {
        .init(host: "localhost", port: 7749, token: "sk_test", name: "Test")
    }

    @MainActor
    private func makeConnection(sessionId: String = "s1") -> ServerConnection {
        let conn = ServerConnection()
        conn.configure(credentials: makeCredentials())
        // Avoid real WS dial in unit tests.
        conn._setActiveSessionIdForTesting(sessionId)
        return conn
    }

    private func makeTraceEvent(id: String, text: String) -> TraceEvent {
        let json = """
        {"id":"\(id)","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"\(text)"}
        """
        return try! JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
    }

}
