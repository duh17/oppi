import Testing
import Foundation
import UIKit
@testable import PiRemote

@Suite("ChatActionHandler")
struct ChatActionHandlerTests {

    // MARK: - Stop State Machine

    @MainActor
    @Test func initialState() {
        let handler = ChatActionHandler()
        #expect(!handler.isStopping)
        #expect(!handler.showForceStop)
        #expect(!handler.isForceStopInFlight)
        #expect(!handler.isSending)
        #expect(handler.sendAckStage == nil)
        #expect(handler.sendProgressText == nil)
    }

    @MainActor
    @Test func resetStopStateClearsAll() {
        let handler = ChatActionHandler()

        // Simulate partial stop state (direct property mutation for testing)
        // Since properties are private(set), test via the reset path
        handler.resetStopState()

        #expect(!handler.isStopping)
        #expect(!handler.showForceStop)
        #expect(!handler.isForceStopInFlight)
        #expect(!handler.isSending)
        #expect(handler.sendAckStage == nil)
        #expect(handler.sendProgressText == nil)
    }

    @MainActor
    @Test func cleanupDoesNotCrash() {
        let handler = ChatActionHandler()
        handler.cleanup()
        handler.cleanup() // idempotent
    }

    // MARK: - Send Prompt Logic

    @MainActor
    @Test func sendPromptReturnsEmptyOnWhitespaceOnly() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()

        // Whitespace-only text with no images should return the original text (guard fails)
        let result = handler.sendPrompt(
            text: "   ",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result == "   ", "Whitespace-only prompt should be returned (not sent)")
        #expect(reducer.items.isEmpty, "No items should be created for whitespace prompt")
    }

    @MainActor
    @Test func sendPromptCreatesUserMessage() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._sendMessageForTesting = { _ in }
        connection._sendAckTimeoutForTesting = .seconds(2)

        let result = handler.sendPrompt(
            text: "Hello agent",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result.isEmpty, "Should return empty on success (input cleared)")

        await waitForCondition { !reducer.items.isEmpty }
        #expect(reducer.items.count == 1)

        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage, got \(reducer.items[0])")
            return
        }
        #expect(text == "Hello agent")
    }

    @MainActor
    @Test func sendPromptDoesNotAppendOptimisticMessageBeforeTaskStarts() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()

        var queuedOperation: (@MainActor () async -> Void)?
        var dispatchStarted = false

        handler._launchTaskForTesting = { operation in
            queuedOperation = operation
        }

        let result = handler.sendPrompt(
            text: "queued message",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onDispatchStarted: {
                dispatchStarted = true
            }
        )

        #expect(result.isEmpty)
        #expect(!dispatchStarted, "Dispatch callback should not run until queued task executes")
        #expect(reducer.items.isEmpty, "No optimistic row should be appended before task start")
        #expect(queuedOperation != nil, "Prompt send should enqueue an async task")
    }

    @MainActor
    @Test func sendPromptIgnoresTapWhileSendInFlight() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
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

        _ = handler.sendPrompt(
            text: "first",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        await waitForCondition { handler.isSending }

        let blocked = handler.sendPrompt(
            text: "second",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        #expect(blocked == "second")

        await waitForCondition(timeoutMs: 1_000) { !handler.isSending }

        let userCount = reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }.count
        #expect(userCount == 1)
    }

    @MainActor
    @Test func sendPromptTracksAckStageProgress() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        handler._sendStageDisplayDurationForTesting = .milliseconds(40)

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            try await Task.sleep(for: .milliseconds(20))
            connection.handleServerMessage(
                .turnAck(
                    command: "prompt",
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            try await Task.sleep(for: .milliseconds(40))
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

            try await Task.sleep(for: .milliseconds(40))
            connection.handleServerMessage(
                .turnAck(
                    command: "prompt",
                    clientTurnId: clientTurnId,
                    stage: .started,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        _ = handler.sendPrompt(
            text: "stage me",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        await waitForCondition(timeoutMs: 600) { handler.sendAckStage == .accepted }
        await waitForCondition(timeoutMs: 600) { handler.sendAckStage == .dispatched }
        await waitForCondition(timeoutMs: 600) { handler.sendAckStage == .started }
        #expect(handler.sendProgressText == "Started…")

        await waitForCondition(timeoutMs: 600) { handler.sendAckStage == nil }
        #expect(handler.sendProgressText == nil)
    }

    @MainActor
    @Test func sendPromptFailureClearsAckStage() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            connection.handleServerMessage(
                .turnAck(
                    command: "prompt",
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
            throw WebSocketError.notConnected
        }

        _ = handler.sendPrompt(
            text: "fail me",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        await waitForCondition(timeoutMs: 600) { !handler.isSending }
        #expect(handler.sendAckStage == nil)
        #expect(handler.sendProgressText == nil)
    }

    @MainActor
    @Test func sendPromptInBusyModeCreatesSystemEvent() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._sendMessageForTesting = { _ in }
        connection._sendAckTimeoutForTesting = .seconds(2)

        let result = handler.sendPrompt(
            text: "steer this way",
            images: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result.isEmpty)

        await waitForCondition { !reducer.items.isEmpty }
        #expect(reducer.items.count == 1)

        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for steer, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("steer this way"))
    }

    @MainActor
    @Test func sendPromptFailureRestoresInputAndImagesViaCallback() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        _ = connection.configure(credentials: .init(host: "localhost", port: 7749, token: "sk_test", name: "Test"))

        let image = makePendingImage()
        var restoredText: String?
        var restoredImageCount = 0

        let returned = handler.sendPrompt(
            text: "hello",
            images: [image],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onAsyncFailure: { text, images in
                restoredText = text
                restoredImageCount = images.count
            }
        )

        #expect(returned.isEmpty)
        await waitForCondition { restoredText != nil }

        #expect(restoredText == "hello")
        #expect(restoredImageCount == 1)

        let hasUserRow = reducer.items.contains { item in
            if case .userMessage = item { return true }
            return false
        }
        #expect(!hasUserRow, "Optimistic user row should be removed after async send failure")

        let hasError = reducer.items.contains { item in
            if case .error = item { return true }
            return false
        }
        #expect(hasError, "Failure should surface as explicit timeline error")
    }

    @MainActor
    @Test func sendPromptFailureTriggersReconnectCallbackOnce() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        _ = connection.configure(credentials: .init(host: "localhost", port: 7749, token: "sk_test", name: "Test"))

        var reconnectCalls = 0

        _ = handler.sendPrompt(
            text: "reconnect me",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onNeedsReconnect: {
                reconnectCalls += 1
            }
        )

        await waitForCondition { reconnectCalls > 0 }
        #expect(reconnectCalls == 1)
    }

    // MARK: - Bash

    @MainActor
    @Test func sendBashCreatesSystemEvent() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()

        handler.sendBash(
            "ls -la",
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for bash")
            return
        }
        #expect(msg == "$ ls -la")
    }

    // MARK: - Helpers

    @MainActor
    private func waitForCondition(
        timeoutMs: Int = 1_000,
        intervalMs: Int = 20,
        _ condition: @escaping () -> Bool
    ) async {
        let attempts = max(1, timeoutMs / intervalMs)
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
    }

    @MainActor
    private func makePendingImage() -> PendingImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return PendingImage.from(image)
    }
}
