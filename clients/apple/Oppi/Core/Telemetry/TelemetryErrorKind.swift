import Foundation

/// The one classifier from a thrown error to the catalog `error_kind`
/// vocabulary. Values are coarse classes, never Swift type names, error text,
/// or numeric codes.
enum TelemetryErrorKind {
    static func classify(_ error: Error) -> TelemetryTag.ErrorKind {
        if let unconfirmed = error as? TurnSendUnconfirmedError {
            return classify(unconfirmed.underlying)
        }
        if error is CancellationError {
            return .cancelled
        }
        if let voiceError = error as? VoiceInputError {
            return voiceError.telemetryKind
        }
        if let commandError = error as? CommandRequestError {
            switch commandError {
            case .timeout: return .timeout
            case .rejected: return .other
            }
        }
        if let socketError = error as? WebSocketError {
            switch socketError {
            case .notConnected: return .notConnected
            case .sendTimeout: return .timeout
            case .encodingFailed: return .other
            }
        }
        if let quickSessionError = error as? QuickSessionError {
            switch quickSessionError {
            case .noConnection: return .noConnection
            case .noWorkspace: return .noWorkspace
            case .agentLaunchFailed: return .agentLaunchFailed
            }
        }
        if let shareError = error as? ShareSessionRequestError {
            switch shareError {
            case .timedOut: return .timeout
            case .failed: return .requestFailed
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return .network
            default: return .urlError
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .invalidResponse: return .decode
            case .server, .codedServer: return .httpStatus
            }
        }
        if error is DecodingError {
            return .decode
        }
        return .other
    }
}
