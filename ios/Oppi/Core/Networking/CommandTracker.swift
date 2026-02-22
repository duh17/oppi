import Foundation

// MARK: - Command Correlation Types

/// Pending command awaiting a `command_result` response from the server.
@MainActor
final class PendingCommand {
    let command: String
    let requestId: String
    let waiter = CommandResultWaiter()

    init(command: String, requestId: String) {
        self.command = command
        self.requestId = requestId
    }
}

/// Payload delivered when a command result arrives.
struct CommandResultPayload: Sendable {
    let data: JSONValue?
}

/// Continuation-based waiter for a single command result.
///
/// Supports resolve-before-wait (buffered result) so callers
/// that resolve eagerly from the stream routing path don't race
/// against the async wait call.
@MainActor
final class CommandResultWaiter {
    private var continuation: CheckedContinuation<CommandResultPayload, Error>?
    private var pendingResult: Result<CommandResultPayload, Error>?

    func wait() async throws -> CommandResultPayload {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResultPayload, Error>) in
            if let pendingResult {
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: Result<CommandResultPayload, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }

        pendingResult = result
    }
}

// MARK: - Error Types

enum CommandRequestError: LocalizedError {
    case timeout(command: String)
    case rejected(command: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .timeout(let command):
            return "\(command) request timed out"
        case .rejected(let command, let reason):
            if let reason, !reason.isEmpty {
                return "\(command) rejected: \(reason)"
            }
            return "\(command) rejected"
        }
    }
}

// MARK: - CommandTracker

/// Tracks in-flight turn sends and command requests.
///
/// Owns the correlation dictionaries and register/unregister/fail methods
/// that were previously scattered across ServerConnection properties and
/// ServerConnectionTypes extension methods.
@MainActor
final class CommandTracker {
    // Turn send tracking
    private(set) var pendingTurnSendsByRequestId: [String: PendingTurnSend] = [:]
    private(set) var pendingTurnRequestIdByClientTurnId: [String: String] = [:]

    // Command request tracking
    private(set) var pendingCommandsByRequestId: [String: PendingCommand] = [:]

    // MARK: - Turn Sends

    func registerTurnSend(_ pending: PendingTurnSend) {
        pendingTurnSendsByRequestId[pending.requestId] = pending
        pendingTurnRequestIdByClientTurnId[pending.clientTurnId] = pending.requestId
    }

    func unregisterTurnSend(requestId: String, clientTurnId: String) {
        pendingTurnSendsByRequestId.removeValue(forKey: requestId)
        if pendingTurnRequestIdByClientTurnId[clientTurnId] == requestId {
            pendingTurnRequestIdByClientTurnId.removeValue(forKey: clientTurnId)
        }
    }

    func failAllTurnSends(error: Error) {
        let pending = Array(pendingTurnSendsByRequestId.values)
        pendingTurnSendsByRequestId.removeAll()
        pendingTurnRequestIdByClientTurnId.removeAll()

        for send in pending {
            send.waiter.resolve(.failure(error))
        }
    }

    // MARK: - Command Requests

    func registerCommand(_ pending: PendingCommand) {
        pendingCommandsByRequestId[pending.requestId] = pending
    }

    func unregisterCommand(requestId: String) {
        pendingCommandsByRequestId.removeValue(forKey: requestId)
    }

    func failAllCommands(error: Error) {
        let pending = Array(pendingCommandsByRequestId.values)
        pendingCommandsByRequestId.removeAll()

        for request in pending {
            request.waiter.resolve(.failure(error))
        }
    }

    // MARK: - Resolution

    /// Resolve a turn ack from `turn_ack` server message.
    /// Returns `true` if matched and resolved.
    func resolveTurnAck(
        command: String,
        clientTurnId: String,
        stage: TurnAckStage,
        requestId: String?,
        requiredStage: TurnAckStage
    ) -> Bool {
        let lookupRequestId = requestId ?? pendingTurnRequestIdByClientTurnId[clientTurnId]
        guard let lookupRequestId,
              let pending = pendingTurnSendsByRequestId[lookupRequestId],
              pending.command == command,
              pending.clientTurnId == clientTurnId else {
            return false
        }

        pending.latestStage = stage
        pending.notifyStage(stage)

        if stage.rank >= requiredStage.rank {
            pending.waiter.resolve(.success(()))
        }

        return true
    }

    /// Resolve a turn send via `command_result` fallback (for servers that
    /// only emit command_result without stage events).
    func resolveTurnCommandResult(
        command: String,
        requestId: String,
        success: Bool,
        error: String?
    ) -> Bool {
        guard let pending = pendingTurnSendsByRequestId[requestId],
              pending.command == command else {
            return false
        }

        if success {
            if pending.latestStage == nil {
                pending.latestStage = .dispatched
                pending.notifyStage(.dispatched)
                pending.waiter.resolve(.success(()))
            }
        } else {
            pending.waiter.resolve(.failure(SendAckError.rejected(command: command, reason: error)))
        }

        return true
    }

    /// Resolve a pending command request from `command_result`.
    /// Returns `true` if matched and resolved.
    func resolveCommandResult(
        command: String,
        requestId: String,
        success: Bool,
        data: JSONValue?,
        error: String?
    ) -> Bool {
        guard let pending = pendingCommandsByRequestId[requestId],
              pending.command == command else {
            return false
        }

        if success {
            pending.waiter.resolve(.success(CommandResultPayload(data: data)))
        } else {
            pending.waiter.resolve(.failure(CommandRequestError.rejected(command: command, reason: error)))
        }

        return true
    }

    // MARK: - Helpers

    static func isReconnectableSendError(_ error: Error) -> Bool {
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            }
        }

        if let ackError = error as? SendAckError {
            switch ackError {
            case .timeout:
                return true
            case .rejected:
                return false
            }
        }

        return false
    }
}
