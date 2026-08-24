import Testing
import Foundation
@testable import Oppi

@Suite("ChatActionHandler Recovery")
@MainActor
struct ChatActionHandlerRecoveryTests {

    @Test func slowHealthyModelMutationDoesNotResubmitPrompt() async {
        let sessionId = "slow-model-send"
        let handler = ChatActionHandler()
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let pipe = TestEventPipeline(sessionId: sessionId, connection: connection)
        connection._sendAckTimeoutForTesting = .milliseconds(25)
        connection._turnSendRetryDelayForTesting = .milliseconds(1)

        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))
        let sessionManager = ChatSessionManager(sessionId: sessionId)
        sessionManager._loadHistoryForTesting = { _, _ in nil }

        let streams = RecoveryScriptedStreamFactory()
        sessionManager._streamSessionForTesting = { _ in streams.makeStream() }

        let initialConnectTask = Task { @MainActor in
            await sessionManager.connect(connection: connection, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        connection.wsClient?._setStatusForTesting(.connected)
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { sessionManager.entryState == .streaming }
        })

        connection.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
        connection._setActiveSessionIdForTesting(sessionId)
        connection.setFocusedSessionStreamEndpointKindForTesting("split_session")
        _ = await connection.sessionStreamCoordinator.streamSession(
            connection: connection,
            sessionId: sessionId,
            routeScope: .workspace("w1")
        )

        var modelRequestId: String?
        var promptAttempts = 0
        var promptClientTurnIds: [String] = []
        connection._sendMessageForTesting = { message in
            switch message {
            case .setModel(_, _, let requestId, _):
                modelRequestId = requestId
            case .prompt(_, _, _, let requestId, let clientTurnId):
                guard let requestId, let clientTurnId else { return }
                promptAttempts += 1
                promptClientTurnIds.append(clientTurnId)
                if promptAttempts >= 3 {
                    pipe.handle(
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
            default:
                break
            }
        }

        let modelTask = Task { @MainActor in
            try? await connection.setModel(provider: "anthropic", modelId: "claude-sonnet-4")
        }
        #expect(await waitForMainActorCondition { modelRequestId != nil })
        #expect(await waitForMainActorCondition { !connection.commands.pendingCommandsByRequestId.isEmpty })

        var reconnectCalls = 0
        _ = handler.sendPrompt(
            text: "send once",
            images: [],
            isBusy: false,
            connection: connection,
            reducer: sessionManager.reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            onNeedsReconnect: {
                reconnectCalls += 1
            }
        )

        #expect(await waitForTestCondition(timeoutMs: 700) {
            await MainActor.run { !handler.isSending }
        })

        #expect(promptAttempts == 2)
        #expect(!promptClientTurnIds.isEmpty)
        #expect(Set(promptClientTurnIds).count == 1)
        #expect(reconnectCalls == 0)

        if let modelRequestId {
            _ = connection.commands.resolveCommandResult(
                command: "set_model",
                requestId: modelRequestId,
                success: true,
                data: ["provider": "anthropic", "id": "claude-sonnet-4"],
                error: nil
            )
        }
        await modelTask.value

        streams.finish(index: 0)
        connection.streamConsumptionTask?.cancel()
        await initialConnectTask.value
    }
}

@MainActor
private final class RecoveryScriptedStreamFactory {
    private var continuations: [AsyncStream<ServerMessage>.Continuation] = []

    var createdCount: Int { continuations.count }

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
