import Testing
import Foundation
@testable import Oppi

@Suite("ChatActionHandler Recovery")
@MainActor
struct ChatActionHandlerRecoveryTests {

    @Test func promptAutoRetriesAfterSessionReconnect() async {
        let sessionId = "recover-send"
        let handler = ChatActionHandler()
        handler._reconnectRecoveryTimeoutForTesting = .seconds(2)
        handler._reconnectRecoveryPollIntervalForTesting = .milliseconds(25)

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let sessionManager = ChatSessionManager(sessionId: sessionId)
        sessionManager._loadHistoryForTesting = { _, _ in nil }

        let streams = RecoveryScriptedStreamFactory()
        sessionManager._streamSessionForTesting = { _ in streams.makeStream() }

        let initialConnectTask = Task { @MainActor in
            await sessionManager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        connection.wsClient?._setStatusForTesting(.connected)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { sessionManager.entryState == .streaming }
        })

        var promptAttempts = 0
        connection._sendMessageForTesting = { message in
            guard case .prompt(_, _, _, let requestId, let clientTurnId) = message,
                  let requestId,
                  let clientTurnId else {
                return
            }

            promptAttempts += 1
            if promptAttempts <= 2 {
                // MessageSender retries reconnectable send errors once before
                // surfacing them. Fail both transport attempts so the handler's
                // recovery path has to drive reconnect + resend.
                throw WebSocketError.notConnected
            }

            connection.handleServerMessage(
                .turnAck(
                    command: "prompt",
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: sessionId
            )
        }

        var reconnectCalls = 0
        var restoredText: String?
        var reconnectTask: Task<Void, Never>?

        _ = handler.sendPrompt(
            text: "hello after reconnect",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: sessionManager.reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            onAsyncFailure: { text, _ in
                restoredText = text
            },
            onNeedsReconnect: {
                reconnectCalls += 1
                connection.wsClient?._setStatusForTesting(.reconnecting(attempt: reconnectCalls))
                streams.finish(index: 0)
                sessionManager.reconnect()
                reconnectTask = Task { @MainActor in
                    await sessionManager.connect(connection: connection, sessionStore: sessionStore)
                }
                Task { @MainActor in
                    _ = await streams.waitForCreated(2)
                    connection.wsClient?._setStatusForTesting(.connected)
                    streams.yield(index: 1, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))
                }
            }
        )

        #expect(await waitForTestCondition(timeoutMs: 2_000) {
            await MainActor.run { !handler.isSending }
        })

        #expect(promptAttempts == 3)
        #expect(reconnectCalls >= 1)
        #expect(restoredText == nil)
        #expect(handler.reconnectFailureMessage == nil)
        #expect(handler.sendProgressText == nil || handler.sendProgressText == "Dispatched…")

        // With per-session reducers, reconnect resets the reducer.
        // The important invariant: send completed successfully (promptAttempts == 3,
        // no failure message). User message may or may not be in the reducer
        // depending on timing of reconnect vs optimistic append.

        streams.finish(index: 1)
        await initialConnectTask.value
        await reconnectTask?.value
    }

    @Test func promptRecoveryTimeoutRestoresComposerAndExplainsStage() async {
        let sessionId = "recover-timeout"
        let handler = ChatActionHandler()
        handler._reconnectRecoveryTimeoutForTesting = .milliseconds(250)
        handler._reconnectRecoveryPollIntervalForTesting = .milliseconds(25)

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let sessionManager = ChatSessionManager(sessionId: sessionId)
        sessionManager._loadHistoryForTesting = { _, _ in nil }

        let streams = RecoveryScriptedStreamFactory()
        sessionManager._streamSessionForTesting = { _ in streams.makeStream() }

        let initialConnectTask = Task { @MainActor in
            await sessionManager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        connection.wsClient?._setStatusForTesting(.connected)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { sessionManager.entryState == .streaming }
        })

        connection._sendMessageForTesting = { message in
            guard case .prompt = message else { return }
            throw WebSocketError.notConnected
        }

        var restoredText: String?
        var reconnectTask: Task<Void, Never>?

        _ = handler.sendPrompt(
            text: "please survive reconnect",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: sessionManager.reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            onAsyncFailure: { text, _ in
                restoredText = text
            },
            onNeedsReconnect: {
                connection.wsClient?._setStatusForTesting(.reconnecting(attempt: 1))
                streams.finish(index: 0)
                sessionManager.reconnect()
                reconnectTask = Task { @MainActor in
                    await sessionManager.connect(connection: connection, sessionStore: sessionStore)
                }
                Task { @MainActor in
                    _ = await streams.waitForCreated(2)
                    connection.wsClient?._setStatusForTesting(.connected)
                    // Intentionally do not emit `.connected` for stream #2.
                    // Transport recovers, but session restore never finishes.
                }
            }
        )

        #expect(await waitForTestCondition(timeoutMs: 1_500) {
            await MainActor.run { !handler.isSending }
        })

        #expect(restoredText == "please survive reconnect")
        #expect(handler.sendProgressText == nil)
        #expect(handler.reconnectFailureMessage?.contains("waking the session took too long") == true)

        let userMessages = sessionManager.reducer.items.filter {
            if case .userMessage = $0 { return true }
            return false
        }
        #expect(userMessages.isEmpty)

        streams.finish(index: 1)
        await initialConnectTask.value
        await reconnectTask?.value
    }

    @Test func stoppedSessionDuringRecoveryTellsUserToResume() async {
        let sessionId = "recover-stopped"
        let handler = ChatActionHandler()
        handler._reconnectRecoveryTimeoutForTesting = .seconds(1)
        handler._reconnectRecoveryPollIntervalForTesting = .milliseconds(25)

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let sessionManager = ChatSessionManager(sessionId: sessionId)
        sessionManager._loadHistoryForTesting = { _, _ in nil }

        let streams = RecoveryScriptedStreamFactory()
        sessionManager._streamSessionForTesting = { _ in streams.makeStream() }

        let initialConnectTask = Task { @MainActor in
            await sessionManager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        connection.wsClient?._setStatusForTesting(.connected)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, status: .ready)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { sessionManager.entryState == .streaming }
        })

        connection._sendMessageForTesting = { message in
            guard case .prompt = message else { return }
            throw WebSocketError.notConnected
        }

        var restoredText: String?
        var reconnectTask: Task<Void, Never>?

        _ = handler.sendPrompt(
            text: "resume me",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: sessionManager.reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            onAsyncFailure: { text, _ in
                restoredText = text
            },
            onNeedsReconnect: {
                connection.wsClient?._setStatusForTesting(.reconnecting(attempt: 1))
                streams.finish(index: 0)
                sessionManager.reconnect()
                reconnectTask = Task { @MainActor in
                    await sessionManager.connect(connection: connection, sessionStore: sessionStore)
                }
                Task { @MainActor in
                    _ = await streams.waitForCreated(2)
                    sessionStore.upsert(makeTestSession(id: sessionId, status: .stopped))
                }
            }
        )

        #expect(await waitForTestCondition(timeoutMs: 1_500) {
            await MainActor.run { !handler.isSending }
        })

        #expect(restoredText == "resume me")
        #expect(handler.reconnectFailureMessage?.contains("Tap Resume to continue") == true)

        streams.finish(index: 1)
        await initialConnectTask.value
        if let reconnectTask {
            await reconnectTask.value
        }
    }
}

@MainActor
private final class RecoveryScriptedStreamFactory {
    private var continuations: [AsyncStream<ServerMessage>.Continuation] = []

    func makeStream() -> AsyncStream<ServerMessage> {
        AsyncStream { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCreated(_ count: Int, timeoutMs: Int = 1_000) async -> Bool {
        await waitForTestCondition(timeoutMs: timeoutMs) {
            await MainActor.run { self.continuations.count >= count }
        }
    }

    func yield(index: Int, message: ServerMessage) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(message)
    }

    func finish(index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }
}
