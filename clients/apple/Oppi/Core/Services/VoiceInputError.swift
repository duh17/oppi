import Foundation

enum VoiceInputError: LocalizedError {
    case localeNotSupported(String)
    case remoteEndpointNotConfigured
    case remoteEndpointUnreachable(String)
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
        case .remoteEndpointUnreachable, .remoteNetwork:
            "network"
        case .remoteBadResponseStatus:
            "http_status"
        case .remoteInvalidResponse, .remoteDecodeFailed:
            "decode"
        case .remoteEndpointNotConfigured:
            "misconfigured"
        case .localeNotSupported, .internalError:
            "other"
        }
    }

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            "Speech recognition not supported for \(locale)"
        case .remoteEndpointNotConfigured:
            "Remote ASR endpoint is not configured. Open Settings → Voice Input."
        case .remoteEndpointUnreachable(let host):
            "Can’t reach remote ASR endpoint (\(host)). Check your server and network."
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
