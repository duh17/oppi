import Foundation

/// UI-free composer dictation policy shared by Apple clients.
///
/// Protocol DTOs stay in `ClientMessage` / `ServerMessage`. This type owns
/// the stream path, draft prefixing, and closed-failure copy. Platform apps
/// own sockets, TCC, and paint.
enum DictationComposerPolicy {
    /// Owner-authenticated dictation WebSocket. Never put `sk_` in this path.
    static let streamPath = "/dictation/stream"

    static let microphoneDeniedMessage = "Microphone permission denied"

    static let unavailableMessage =
        "Server dictation is not connected. Connect to an Oppi server first."

    static let readyTimeoutMessage =
        "Remote ASR request timed out. Check server load or network latency."

    static let disconnectMessage = "Dictation connection lost"

    /// Preserve existing whitespace; otherwise insert one space before the transcript.
    static func prefix(for base: String) -> String {
        if base.isEmpty || base.last?.isWhitespace == true {
            return base
        }
        return base + " "
    }

    static func composedDraft(prefix: String, transcript: String) -> String {
        prefix + transcript
    }
}
