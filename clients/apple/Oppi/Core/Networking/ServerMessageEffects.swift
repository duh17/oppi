import Foundation

struct ServerMessageCleanupEffects: Equatable {
    var stopSilenceWatchdog = false
    var clearAskSessionIds: Set<String> = []
    var clearExtensionDialogSessionIds: Set<String> = []
    var clearExtensionSurfaceSessionIds: Set<String> = []
    var clearMessageQueueSessionIds: Set<String> = []

    var isEmpty: Bool {
        !stopSilenceWatchdog
            && clearAskSessionIds.isEmpty
            && clearExtensionDialogSessionIds.isEmpty
            && clearExtensionSurfaceSessionIds.isEmpty
            && clearMessageQueueSessionIds.isEmpty
    }
}

struct ServerMessageQueueEffects: Equatable {
    var applyQueueState: MessageQueueState?
    var queueItemStarted: (kind: MessageQueueKind, item: MessageQueueItem, queueVersion: Int)?

    var isEmpty: Bool {
        applyQueueState == nil && queueItemStarted == nil
    }

    static func == (lhs: ServerMessageQueueEffects, rhs: ServerMessageQueueEffects) -> Bool {
        lhs.applyQueueState == rhs.applyQueueState
            && lhs.queueItemStarted?.kind == rhs.queueItemStarted?.kind
            && lhs.queueItemStarted?.item == rhs.queueItemStarted?.item
            && lhs.queueItemStarted?.queueVersion == rhs.queueItemStarted?.queueVersion
    }
}

struct ServerMessageUIEffects {
    var extensionRequest: ExtensionUIRequest?
    var extensionNotification: ExtensionUINotification?
    var isFocusedSession = false

    var isEmpty: Bool {
        extensionRequest == nil && extensionNotification == nil
    }
}

enum ServerMessageEffects {
    static func timelineEvents(for message: ServerMessage, sessionId: String) -> [AgentEvent] {
        switch message {
        case .agentStart:
            return [.agentStart(sessionId: sessionId)]
        case .agentEnd:
            return [.agentEnd(sessionId: sessionId)]
        case .textDelta(let delta):
            return [.textDelta(sessionId: sessionId, delta: delta)]
        case .thinkingDelta(let delta):
            return [.thinkingDelta(sessionId: sessionId, delta: delta)]
        case .messageEnd(let role, let content) where role == "assistant":
            return [.messageEnd(sessionId: sessionId, content: content)]
        case .error(let message, _, _):
            return [.error(sessionId: sessionId, message: message)]
        case .sessionEnded(let reason):
            return [.sessionEnded(sessionId: sessionId, reason: reason)]
        case .compactionStart(let reason):
            return [.compactionStart(sessionId: sessionId, reason: reason)]
        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            return [.compactionEnd(
                sessionId: sessionId,
                aborted: aborted,
                willRetry: willRetry,
                summary: summary,
                tokensBefore: tokensBefore
            )]
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            return [.retryStart(
                sessionId: sessionId,
                attempt: attempt,
                maxAttempts: maxAttempts,
                delayMs: delayMs,
                errorMessage: errorMessage
            )]
        case .retryEnd(let success, let attempt, let finalError):
            return [.retryEnd(
                sessionId: sessionId,
                success: success,
                attempt: attempt,
                finalError: finalError
            )]
        default:
            return []
        }
    }

    static func uiEffects(for message: ServerMessage, isFocusedSession: Bool) -> ServerMessageUIEffects {
        var effects = ServerMessageUIEffects(isFocusedSession: isFocusedSession)

        switch message {
        case .extensionUIRequest(let request):
            effects.extensionRequest = request

        case .extensionUINotification(let notification):
            effects.extensionNotification = notification

        default:
            break
        }

        return effects
    }

    static func queueEffects(for message: ServerMessage) -> ServerMessageQueueEffects {
        var effects = ServerMessageQueueEffects()

        switch message {
        case .queueState(let queue):
            effects.applyQueueState = queue

        case .queueItemStarted(let kind, let item, let queueVersion):
            effects.queueItemStarted = (kind, item, queueVersion)

        default:
            break
        }

        return effects
    }

    static func queueEffectsForCommandResult(
        command: String,
        success: Bool,
        data: JSONValue?
    ) -> ServerMessageQueueEffects {
        guard success,
              command == "get_queue" || command == "set_queue",
              let queue = decodeQueueStateFromCommandData(data) else {
            return ServerMessageQueueEffects()
        }
        return ServerMessageQueueEffects(applyQueueState: queue)
    }

    static func decodeQueueStateFromCommandData(_ data: JSONValue?) -> MessageQueueState? {
        guard let data else { return nil }
        do {
            let jsonData = try JSONEncoder().encode(data)
            return try JSONDecoder().decode(MessageQueueState.self, from: jsonData)
        } catch {
            return nil
        }
    }

    static func cleanupEffects(
        for message: ServerMessage,
        routedSessionId sessionId: String,
        isFocusedSession: Bool
    ) -> ServerMessageCleanupEffects {
        var effects = ServerMessageCleanupEffects()

        switch message {
        case .state(let session) where session.status.isTerminal:
            if isFocusedSession {
                effects.stopSilenceWatchdog = true
            }
            effects.clearAskSessionIds.insert(sessionId)
            effects.clearExtensionDialogSessionIds.insert(sessionId)

        case .sessionEnded:
            if isFocusedSession {
                effects.stopSilenceWatchdog = true
                effects.clearMessageQueueSessionIds.insert(sessionId)
            }
            effects.clearAskSessionIds.insert(sessionId)
            effects.clearExtensionSurfaceSessionIds.insert(sessionId)

        case .sessionDeleted(let deletedId):
            if isFocusedSession {
                effects.clearMessageQueueSessionIds.insert(deletedId)
            }
            effects.clearAskSessionIds.insert(deletedId)
            effects.clearExtensionSurfaceSessionIds.insert(deletedId)

        case .stopConfirmed:
            if isFocusedSession {
                effects.stopSilenceWatchdog = true
            }
            effects.clearAskSessionIds.insert(sessionId)

        default:
            break
        }

        return effects
    }
}
