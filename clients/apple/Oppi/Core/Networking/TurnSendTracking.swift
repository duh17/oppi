import Foundation

// MARK: - Turn Send Tracking

@MainActor
final class PendingTurnSend {
    let command: String
    let requestId: String
    let clientTurnId: String
    private let onAckStage: ((TurnAckStage) -> Void)?

    var latestStage: TurnAckStage?
    var waiter = SendAckWaiter()

    init(
        command: String,
        requestId: String,
        clientTurnId: String,
        onAckStage: ((TurnAckStage) -> Void)?
    ) {
        self.command = command
        self.requestId = requestId
        self.clientTurnId = clientTurnId
        self.onAckStage = onAckStage
    }

    func resetWaiter() {
        waiter = SendAckWaiter()
    }

    func notifyStage(_ stage: TurnAckStage) {
        onAckStage?(stage)
    }
}

// MARK: - Send Ack Waiter

@MainActor
final class SendAckWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let pendingResult {
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }

        pendingResult = result
    }
}

// MARK: - Send Ack Errors

enum SendAckError: LocalizedError {
    case timeout(command: String)
    case rejected(command: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .timeout(let command):
            return "\(command) acknowledgement timed out"
        case .rejected(let command, let reason):
            if let reason, !reason.isEmpty {
                return "\(command) rejected: \(reason)"
            }
            return "\(command) rejected"
        }
    }
}
