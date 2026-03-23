import Foundation
@testable import Oppi

/// Test-only event pipeline that mirrors the per-session timeline pipeline
/// (ChatSessionManager.routeToTimeline + applySharedStoreUpdate + handleActiveSessionUI).
///
/// Owns reducer/coalescer/correlator. Production code has zero references to this type.
/// Call `handle(_:sessionId:)` instead of the removed `ServerConnection.handleServerMessage`.
@MainActor
final class TestEventPipeline {
    let reducer: TimelineReducer
    let coalescer: DeltaCoalescer
    let toolCallCorrelator: ToolCallCorrelator
    private weak var _connection: ServerConnection?

    var connection: ServerConnection {
        guard let conn = _connection else {
            fatalError("TestEventPipeline: connection was deallocated")
        }
        return conn
    }

    init(sessionId: String, connection: ServerConnection) {
        self.reducer = TimelineReducer()
        self.coalescer = DeltaCoalescer()
        self.toolCallCorrelator = ToolCallCorrelator()
        self._connection = connection

        coalescer.onFlush = { [weak self] events in
            self?.reducer.processBatch(events)
        }
        coalescer.sessionId = sessionId
    }

    func flushNow() {
        coalescer.flushNow()
    }

    // MARK: - Message Routing

    /// Full integration routing for tests — store updates + timeline + active UI.
    /// Mirrors the production path: applySharedStoreUpdate → routeToTimeline → handleActiveSessionUI.
    func handle(_ message: ServerMessage, sessionId: String) {
        let conn = connection
        guard sessionId == conn.activeSessionId else { return }

        if conn.isStopLifecycleMessage(message) {
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleActiveSessionUI(message, sessionId: sessionId)
            switch message {
            case .stopRequested(_, let reason):
                reducer.appendSystemEvent(reason ?? "Stopping…")
            case .stopConfirmed(_, let reason):
                coalescer.receive(.agentEnd(sessionId: sessionId))
                reducer.appendSystemEvent(reason ?? "Stop confirmed")
            case .stopFailed(_, let reason):
                reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))
            default: break
            }
            return
        }

        switch message {
        case .permissionRequest(let perm):
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.permissionRequest(perm))
        case .permissionExpired(let id, _):
            let result = conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            if let request = result.takenPermission {
                reducer.resolvePermission(id: id, outcome: .expired, tool: request.tool, summary: request.displaySummary)
            }
            coalescer.receive(.permissionExpired(id: id))
        case .permissionCancelled(let id):
            let result = conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            if let request = result.takenPermission {
                reducer.resolvePermission(id: id, outcome: .cancelled, tool: request.tool, summary: request.displaySummary)
            }
        case .agentStart:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.agentStart(sessionId: sessionId))
            conn.silenceWatchdog.start()
        case .agentEnd:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.agentEnd(sessionId: sessionId))
            conn.silenceWatchdog.stop()
        case .textDelta(let delta):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))
        case .thinkingDelta(let delta):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))
        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.start(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId, callSegments: callSegments))
        case .toolOutput(let output, let isError, let toolCallId, let mode, let truncated, let totalBytes):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.output(sessionId: sessionId, output: output, isError: isError, toolCallId: toolCallId, mode: mode, truncated: truncated, totalBytes: totalBytes))
        case .toolEnd(_, let toolCallId, let details, let isError, let resultSegments):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.end(sessionId: sessionId, toolCallId: toolCallId, details: details, isError: isError, resultSegments: resultSegments))
        case .messageEnd(let role, let content):
            if role == "assistant" {
                coalescer.receive(.messageEnd(sessionId: sessionId, content: content))
            } else if role == "user", !content.isEmpty, !reducer.hasUserMessage(matching: content) {
                reducer.appendUserMessage(content)
            }
        case .error(let msg, let code, let fatal):
            if code == ServerConnection.missingFullSubscriptionErrorCode || (code == nil && msg.contains("is not subscribed at level=full")) {
                conn.triggerFullSubscriptionRecovery(sessionId: sessionId, serverError: msg)
                break
            }
            coalescer.receive(.error(sessionId: sessionId, message: msg))
            conn.fatalSetupError = conn.fatalSetupError || fatal
        case .sessionEnded(let reason):
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.silenceWatchdog.stop()
            conn.messageQueueStore.clear(sessionId: sessionId)
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))
        case .sessionDeleted(let deletedId):
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.messageQueueStore.clear(sessionId: deletedId)
        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))
        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            coalescer.receive(.compactionEnd(sessionId: sessionId, aborted: aborted, willRetry: willRetry, summary: summary, tokensBefore: tokensBefore))
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))
        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))
        case .commandResult(let command, let requestId, let success, let data, let error):
            let consumed = conn.handleCommandResult(command: command, requestId: requestId, success: success, data: data, error: error, sessionId: sessionId)
            if !consumed {
                coalescer.receive(.commandResult(sessionId: sessionId, command: command, requestId: requestId, success: success, data: data, error: error))
            }
        case .connected(let session):
            conn.handleConnected(session)
        case .queueState(let queue):
            conn.messageQueueStore.apply(queue, for: sessionId)
        case .queueItemStarted(let kind, let item, let queueVersion):
            conn.messageQueueStore.applyQueueItemStarted(for: sessionId, kind: kind, item: item, queueVersion: queueVersion)
            reducer.appendUserMessage(item.message, images: item.images ?? [])
        case .state(let session):
            let previousStatus = conn.sessionStore.sessions.first(where: { $0.id == session.id })?.status
            let prevWsId = conn.sessionStore.sessions.first(where: { $0.id == session.id })?.workspaceId
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleState(session, previousWorkspaceId: prevWsId)
            if let previousStatus, previousStatus == .busy || previousStatus == .stopping,
               session.status == .ready || session.status == .stopped || session.status == .error {
                conn.screenAwakeController.setSessionActivity(false, sessionId: session.id)
                coalescer.receive(.agentEnd(sessionId: session.id))
                conn.silenceWatchdog.stop()
            }
        default:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleActiveSessionUI(message, sessionId: sessionId)
        }
    }
}
