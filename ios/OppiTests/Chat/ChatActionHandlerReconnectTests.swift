import Testing
import Foundation
@testable import Oppi

/// Regression tests for prompt delivery after WebSocket reconnect.
///
/// Reproduces the bug from session W01FGDYt (2026-03-13): user sends prompts
/// after a WS disconnect/reconnect, but messages never reach the server.
/// The `isSending` guard blocks subsequent sends while the first send's
/// ack timeout is still in flight.
///
/// See: bug 35835fa3 (queued prompts not delivered after WebSocket reconnect)
@Suite("ChatActionHandler — Reconnect Prompt Delivery")
@MainActor
struct ChatActionHandlerReconnectTests {

    // MARK: - isSending guard blocks during ack timeout

    @Test func sendBlockedDuringAckTimeout_textBouncesBackSilently() async {
        // Scenario: first prompt is sent but ack never arrives (WS dropped).
        // User taps send again while ack timeout is in flight.
        // Expected: second send is blocked; text returned to caller.
        // Bug: no visible error — user thinks the send worked.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        connection._sendAckTimeoutForTesting = .milliseconds(300)

        // First send: WS accepts the bytes but ack never comes (simulates dead connection)
        connection._sendMessageForTesting = { _ in
            // Send "succeeds" at the WS level but server never responds with turn_ack
        }

        let first = handler.sendPrompt(
            text: "first message",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(first.isEmpty, "First send should accept the text (return empty)")

        // Wait for the Task to start and set isSending = true
        let sending = await waitForTestCondition(timeoutMs: 200) {
            await MainActor.run { handler.isSending }
        }
        #expect(sending, "Handler should be in isSending state")

        // Second send while first is waiting for ack
        let second = handler.sendPrompt(
            text: "try again",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(second == "try again", "Second send should be blocked — text returned to caller")

        // Third send
        let third = handler.sendPrompt(
            text: "?",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(third == "?", "Third send should also be blocked")

        // Wait for ack timeout + retry to exhaust
        let finished = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished, "Send should eventually finish after ack timeout")

        // The first message should have been removed from timeline (send failed)
        let userMessages = reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(userMessages.isEmpty, "Failed optimistic user message should be removed")

        // An error should be visible
        let errors = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(!errors.isEmpty, "Timeline should show an error for the failed send")
    }

    @Test func sendAfterAckTimeout_eventuallySucceeds() async {
        // After the ack timeout clears isSending, the next send should work.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        connection._sendAckTimeoutForTesting = .milliseconds(200)

        var sendCount = 0

        // First send: no ack (simulates dead WS). Second send: ack arrives.
        connection._sendMessageForTesting = { message in
            sendCount += 1
            if sendCount <= 2 {
                // First two attempts (original + retry): no ack → timeout
                return
            }
            // Third attempt (user's retry after isSending clears): succeed
            if case .prompt(_, _, _, let requestId, let clientTurnId) = message,
               let requestId, let clientTurnId {
                connection.handleServerMessage(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            }
        }

        // First send — will timeout
        _ = handler.sendPrompt(
            text: "first attempt",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        // Wait for timeout to clear
        let cleared = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(cleared)

        // Second send — should work now
        let result = handler.sendPrompt(
            text: "retry after reconnect",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result.isEmpty, "Send should be accepted after isSending clears")

        let sent = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(sent)

        // Should have a user message in the timeline from the successful send
        let userMessages = reducer.items.filter {
            if case .userMessage(_, let text, _, _) = $0 { return text == "retry after reconnect" }
            return false
        }
        #expect(userMessages.count == 1, "Successful retry should produce a user message")
    }

    // MARK: - Busy path: optimistic queue items orphaned after reconnect

    @Test func busyPathOptimisticItem_removedOnSendFailure() async {
        // When session is busy and send fails, the optimistic queue item
        // must be removed — not left as a permanent ghost.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        connection._sendAckTimeoutForTesting = .milliseconds(200)

        // Send will fail (no ack)
        connection._sendMessageForTesting = { _ in }

        _ = handler.sendPrompt(
            text: "steer while busy",
            images: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        // Optimistic item should exist immediately
        let queueBefore = connection.messageQueueStore.queue(for: "s1")
        #expect(queueBefore.steering.count == 1)

        // Wait for send to fail
        let finished = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished)

        // Optimistic item must be cleaned up
        let queueAfter = connection.messageQueueStore.queue(for: "s1")
        #expect(
            queueAfter.steering.isEmpty,
            "Optimistic queue item must be removed after send failure — otherwise it persists as ghost with chevron"
        )
    }

    @Test func busyPathOptimisticItem_survivesWhenSendSucceeds() async {
        // Verify the happy path: optimistic item stays until server queue sync replaces it.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")

        connection._sendMessageForTesting = { message in
            if case .steer(_, _, let requestId, let clientTurnId) = message,
               let requestId, let clientTurnId {
                connection.handleServerMessage(
                    .turnAck(
                        command: "steer",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            }
            // Swallow get_queue — no server response for queue refresh
            // This means the optimistic item stays (not overwritten by server state)
        }

        _ = handler.sendPrompt(
            text: "steer while busy",
            images: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        let finished = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished)

        // Optimistic item should still be present (awaiting server queue sync)
        let queue = connection.messageQueueStore.queue(for: "s1")
        #expect(queue.steering.count == 1)
        #expect(queue.steering.first?.message == "steer while busy")
    }

    // MARK: - activeSessionId nil window

    @Test func sendWithNilActiveSessionId_failsGracefully() async {
        // Reproduces the window between disconnectSession() clearing
        // sender.activeSessionId and streamSession() re-setting it.
        // The prompt should fail with a visible error, not hang silently.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials())
        // Deliberately do NOT set activeSessionId — simulates the nil window
        connection._setActiveSessionIdForTesting(nil)
        connection._sendAckTimeoutForTesting = .milliseconds(200)

        var restoredText: String?

        _ = handler.sendPrompt(
            text: "sent during nil window",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onAsyncFailure: { text, _ in
                restoredText = text
            }
        )

        let finished = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished, "Send should eventually fail, not hang forever")

        // Error should be surfaced
        let errors = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(!errors.isEmpty, "Send failure should produce a visible timeline error")

        // Text should be restored
        #expect(restoredText == "sent during nil window", "Failed text should be restored via onAsyncFailure")
    }

    // MARK: - Full reconnect cycle simulation

    @Test func promptAfterSimulatedReconnect_delivered() async {
        // Happy path after reconnect: activeSessionId is re-set,
        // WS is connected, prompt goes through.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials())
        connection._setActiveSessionIdForTesting("s1")

        var promptTexts: [String] = []

        connection._sendMessageForTesting = { message in
            if case .prompt(let text, _, _, let requestId, let clientTurnId) = message,
               let requestId, let clientTurnId {
                promptTexts.append(text)
                connection.handleServerMessage(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            }
        }

        // Simulate: disconnectSession clears activeSessionId
        connection._setActiveSessionIdForTesting(nil)

        // Simulate: streamSession re-sets it (reconnect complete)
        connection._setActiveSessionIdForTesting("s1")

        // Now send — should work
        _ = handler.sendPrompt(
            text: "after reconnect",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        let sent = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(sent)
        #expect(promptTexts == ["after reconnect"])
    }

    @Test func multiplePromptsAfterReconnect_allDeliveredSequentially() async {
        // After reconnect, user should be able to send multiple prompts.
        // Each should be delivered one at a time (isSending serialization).
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials())
        connection._setActiveSessionIdForTesting("s1")

        var promptTexts: [String] = []

        connection._sendMessageForTesting = { message in
            if case .prompt(let text, _, _, let requestId, let clientTurnId) = message,
               let requestId, let clientTurnId {
                promptTexts.append(text)
                connection.handleServerMessage(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            }
        }

        // Send three prompts sequentially (waiting for each to finish)
        for text in ["first", "second", "third"] {
            let result = handler.sendPrompt(
                text: text,
                images: [],
                isBusy: false,
                connection: connection,
                reducer: reducer,
                sessionId: "s1"
            )
            #expect(result.isEmpty, "Send of '\(text)' should be accepted")

            let done = await waitForTestCondition(timeoutMs: 1_000) {
                await MainActor.run { !handler.isSending }
            }
            #expect(done, "Send of '\(text)' should complete")
        }

        #expect(promptTexts == ["first", "second", "third"])
    }

    // MARK: - Session scope framing race

    @Test func sendWithNilActiveSessionId_fastFailsWithoutDispatch() async {
        // Regression test for the reconnect gap fix.
        //
        // Before the fix: WS connected but activeSessionId nil → message
        // was sent without session scope, server couldn't route it, ack
        // never arrived, user waited 4-8s with no feedback.
        //
        // After the fix: sendTurnWithAck pre-checks activeSessionId and
        // fast-fails, so the send never reaches the wire. Error surfaces
        // immediately and text is restored.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials())
        connection._setActiveSessionIdForTesting(nil) // nil window

        var restoredText: String?
        var reconnectCalled = false

        _ = handler.sendPrompt(
            text: "lost in the void",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onAsyncFailure: { text, _ in
                restoredText = text
            },
            onNeedsReconnect: {
                reconnectCalled = true
            }
        )

        let finished = await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished, "Should fast-fail, not wait for ack timeout")

        // Text restored immediately
        #expect(restoredText == "lost in the void")

        // Reconnect triggered (notConnected is a reconnectable error)
        #expect(reconnectCalled)

        // Error visible
        let errors = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(!errors.isEmpty, "Fast-fail should still surface an error")
    }

    @Test func isSendingGuard_noVisibleError_documentsTheBug() async {
        // This test documents the current (broken) behavior:
        // When isSending blocks a send, the text is returned to the
        // caller but NO error is shown in the timeline.
        // The user has no way to know their send was rejected.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        connection._sendAckTimeoutForTesting = .milliseconds(300)

        // First send — will sit waiting for ack
        connection._sendMessageForTesting = { _ in }

        _ = handler.sendPrompt(
            text: "first",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 200) {
            await MainActor.run { handler.isSending }
        }

        // Timeline before the blocked send
        let errorsBefore = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }

        // Second send — blocked by isSending
        let restored = handler.sendPrompt(
            text: "blocked",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(restored == "blocked", "Text should be returned to caller")

        // No error was added to the timeline for the blocked send
        let errorsAfter = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(
            errorsAfter.count == errorsBefore.count,
            "BUG: isSending guard returns text silently — no error shown to user"
        )

        // Wait for first send to timeout
        _ = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
    }

    // MARK: - onNeedsReconnect callback interaction

    @Test func sendFailure_onNeedsReconnect_doesNotOrphanOptimisticMessage() async {
        // When send fails with a reconnectable error, onNeedsReconnect fires.
        // The optimistic user message must still be cleaned up — not orphaned
        // because the reconnect disrupts the error handler.
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        // Don't set activeSessionId → wsClient.send() will throw notConnected

        var reconnectCalled = false
        var restoredText: String?

        _ = handler.sendPrompt(
            text: "reconnect me",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onAsyncFailure: { text, _ in
                restoredText = text
            },
            onNeedsReconnect: {
                reconnectCalled = true
            }
        )

        let finished = await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        }
        #expect(finished)
        #expect(reconnectCalled, "Reconnectable error should trigger onNeedsReconnect")
        #expect(restoredText == "reconnect me", "Text should be restored even when reconnect fires")

        // No orphaned user messages
        let userMessages = reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(userMessages.isEmpty, "Optimistic user message must be removed after failure")

        // Error should be visible
        let errors = reducer.items.filter {
            if case .error = $0 { return true }
            return false
        }
        #expect(!errors.isEmpty, "Send failure must surface as timeline error")
    }
}
