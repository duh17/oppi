import Foundation
@testable import Oppi

@MainActor
final class ServerConnectionScenario {
    let connection: ServerConnection
    let activeSessionId: String

    init(sessionId: String = "s1") {
        self.connection = makeTestConnection(sessionId: sessionId)
        self.activeSessionId = sessionId
    }

    @discardableResult
    func givenStoredSession(
        id: String? = nil,
        status: SessionStatus,
        workspaceId: String? = nil,
        thinkingLevel: String? = nil
    ) -> Self {
        connection.sessionStore.upsert(
            makeTestSession(
                id: id ?? activeSessionId,
                workspaceId: workspaceId,
                status: status,
                thinkingLevel: thinkingLevel
            )
        )
        return self
    }

    @discardableResult
    func whenHandle(
        _ message: ServerMessage,
        sessionId: String? = nil,
        flushAfter: Bool = false
    ) -> Self {
        connection.handleServerMessage(message, sessionId: sessionId ?? activeSessionId)
        if flushAfter {
            connection.flushAndSuspend()
        }
        return self
    }

    @discardableResult
    func whenFlush() -> Self {
        connection.flushAndSuspend()
        return self
    }

    func firstSessionStatus() -> SessionStatus? {
        connection.sessionStore.sessions.first?.status
    }

    func timelineItemCount(of kind: ScenarioTimelineItemKind) -> Int {
        connection.reducer.items.filter { item in
            switch kind {
            case .assistantMessage:
                if case .assistantMessage = item { return true }
            case .systemEvent:
                if case .systemEvent = item { return true }
            case .error:
                if case .error = item { return true }
            case .thinking:
                if case .thinking = item { return true }
            case .toolCall:
                if case .toolCall = item { return true }
            }
            return false
        }.count
    }
}

enum ScenarioTimelineItemKind {
    case assistantMessage
    case systemEvent
    case error
    case thinking
    case toolCall
}

private enum AckCommand: CaseIterable {
    case prompt
    case steer
    case followUp

    var rawValue: String {
        switch self {
        case .prompt: return "prompt"
        case .steer: return "steer"
        case .followUp: return "follow_up"
        }
    }

    @MainActor
    func send(using connection: ServerConnection, text: String) async throws {
        switch self {
        case .prompt:
            try await connection.sendPrompt(text)
        case .steer:
            try await connection.sendSteer(text)
        case .followUp:
            try await connection.sendFollowUp(text)
        }
    }
}

private struct AckRequest {
    let command: String
    let requestId: String?
    let clientTurnId: String?
}

private func extractAckRequest(from message: ClientMessage) -> AckRequest? {
    switch message {
    case .prompt(_, _, _, let requestId, let clientTurnId):
        return AckRequest(command: "prompt", requestId: requestId, clientTurnId: clientTurnId)
    case .steer(_, _, let requestId, let clientTurnId):
        return AckRequest(command: "steer", requestId: requestId, clientTurnId: clientTurnId)
    case .followUp(_, _, let requestId, let clientTurnId):
        return AckRequest(command: "follow_up", requestId: requestId, clientTurnId: clientTurnId)
    default:
        return nil
    }
}

@MainActor
private func makeAckTestConnection(
    sessionId: String = "s1",
    timeout: Duration? = nil
) -> ServerConnection {
    let connection = ServerConnection()
    connection._setActiveSessionIdForTesting(sessionId)
    if let timeout {
        connection._sendAckTimeoutForTesting = timeout
    }
    return connection
}

private actor AckStageRecorder {
    private var stages: [TurnAckStage] = []

    func record(_ stage: TurnAckStage) {
        stages.append(stage)
    }

    func snapshot() -> [TurnAckStage] {
        stages
    }
}
