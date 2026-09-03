import Testing
import Foundation
import UIKit
@testable import Oppi

@Suite("ChatActionHandler")
@MainActor
struct ChatActionHandlerTests {

    // MARK: - Stop State Machine

    @Test func initialState() {
        let handler = ChatActionHandler()
        #expect(!handler.isStopping)
        #expect(!handler.showForceStop)
        #expect(!handler.isForceStopInFlight)
        #expect(!handler.isSending)
        #expect(handler.sendAckStage == nil)
        #expect(handler.sendProgressText == nil)
    }

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

    @Test func cleanupDoesNotCrash() {
        let handler = ChatActionHandler()
        handler.cleanup()
        handler.cleanup() // idempotent
    }

    @Test func stopTurnSendsStopCommandOnly() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()
        let sessionManager = ChatSessionManager(sessionId: "s1")

        var session = makeTestSession(id: "s1", name: nil, messageCount: 0)
        session.status = .busy
        sessionStore.upsert(session)
        connection._setActiveSessionIdForTesting("s1")

        var sentStop = 0
        var sentStopSession = 0

        handler._sendStopForTesting = { _ in
            sentStop += 1
        }
        handler._sendStopSessionForTesting = { _ in
            sentStopSession += 1
        }

        handler.stop(
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 400) { await MainActor.run { sentStop > 0 } }

        #expect(sentStop == 1)
        #expect(sentStopSession == 0)
        #expect(!handler.showForceStop)
    }

    @Test func stopTurnNeverAutoShowsForceStop() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()
        let sessionManager = ChatSessionManager(sessionId: "s1")

        var session = makeTestSession(id: "s1", name: nil, messageCount: 0)
        session.status = .busy
        sessionStore.upsert(session)
        connection._setActiveSessionIdForTesting("s1")
        handler._sendStopForTesting = { _ in }

        handler.stop(
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            sessionId: "s1"
        )

        try? await Task.sleep(for: .milliseconds(250))

        #expect(!handler.showForceStop)
        #expect(!handler.isForceStopInFlight)
    }

    // MARK: - Composer Commands

    @Test func compactReportsSuccessfulDispatchBeforeComposerClearance() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._sendMessageForTesting = { _ in }
        var succeeded = false
        var failed = false

        handler.compact(
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onSendSucceeded: { succeeded = true },
            onAsyncFailure: { failed = true }
        )

        #expect(await waitForTestCondition { await MainActor.run { succeeded } })
        #expect(!failed)
    }

    @Test func compactReportsDispatchFailureForDraftRestoration() async {
        enum ExpectedError: Error {
            case failed
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._sendMessageForTesting = { _ in throw ExpectedError.failed }
        var succeeded = false
        var failed = false

        handler.compact(
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onSendSucceeded: { succeeded = true },
            onAsyncFailure: { failed = true }
        )

        #expect(await waitForTestCondition { await MainActor.run { failed } })
        #expect(!succeeded)
    }

    // MARK: - Send Prompt Logic

    @Test func sendPromptReturnsEmptyOnWhitespaceOnly() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()

        // Whitespace-only text with no attachments should return the original text (guard fails)
        let result = handler.sendPrompt(
            text: "   ",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result == "   ", "Whitespace-only prompt should be returned (not sent)")
        #expect(reducer.items.isEmpty, "No items should be created for whitespace prompt")
    }

    @Test func sendPromptCreatesUserMessage() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._sendMessageForTesting = { _ in }
        connection._sendAckTimeoutForTesting = .seconds(2)

        let result = handler.sendPrompt(
            text: "Hello agent",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )
        #expect(result.isEmpty, "Should return empty on success (input cleared)")

        _ = await waitForTestCondition { await MainActor.run { !reducer.items.isEmpty } }
        #expect(reducer.items.count == 1)

        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage, got \(reducer.items[0])")
            return
        }
        #expect(text == "Hello agent")
    }

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
            attachments: [],
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

    @Test func sendPromptIgnoresTapWhileSendInFlight() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
            pipe.handle(
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
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition { await MainActor.run { handler.isSending } }

        let blocked = handler.sendPrompt(
            text: "second",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        #expect(blocked == "second")

        _ = await waitForTestCondition(timeoutMs: 1_000) { await MainActor.run { !handler.isSending } }

        let userCount = reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }.count
        #expect(userCount == 1)
    }

    @Test func sendPromptDoesNotExposeTurnAckOrSendingProgressText() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            try await Task.sleep(for: .milliseconds(20))
            pipe.handle(
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
            pipe.handle(
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
            pipe.handle(
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
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { handler.isSending } }
        #expect(handler.sendProgressText == nil)

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { handler.sendAckStage == .accepted } }
        #expect(handler.sendProgressText == nil)

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { handler.sendAckStage == .dispatched } }
        #expect(handler.sendProgressText == nil)

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { handler.sendAckStage == .started } }
        #expect(handler.sendProgressText == nil)

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { !handler.isSending } }
        #expect(handler.sendProgressText == nil)
    }

    @Test func sendPromptFailureClearsAckStage() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            pipe.handle(
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
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 600) { await MainActor.run { !handler.isSending } }
        #expect(handler.sendAckStage == nil)
        #expect(handler.sendProgressText == nil)
    }

    @Test func sendPromptInBusyModeDefaultsToSteerWithoutTimelineQueueNoise() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var sawSteer = false

        connection._sendMessageForTesting = { message in
            guard case .steer(_, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            sawSteer = true
            pipe.handle(
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

        _ = handler.sendPrompt(
            text: "steer this way",
            attachments: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 600) {
            await MainActor.run { !handler.isSending }
        }
        #expect(sawSteer)

        let hasUserRow = reducer.items.contains {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(!hasUserRow)

        let hasQueueSystemEvent = reducer.items.contains { item in
            guard case .systemEvent(_, let text) = item else { return false }
            return text.contains("Message Queue")
        }
        #expect(!hasQueueSystemEvent)
    }

    @Test func sendPromptInBusyModeCanQueueFollowUpWithoutTimelineQueueNoise() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var sawFollowUp = false

        connection._sendMessageForTesting = { message in
            guard case .followUp(_, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            sawFollowUp = true
            pipe.handle(
                .turnAck(
                    command: "follow_up",
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        _ = handler.sendPrompt(
            text: "continue this",
            attachments: [],
            isBusy: true,
            busyStreamingBehavior: .followUp,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 600) {
            await MainActor.run { !handler.isSending }
        }
        #expect(sawFollowUp)

        let hasUserRow = reducer.items.contains {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(!hasUserRow)

        let hasQueueSystemEvent = reducer.items.contains { item in
            guard case .systemEvent(_, let text) = item else { return false }
            return text.contains("Message Queue")
        }
        #expect(!hasQueueSystemEvent)
    }

    @Test func sendPromptInBusyModeQueuesOptimisticallyBeforeTaskRuns() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")

        var queuedOperation: (@MainActor () async -> Void)?
        handler._launchTaskForTesting = { operation in
            queuedOperation = operation
        }

        _ = handler.sendPrompt(
            text: "steer this way",
            attachments: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        let queue = connection.messageQueueStore.queue(for: "s1")
        #expect(queue.steering.count == 1)
        #expect(queue.steering.first?.message == "steer this way")
        #expect(queue.followUp.isEmpty)
        #expect(queuedOperation != nil)
        #expect(reducer.items.isEmpty)
    }

    @Test func sendPromptInBusyModeFailureRollsBackOptimisticQueue() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")

        connection._sendMessageForTesting = { _ in
            throw WebSocketError.notConnected
        }

        _ = handler.sendPrompt(
            text: "steer this way",
            attachments: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        #expect(connection.messageQueueStore.queue(for: "s1").steering.count == 1)

        _ = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { !handler.isSending }
        }

        let queue = connection.messageQueueStore.queue(for: "s1")
        #expect(queue.steering.isEmpty)
    }

    @Test func sendPromptInBusyModeRefreshesQueueAfterSteer() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var sawSteer = false
        var sawQueueRefresh = false

        connection._sendMessageForTesting = { message in
            switch message {
            case .steer(_, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                sawSteer = true
                pipe.handle(
                    .turnAck(
                        command: "steer",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )

            case .getQueue(let requestId):
                sawQueueRefresh = true
                pipe.handle(
                    .commandResult(
                        command: "get_queue",
                        requestId: requestId,
                        success: true,
                        data: [
                            "version": 3,
                            "steering": [
                                [
                                    "id": "q1",
                                    "message": "steer this way",
                                    "createdAt": 1,
                                ],
                            ],
                            "followUp": [],
                        ],
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "steer this way",
            attachments: [],
            isBusy: true,
            connection: connection,
            reducer: reducer,
            sessionId: "s1"
        )

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { sawSteer && sawQueueRefresh }
        })

        let queue = connection.messageQueueStore.queue(for: "s1")
        #expect(queue.version == 3)
        #expect(queue.steering.count == 1)
    }

    @Test func sendPromptFailureTriggersReconnectCallbackOnce() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        _ = connection.configure(credentials: .init(host: "localhost", port: 7749, token: "sk_test", name: "Test"))

        var reconnectCalls = 0

        _ = handler.sendPrompt(
            text: "reconnect me",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            onNeedsReconnect: {
                reconnectCalls += 1
            }
        )

        _ = await waitForTestCondition { await MainActor.run { reconnectCalls > 0 } }
        #expect(reconnectCalls == 1)
    }

    @Test func sendPromptAutoTitlesUnnamedSessionFromFirstMessage() async {
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        // firstMessage is set on the session — the auto-title should use this,
        // not the prompt text being sent.
        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 0,
            firstMessage: "please fix websocket reconnect state drift"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)
        handler._generateSessionTitleForTesting = { _ in
            "Title: Fix websocket reconnect bug."
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "please fix websocket reconnect state drift",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setSessionNameValue != nil }
        }

        #expect(setSessionNameValue == "Fix websocket reconnect bug")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Fix websocket reconnect bug")
    }

    @Test func sendPromptAutoTitleCapsLength() async {
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 0,
            firstMessage: "debug reconnect flow"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)
        handler._generateSessionTitleForTesting = { _ in
            "Title: Investigate websocket reconnect state drift after background foreground transitions now"
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "debug reconnect flow",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setSessionNameValue != nil }
        }

        // "Title:" prefix stripped, capped at 48 chars at word boundary
        #expect(setSessionNameValue == "Investigate websocket reconnect state drift")
    }

    @Test func sendPromptDoesNotAutoTitleWhenSessionAlreadyNamed() async {
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: "Manual name", messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var titleGenerationCalls = 0
        var setSessionNameCalls = 0

        handler._generateSessionTitleForTesting = { _ in
            titleGenerationCalls += 1
            return "Should not apply"
        }

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName:
                setSessionNameCalls += 1
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "follow up work",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) { await MainActor.run { !handler.isSending } }
        #expect(titleGenerationCalls == 0)
        #expect(setSessionNameCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Manual name")
    }

    @Test func sendPromptDoesNotAutoTitleWhenFeatureDisabled() async {
        UserDefaults.standard.set("off", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 0,
            firstMessage: "write migration plan"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var titleGenerationCalls = 0
        var setSessionNameCalls = 0

        handler._generateSessionTitleForTesting = { _ in
            titleGenerationCalls += 1
            return "Should not apply"
        }

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName:
                setSessionNameCalls += 1
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "write migration plan",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) { await MainActor.run { !handler.isSending } }
        #expect(titleGenerationCalls == 0)
        #expect(setSessionNameCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == nil)
    }

    @Test func sendPromptAutoTitleSucceedsEvenWhenMessageCountGrowsFast() async {
        // Regression: fast models (codex) fire message_end events before the
        // on-device title LLM finishes, pushing messageCount past 1. The deferred
        // auto-title task should still apply the name as long as the session
        // remains untitled — it must not re-check messageCount <= 1.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 0,
            firstMessage: "implement loopback bridge for local process"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        // Simulate the title generator being slow (the real on-device LLM takes ~1-2s)
        handler._generateSessionTitleForTesting = { _ in
            // By the time this returns, messageCount will have grown
            return "Local process bridge"
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "implement loopback bridge for local process",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        // Simulate fast model: messageCount jumps to 5 shortly after prompt
        // dispatch (before the on-device title LLM finishes). This happens
        // because pi streams message_end events that increment the count.
        if var s = sessionStore.sessions.first(where: { $0.id == "s1" }) {
            s.messageCount = 5
            sessionStore.upsert(s)
        }

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setSessionNameValue != nil }
        }

        #expect(setSessionNameValue == "Local process bridge")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Local process bridge")
    }

    @Test func sendPromptAutoTitleUsesFirstMessageNotCurrentPrompt() async {
        // Regression: when the ChatView is recreated (navigation away/back),
        // the auto-title guard state is lost. A second prompt send would
        // re-trigger title generation. The title must always be derived from
        // session.firstMessage, not whatever the user typed on later turns.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        // Session has a firstMessage recorded but no name yet (simulates the
        // scenario where the first auto-title attempt was cancelled by cleanup).
        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 2,
            firstMessage: "fix the websocket reconnect drift"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var generatedFromText: String?
        handler._generateSessionTitleForTesting = { text in
            generatedFromText = text
            return "Fix Websocket Reconnect Drift"
        }

        var setSessionNameValue: String?
        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        // Send a DIFFERENT message (3rd turn) — auto-title should use
        // firstMessage, not this text.
        _ = handler.sendPrompt(
            text: "also check the retry logic",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setSessionNameValue != nil }
        }

        // Title was generated from the session's first message, not the current prompt
        #expect(generatedFromText == "fix the websocket reconnect drift")
        #expect(setSessionNameValue == "Fix Websocket Reconnect Drift")
    }

    @Test func sendPromptAutoTitleSkipsWhenNoFirstMessage() async {
        // When firstMessage is nil (e.g., server hasn't confirmed the first
        // message yet), the auto-title should not attempt generation.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var titleGenerationCalls = 0
        handler._generateSessionTitleForTesting = { _ in
            titleGenerationCalls += 1
            return "Should not fire"
        }

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "hello world",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) { await MainActor.run { !handler.isSending } }
        #expect(titleGenerationCalls == 0)
    }

    @Test func regressionHandlerRecreationAfterCleanupStillUsesFirstMessage() async {
        // Reproduces the exact bug from session data: user sends first message,
        // navigates away (cleanup), comes back (new handler), sends a different
        // message. The old code would generate a title from the second message.
        // Fixed: title always comes from session.firstMessage.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        // Session created with first message
        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 1,
            firstMessage: "in context view we shouldnt show these make sure add tests"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            default:
                break
            }
        }

        // --- handler1: user sent first message, then navigated away ---
        let titleGate = AsyncStream.makeStream(of: Void.self)
        defer { titleGate.continuation.finish() }

        let handler1 = ChatActionHandler()
        handler1._generateSessionTitleForTesting = { _ in
            // Simulate slow on-device model deterministically — won't finish before cleanup.
            for await _ in titleGate.stream { break }
            return "Should never complete"
        }

        _ = handler1.sendPrompt(
            text: "in context view we shouldnt show these make sure add tests",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: TimelineReducer(),
            sessionId: "s1",
            sessionStore: sessionStore
        )
        // User navigates away — cleanup fires
        handler1.cleanup()

        // --- handler2: user comes back, sends a different message ---
        let handler2 = ChatActionHandler()
        var generatedFromText: String?
        var setNameValue: String?

        handler2._generateSessionTitleForTesting = { text in
            generatedFromText = text
            return "Hide Context View Items"
        }

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setNameValue = name
            default:
                break
            }
        }

        // Second prompt text is completely different from firstMessage
        _ = handler2.sendPrompt(
            text: "can you check if pi supports register tool on demand",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: TimelineReducer(),
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setNameValue != nil }
        }

        // Title was generated from firstMessage, not the second prompt
        #expect(generatedFromText == "in context view we shouldnt show these make sure add tests")
        #expect(setNameValue == "Hide Context View Items")
    }

    @Test func regressionCleanupDoesNotCancelPendingAutoTitleTask() async {
        // Verifies that cleanup() lets pending auto-title tasks finish.
        // The old code cancelled them, causing the title to never be set
        // after navigation away from ChatView.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let handler = ChatActionHandler()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(
            id: "s1", name: nil, messageCount: 0,
            firstMessage: "fix timeline message ordering bug"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        var setNameValue: String?
        let titleReady = AsyncStream.makeStream(of: Void.self)

        handler._generateSessionTitleForTesting = { _ in
            // Wait until after cleanup fires, then return
            for await _ in titleReady.stream { break }
            return "Fix Timeline Message Ordering"
        }

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            case .setSessionName(let name, _):
                setNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "fix timeline message ordering bug",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: TimelineReducer(),
            sessionId: "s1",
            sessionStore: sessionStore
        )

        // Cleanup fires (user navigated away)
        handler.cleanup()

        // Now let the title generator finish — it should NOT be cancelled
        titleReady.continuation.yield()
        titleReady.continuation.finish()

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { setNameValue != nil }
        }

        #expect(setNameValue == "Fix Timeline Message Ordering")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Fix Timeline Message Ordering")
    }

    @Test func regressionSecondHandlerSkipsWhenFirstHandlerAlreadySetName() async {
        // After a successful auto-title, a recreated handler must not
        // re-generate — the session.name guard blocks it.
        UserDefaults.standard.set("onDevice", forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleProviderDefaultsKey)
        }

        let connection = ServerConnection()
        let sessionStore = SessionStore()

        // Session already has a name from a previous auto-title
        sessionStore.upsert(makeTestSession(
            id: "s1", name: "Fix Timeline Bug", messageCount: 3,
            firstMessage: "fix timeline message ordering bug"
        ))
        connection._setActiveSessionIdForTesting("s1")
        let pipe = TestEventPipeline(sessionId: "s1", connection: connection)

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                pipe.handle(
                    .turnAck(
                        command: "prompt",
                        clientTurnId: clientTurnId,
                        stage: .dispatched,
                        requestId: requestId,
                        duplicate: false
                    ),
                    sessionId: "s1"
                )
            default:
                break
            }
        }

        // New handler (simulates ChatView recreation)
        let handler = ChatActionHandler()
        var titleGenCalls = 0
        handler._generateSessionTitleForTesting = { _ in
            titleGenCalls += 1
            return "Should not apply"
        }

        _ = handler.sendPrompt(
            text: "commit everything",
            attachments: [],
            isBusy: false,
            connection: connection,
            reducer: TimelineReducer(),
            sessionId: "s1",
            sessionStore: sessionStore
        )

        _ = await waitForTestCondition(timeoutMs: 800) { await MainActor.run { !handler.isSending } }

        #expect(titleGenCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Fix Timeline Bug")
    }

    // MARK: - Model

    @Test func setModelFailureRollsBackAndSurfacesError() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let sessionId = "s1"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, model: "anthropic/old-model"))

        connection.wsClient?._setStatusForTesting(.connected)
        connection.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        connection.setFocusedSessionStreamEndpointKindForTesting("split_session")
        _ = await connection.sessionStreamCoordinator.streamSession(
            connection: connection,
            sessionId: sessionId,
            routeScope: .workspace("w1")
        )
        defer { connection.streamConsumptionTask?.cancel() }

        connection._sendMessageForTesting = { message in
            guard case .setModel(_, _, let requestId, _) = message,
                  let requestId else {
                return
            }
            _ = connection.commands.resolveCommandResult(
                command: "set_model",
                requestId: requestId,
                success: false,
                data: nil,
                error: "model unavailable"
            )
        }

        let requestedModel = ModelInfo(
            id: "new-model",
            name: "New model",
            provider: "anthropic",
            contextWindow: 200_000
        )
        handler.setModel(
            requestedModel,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )

        #expect(sessionStore.sessions.first(where: { $0.id == sessionId })?.model == "anthropic/new-model")
        #expect(await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run {
                sessionStore.sessions.first(where: { $0.id == sessionId })?.model == "anthropic/old-model"
            }
        })

        let hasModelError = reducer.items.contains { item in
            guard case .error(_, let message) = item else { return false }
            return message.contains("Failed to set model") && message.contains("model unavailable")
        }
        #expect(hasModelError)
    }

    @Test func persistSetModelOnMirroredSessionFailsWithoutSending() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let sessionId = "s1"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, model: "anthropic/old-model", runtime: .piTui))

        var sent = false
        connection._sendMessageForTesting = { _ in
            sent = true
        }

        handler.setModel(
            ModelInfo(id: "new-model", name: "New model", provider: "anthropic", contextWindow: 200_000),
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId,
            persist: true
        )

        #expect(!sent)
        #expect(sessionStore.sessions.first(where: { $0.id == sessionId })?.model == "anthropic/old-model")
        #expect(reducer.items.contains { item in
            guard case .error(_, let message) = item else { return false }
            return message == SessionRuntimeKind.persistUnsupportedMessage
        })
    }

    @Test func persistThinkingOnMirroredSessionFailsWithoutSending() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let sessionId = "s1"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, runtime: .piTui))

        var sent = false
        connection._sendMessageForTesting = { _ in
            sent = true
        }

        handler.setThinking(
            .high,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            persist: true
        )

        #expect(!sent)
        #expect(reducer.items.contains { item in
            guard case .error(_, let message) = item else { return false }
            return message == SessionRuntimeKind.persistUnsupportedMessage
        })
    }

    // MARK: - Rename

    @Test func renameTrimsInputAndSendsSetSessionName() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: "Old name", messageCount: 0))

        var sentName: String?

        connection._sendMessageForTesting = { message in
            if case .setSessionName(let name, _) = message {
                sentName = name
            }
        }

        handler.rename(
            "  Better session name  ",
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: "s1"
        )

        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Better session name")

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { sentName != nil }
        }

        #expect(sentName == "Better session name")
    }

    @Test func renameCollapsesWhitespaceAndLimitsLength() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: "Old", messageCount: 0))

        var sentName: String?
        connection._sendMessageForTesting = { message in
            if case .setSessionName(let name, _) = message {
                sentName = name
            }
        }

        let longName = "  Improve   TODO   planning    flow   for   release  candidate  and post-launch cleanup work  "
        handler.rename(
            longName,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: "s1"
        )

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { sentName != nil }
        }

        guard let sentName else {
            Issue.record("Expected set_session_name call")
            return
        }

        #expect(!sentName.contains("  "))
        #expect(sentName.count <= 48)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == sentName)
    }

    @Test func renameIgnoresWhitespaceOnlyInput() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: "Existing", messageCount: 0))

        var sendCalls = 0
        connection._sendMessageForTesting = { _ in
            sendCalls += 1
        }

        handler.rename(
            "   \n\t   ",
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: "s1"
        )

        #expect(sendCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Existing")
        #expect(reducer.items.isEmpty)
    }

    @Test func renameFailureRollsBackAndSurfacesError() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeTestSession(id: "s1", name: "Original", messageCount: 0))

        connection._sendMessageForTesting = { message in
            if case .setSessionName = message {
                throw WebSocketError.notConnected
            }
        }

        handler.rename(
            "Renamed",
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: "s1"
        )

        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Renamed")

        _ = await waitForTestCondition(timeoutMs: 800) {
            await MainActor.run { sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Original" }
        }

        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Original")

        let hasRenameError = reducer.items.contains { item in
            guard case .error(_, let message) = item else { return false }
            return message.contains("Rename failed")
        }
        #expect(hasRenameError)
    }

}
