import Foundation

/// Polls `POST /pair/approval-status` until enrollment, a terminal failure, or cancel.
enum PairingEnrollment {
    static let pollInterval: Duration = .seconds(2)

    enum Failure: Error, Equatable, LocalizedError {
        case denied
        case expired
        case unknownApproval
        case cancelled
        case disconnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                "Pairing was denied on your other device."
            case .expired:
                "The pairing request expired. Request a fresh invite."
            case .unknownApproval:
                "This pairing request is no longer valid. Request a fresh invite."
            case .cancelled:
                "Pairing cancelled."
            case .disconnected:
                "Lost contact while waiting for approval. Request a fresh invite and try again."
            case .server(let message):
                message
            }
        }

        static func classify(_ error: Error) -> Failure {
            if error is CancellationError { return .cancelled }
            if let failure = error as? Failure { return failure }
            if let apiError = error as? APIError {
                switch apiError {
                case .server(let status, let message), .codedServer(let status, let message, _):
                    let code = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if status == 403, code.localizedCaseInsensitiveContains("pairing_denied") {
                        return .denied
                    }
                    if status == 410, code.localizedCaseInsensitiveContains("pairing_expired") {
                        return .expired
                    }
                    if status == 404, code.localizedCaseInsensitiveContains("unknown_approval") {
                        return .unknownApproval
                    }
                    return .server(UserFacingErrorText.normalize(message))
                case .invalidResponse:
                    return .server("Server returned an invalid pairing response. Request a fresh invite and try again.")
                }
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                     .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork:
                    return .disconnected
                default:
                    break
                }
            }
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? .disconnected : .server(message)
        }
    }

    /// Returns an enrolled credential even when the task was cancelled as the
    /// poll answered: the server already enrolled this device, so the caller
    /// must see the credential to revoke it before reporting the cancel.
    @MainActor
    static func complete(
        start: PairDeviceStart,
        poll: (String, String) async throws -> PairingApprovalPoll,
        onWaiting: ((Int64) -> Void)? = nil,
        pollInterval: Duration = pollInterval,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> PairDeviceResponse {
        switch start {
        case .enrolled(let response):
            return response
        case .approvalRequired(let required):
            guard required.status == "approval_required",
                  !required.approvalId.isEmpty,
                  !required.pendingToken.isEmpty else {
                throw Failure.server("Server returned an invalid pairing response. Request a fresh invite and try again.")
            }
            onWaiting?(required.expiresAt)
            while true {
                try Task.checkCancellation()
                do {
                    try await sleep(pollInterval)
                } catch is CancellationError {
                    throw Failure.cancelled
                }
                try Task.checkCancellation()
                let result: PairingApprovalPoll
                do {
                    result = try await poll(required.approvalId, required.pendingToken)
                } catch is CancellationError {
                    throw Failure.cancelled
                } catch {
                    throw Failure.classify(error)
                }
                switch result {
                case .enrolled(let response):
                    return response
                case .pending(let expiresAt):
                    onWaiting?(expiresAt)
                }
            }
        }
    }
}
