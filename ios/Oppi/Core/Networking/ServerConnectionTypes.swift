import Foundation

// MARK: - RPC Correlation Types

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
}

@MainActor
final class PendingRPCRequest {
    let command: String
    let requestId: String
    let waiter = RPCResultWaiter()

    init(command: String, requestId: String) {
        self.command = command
        self.requestId = requestId
    }
}

struct RPCResultPayload: Sendable {
    let data: JSONValue?
}

@MainActor
final class RPCResultWaiter {
    private var continuation: CheckedContinuation<RPCResultPayload, Error>?
    private var pendingResult: Result<RPCResultPayload, Error>?

    func wait() async throws -> RPCResultPayload {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RPCResultPayload, Error>) in
            if let pendingResult {
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: Result<RPCResultPayload, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }

        pendingResult = result
    }
}

// MARK: - Error Types

enum RPCRequestError: LocalizedError {
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

enum ForkRequestError: LocalizedError, Equatable {
    case turnInProgress
    case noForkableMessages
    case entryNotForkable

    var errorDescription: String? {
        switch self {
        case .turnInProgress:
            return "Wait for this turn to finish before forking."
        case .noForkableMessages:
            return "No user messages available for forking yet."
        case .entryNotForkable:
            return "That message cannot be forked. Pick a user message from history."
        }
    }
}

// MARK: - RPC Registration Helpers

extension ServerConnection {
    func registerPendingTurnSend(_ pending: PendingTurnSend) {
        pendingTurnSendsByRequestId[pending.requestId] = pending
        pendingTurnRequestIdByClientTurnId[pending.clientTurnId] = pending.requestId
    }

    func unregisterPendingTurnSend(requestId: String, clientTurnId: String) {
        pendingTurnSendsByRequestId.removeValue(forKey: requestId)
        if pendingTurnRequestIdByClientTurnId[clientTurnId] == requestId {
            pendingTurnRequestIdByClientTurnId.removeValue(forKey: clientTurnId)
        }
    }

    func registerPendingRPCRequest(_ pending: PendingRPCRequest) {
        pendingRPCRequestsByRequestId[pending.requestId] = pending
    }

    func unregisterPendingRPCRequest(requestId: String) {
        pendingRPCRequestsByRequestId.removeValue(forKey: requestId)
    }

    func failPendingSendAcks(error: Error) {
        let pending = Array(pendingTurnSendsByRequestId.values)
        pendingTurnSendsByRequestId.removeAll()
        pendingTurnRequestIdByClientTurnId.removeAll()

        for send in pending {
            send.waiter.resolve(.failure(error))
        }
    }

    func failPendingRPCRequests(error: Error) {
        let pending = Array(pendingRPCRequestsByRequestId.values)
        pendingRPCRequestsByRequestId.removeAll()

        for request in pending {
            request.waiter.resolve(.failure(error))
        }
    }

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
