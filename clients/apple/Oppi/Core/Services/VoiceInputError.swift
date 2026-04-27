import Foundation

enum VoiceInputError: LocalizedError {
    case localeNotSupported(String)
    case serverNotConnected
    case serverAsrUnavailable
    case remoteRequestTimedOut
    case remoteNetwork(String?)
    case remoteBadResponseStatus(Int)
    case remoteInvalidResponse
    case remoteDecodeFailed
    case internalError(String)

    var telemetryCategory: String {
        switch self {
        case .remoteRequestTimedOut:
            "timeout"
        case .remoteNetwork:
            "network"
        case .remoteBadResponseStatus:
            "http_status"
        case .remoteInvalidResponse, .remoteDecodeFailed:
            "decode"
        case .serverNotConnected, .serverAsrUnavailable:
            "misconfigured"
        case .localeNotSupported, .internalError:
            "other"
        }
    }

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            "Speech recognition not supported for \(locale)"
        case .serverNotConnected:
            "Server dictation is not connected. Connect to an Oppi server first."
        case .serverAsrUnavailable:
            "Server dictation is unavailable on this server. Check the ASR server and reconnect."
        case .remoteRequestTimedOut:
            "Remote ASR request timed out. Check server load or network latency."
        case .remoteNetwork:
            "Network error while contacting remote ASR."
        case .remoteBadResponseStatus(let statusCode):
            "Remote ASR returned HTTP \(statusCode)."
        case .remoteInvalidResponse:
            "Remote ASR returned an invalid response."
        case .remoteDecodeFailed:
            "Remote ASR response could not be decoded."
        case .internalError(let message):
            message
        }
    }
}
