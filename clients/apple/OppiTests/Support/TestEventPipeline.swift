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
        guard conn.isFocusedSession(sessionId) else { return }

        if Self.isStopLifecycleMessage(message) {
            let storeResult = conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleActiveSessionUI(message, sessionId: sessionId, storeResult: storeResult)
            switch message {
            case .stopRequested(_, let reason):
                reducer.appendSystemEvent(reason ?? "Stopping…")
            case .stopConfirmed(_, let reason):
                coalescer.flushNow()
                reducer.finalizeTerminalArtifactsAsInterrupted()
                reducer.appendSystemEvent(reason ?? "Stop confirmed")
            case .stopFailed(_, let reason):
                reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))
            default: break
            }
            return
        }

        switch message {
        case .agentStart:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.agentStart(sessionId: sessionId))
            conn.silenceWatchdog.start()
        case .agentEnd:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.agentEnd(sessionId: sessionId))
        case .agentSettled:
            conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            coalescer.receive(.agentSettled(sessionId: sessionId))
            conn.silenceWatchdog.stop()
        case .textDelta(let delta, let contentIndex):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(.textDelta(
                sessionId: sessionId,
                delta: delta,
                contentIndex: contentIndex
            ))
        case .thinkingDelta(let delta, let contentIndex):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta, contentIndex: contentIndex))
        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.start(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId, callSegments: callSegments))
        case .toolUpdate(let tool, let args, let toolCallId, let callSegments):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.update(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId, callSegments: callSegments))
        case .toolOutput(let output, let isError, let toolCallId, let mode, let truncated, let totalBytes, let details):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.output(sessionId: sessionId, output: output, isError: isError, toolCallId: toolCallId, mode: mode, truncated: truncated, totalBytes: totalBytes, details: details))
        case .toolEnd(_, let toolCallId, let details, let isError, let resultSegments):
            conn.silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.end(sessionId: sessionId, toolCallId: toolCallId, details: details, isError: isError, resultSegments: resultSegments))
        case .messageEnd(let role, let content, let assistantContent, let entryId):
            if role == "assistant" {
                coalescer.receive(.messageEnd(
                    sessionId: sessionId,
                    content: content,
                    assistantContent: assistantContent,
                    entryId: entryId
                ))
            } else if role == "user", !content.isEmpty, !reducer.hasUserMessage(matching: content) {
                reducer.appendUserMessage(content)
            }
        case .error(let msg, _, let fatal):
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
        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore, let errorMessage):
            coalescer.receive(.compactionEnd(sessionId: sessionId, aborted: aborted, willRetry: willRetry, summary: summary, tokensBefore: tokensBefore, errorMessage: errorMessage))
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))
        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))
        case .commandResult(let command, let requestId, let success, let data, let error):
            if let requestId {
                if command == "prompt" || command == "steer" || command == "follow_up" {
                    _ = conn.commands.resolveTurnCommandResult(
                        command: command,
                        requestId: requestId,
                        success: success,
                        error: error
                    )
                } else {
                    _ = conn.commands.resolveCommandResult(
                        command: command,
                        requestId: requestId,
                        success: success,
                        data: data,
                        error: error
                    )
                }
            }

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
            let displayText = UserMessageAttachmentPresentation.makeTimelineText(
                text: item.message,
                uploadedAttachments: item.attachments ?? []
            )
            reducer.appendUserMessage(displayText, images: item.optimisticImages ?? [])
        case .state, .sessionSummary:
            let result = conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleActiveSessionUI(message, sessionId: sessionId, storeResult: result)
            if result.didTransitionOutOfRunning {
                coalescer.flushNow()
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }
        default:
            let result = conn.applySharedStoreUpdate(for: message, sessionId: sessionId)
            conn.handleActiveSessionUI(message, sessionId: sessionId, storeResult: result)
        }
    }

    private static func isStopLifecycleMessage(_ message: ServerMessage) -> Bool {
        switch message {
        case .stopRequested, .stopConfirmed, .stopFailed:
            return true
        default:
            return false
        }
    }
}

extension ServerConnection {
    func routeStreamMessage(_ streamMessage: StreamMessage) {
        routeStreamMessage(StreamFrameEvent(
            sessionId: streamMessage.sessionId,
            message: streamMessage.message,
            meta: InboundStreamMeta(
                seq: streamMessage.seq,
                currentSeq: streamMessage.currentSeq,
                receivedAtMs: Date.nowMs(),
                transportPath: transportPath
            )
        ))
    }
}
