import Foundation
@testable import Oppi

@MainActor
final class ServerConnectionScenario {
    let connection: ServerConnection
    let activeSessionId: String

    /// Per-session pipeline for tests — mirrors ChatSessionManager ownership.
    let reducer = TimelineReducer()
    let coalescer = DeltaCoalescer()
    let toolCallCorrelator = ToolCallCorrelator()

    init(sessionId: String = "s1") {
        self.connection = makeTestConnection(sessionId: sessionId).conn
        self.activeSessionId = sessionId

        coalescer.onFlush = { [weak self] events in
            self?.reducer.processBatch(events)
        }
        coalescer.sessionId = sessionId
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
        let sid = sessionId ?? activeSessionId
        let storeResult = connection.applySharedStoreUpdate(for: message, sessionId: sid)
        // Only route to per-session pipeline for the active session
        if sid == activeSessionId {
            routeToTimeline(message, sessionId: sid, storeResult: storeResult)
            connection.handleActiveSessionUI(message, sessionId: sid)
        }
        if flushAfter {
            coalescer.flushNow()
        }
        return self
    }

    @discardableResult
    func whenFlush() -> Self {
        coalescer.flushNow()
        return self
    }

    func firstSessionStatus() -> SessionStatus? {
        connection.sessionStore.sessions.first?.status
    }

    func timelineItemCount(of kind: ScenarioTimelineItemKind) -> Int {
        reducer.items.filter { item in
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

    /// Route message to per-scenario timeline pipeline (mirrors ChatSessionManager.routeToTimeline).
    private func routeToTimeline(_ message: ServerMessage, sessionId: String, storeResult: ServerConnection.StoreUpdateResult = .notHandled) {
        switch message {
        case .agentStart:
            coalescer.receive(.agentStart(sessionId: sessionId))
        case .agentEnd:
            coalescer.receive(.agentEnd(sessionId: sessionId))
        case .textDelta(let delta):
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))
        case .thinkingDelta(let delta):
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))
        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            coalescer.receive(toolCallCorrelator.start(
                sessionId: sessionId, tool: tool, args: args,
                toolCallId: toolCallId, callSegments: callSegments
            ))
        case .toolOutput(let output, let isError, let toolCallId, let mode, let truncated, let totalBytes):
            coalescer.receive(toolCallCorrelator.output(
                sessionId: sessionId, output: output, isError: isError,
                toolCallId: toolCallId, mode: mode,
                truncated: truncated, totalBytes: totalBytes
            ))
        case .toolEnd(_, let toolCallId, let details, let isError, let resultSegments):
            coalescer.receive(toolCallCorrelator.end(
                sessionId: sessionId, toolCallId: toolCallId,
                details: details, isError: isError,
                resultSegments: resultSegments
            ))
        case .messageEnd(let role, let content):
            if role == "assistant" {
                coalescer.receive(.messageEnd(sessionId: sessionId, content: content))
            } else if role == "user", !content.isEmpty {
                if !reducer.hasUserMessage(matching: content) {
                    reducer.appendUserMessage(content)
                }
            }
        case .error(let msg, _, let fatal):
            coalescer.receive(.error(sessionId: sessionId, message: msg))
            if fatal { connection.fatalSetupError = true }
        case .sessionEnded(let reason):
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))
        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))
        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            coalescer.receive(.compactionEnd(sessionId: sessionId, aborted: aborted, willRetry: willRetry, summary: summary, tokensBefore: tokensBefore))
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))
        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))
        case .commandResult(let command, let requestId, let success, let data, let error):
            let consumed = connection.handleCommandResult(
                command: command, requestId: requestId,
                success: success, data: data, error: error,
                sessionId: sessionId
            )
            if !consumed {
                coalescer.receive(.commandResult(sessionId: sessionId, command: command, requestId: requestId, success: success, data: data, error: error))
            }
        case .permissionExpired(let id, _):
            if let request = storeResult.takenPermission {
                reducer.resolvePermission(id: id, outcome: .expired, tool: request.tool, summary: request.displaySummary)
            }
            coalescer.receive(.permissionExpired(id: id))
        case .permissionCancelled(let id):
            if let request = storeResult.takenPermission {
                reducer.resolvePermission(id: id, outcome: .cancelled, tool: request.tool, summary: request.displaySummary)
            }
        case .permissionRequest(let perm):
            coalescer.receive(.permissionRequest(perm))
        case .queueItemStarted(_, let item, _):
            reducer.appendUserMessage(item.message, images: item.images ?? [])
        case .stopRequested(_, let reason):
            reducer.appendSystemEvent(reason ?? "Stopping…")
        case .stopConfirmed(_, let reason):
            coalescer.receive(.agentEnd(sessionId: sessionId))
            reducer.appendSystemEvent(reason ?? "Stop confirmed")
        case .stopFailed(_, let reason):
            reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))
        case .state(let session):
            let previousStatus = connection.sessionStore.sessions.first(where: { $0.id == session.id })?.status
            if let previousStatus,
               previousStatus == .busy || previousStatus == .stopping,
               session.status == .ready || session.status == .stopped || session.status == .error {
                coalescer.receive(.agentEnd(sessionId: session.id))
            }
        default:
            break
        }
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
