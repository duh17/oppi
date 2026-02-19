import Testing
import Foundation
import UIKit
@testable import Oppi

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

    @MainActor
    @Test func sendPromptAutoTitlesUnnamedSessionFromFirstMessage() async {
        UserDefaults.standard.set(true, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")
        handler._generateSessionTitleForTesting = { _ in
            "Title: Fix websocket reconnect bug."
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
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
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "please fix websocket reconnect state drift",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        await waitForCondition(timeoutMs: 800) {
            setSessionNameValue != nil
        }

        #expect(setSessionNameValue == "Fix websocket reconnect bug")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Fix websocket reconnect bug")
    }

    @MainActor
    @Test func sendPromptAutoTitlePrefixesTodoForTaskPrompts() async {
        UserDefaults.standard.set(true, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")
        handler._generateSessionTitleForTesting = { _ in
            "Ship migration checklist this week"
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
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
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "let's do a TODO list for workspace migration and rollout",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        await waitForCondition(timeoutMs: 800) {
            setSessionNameValue != nil
        }

        #expect(setSessionNameValue == "TODO: Ship migration checklist this week")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "TODO: Ship migration checklist this week")
    }

    @MainActor
    @Test func sendPromptAutoTitleLimitsWordCount() async {
        UserDefaults.standard.set(true, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")
        handler._generateSessionTitleForTesting = { _ in
            "Title: Investigate websocket reconnect state drift after background foreground transitions now"
        }

        var setSessionNameValue: String?

        connection._sendMessageForTesting = { message in
            switch message {
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
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
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "debug reconnect flow",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        await waitForCondition(timeoutMs: 800) {
            setSessionNameValue != nil
        }

        #expect(setSessionNameValue == "Investigate websocket reconnect state drift")
    }

    @MainActor
    @Test func sendPromptDoesNotAutoTitleWhenSessionAlreadyNamed() async {
        UserDefaults.standard.set(true, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: "Manual name", messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")

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
            case .setSessionName:
                setSessionNameCalls += 1
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "follow up work",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        await waitForCondition(timeoutMs: 800) { !handler.isSending }
        #expect(titleGenerationCalls == 0)
        #expect(setSessionNameCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Manual name")
    }

    @MainActor
    @Test func sendPromptDoesNotAutoTitleWhenFeatureDisabled() async {
        UserDefaults.standard.set(false, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")

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
            case .setSessionName:
                setSessionNameCalls += 1
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "write migration plan",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: reducer,
            sessionId: "s1",
            sessionStore: sessionStore
        )

        await waitForCondition(timeoutMs: 800) { !handler.isSending }
        #expect(titleGenerationCalls == 0)
        #expect(setSessionNameCalls == 0)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == nil)
    }

    @MainActor
    @Test func sendPromptAutoTitleSucceedsEvenWhenMessageCountGrowsFast() async {
        // Regression: fast models (codex) fire message_end events before the
        // on-device title LLM finishes, pushing messageCount past 1. The deferred
        // auto-title task should still apply the name as long as the session
        // remains untitled — it must not re-check messageCount <= 1.
        UserDefaults.standard.set(true, forKey: ChatActionHandler.autoTitleEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatActionHandler.autoTitleEnabledDefaultsKey) }

        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: nil, messageCount: 0))
        connection._setActiveSessionIdForTesting("s1")

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
            case .setSessionName(let name, _):
                setSessionNameValue = name
            default:
                break
            }
        }

        _ = handler.sendPrompt(
            text: "implement loopback bridge for local process",
            images: [],
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

        await waitForCondition(timeoutMs: 800) {
            setSessionNameValue != nil
        }

        #expect(setSessionNameValue == "Local process bridge")
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Local process bridge")
    }

    // MARK: - Rename

    @MainActor
    @Test func renameTrimsInputAndSendsSetSessionName() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: "Old name", messageCount: 0))

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

        await waitForCondition(timeoutMs: 800) {
            sentName != nil
        }

        #expect(sentName == "Better session name")
    }

    @MainActor
    @Test func renameCollapsesWhitespaceAndLimitsLength() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: "Old", messageCount: 0))

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

        await waitForCondition(timeoutMs: 800) {
            sentName != nil
        }

        guard let sentName else {
            Issue.record("Expected set_session_name call")
            return
        }

        #expect(!sentName.contains("  "))
        #expect(sentName.count <= 48)
        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == sentName)
    }

    @MainActor
    @Test func renameIgnoresWhitespaceOnlyInput() {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: "Existing", messageCount: 0))

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

    @MainActor
    @Test func renameFailureRollsBackAndSurfacesError() async {
        let handler = ChatActionHandler()
        let reducer = TimelineReducer()
        let connection = ServerConnection()
        let sessionStore = SessionStore()

        sessionStore.upsert(makeSession(id: "s1", name: "Original", messageCount: 0))

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

        await waitForCondition(timeoutMs: 800) {
            sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Original"
        }

        #expect(sessionStore.sessions.first(where: { $0.id == "s1" })?.name == "Original")

        let hasRenameError = reducer.items.contains { item in
            guard case .error(_, let message) = item else { return false }
            return message.contains("Rename failed")
        }
        #expect(hasRenameError)
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
    private func makeSession(id: String, name: String?, messageCount: Int) -> Session {
        let now = Date()
        return Session(
            id: id,
            workspaceId: nil,
            workspaceName: nil,
            name: name,
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: nil,
            messageCount: messageCount,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

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
