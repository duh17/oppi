import Foundation

/// Adapts explicit audio lifecycle presentation into the existing native tool row
/// rendering model.
///
/// Keep this mapping outside `ToolTimelineRowContentView`: the row view should
/// render `ToolExpandedContent`, while lifecycle policy decides which voice
/// presentation state should be shown.
enum AudioTimelinePresentationAdapter {
    static func expandedContent(
        from presentation: AudioTimelinePresentation?,
        fallback: ToolPresentationBuilder.ToolExpandedContent?
    ) -> ToolPresentationBuilder.ToolExpandedContent? {
        guard let presentation else { return fallback }

        switch presentation {
        case .hidden:
            return fallback
        case .streamingTranscript(let text, let playbackBehavior):
            return .audioMessage(
                text: text,
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                playbackBehavior: playbackBehavior
            )
        case .speakingTranscript(let text, _):
            return .audioMessage(
                text: text,
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                playbackBehavior: .playNow
            )
        case .finalCard(let transcript, let attachmentID, _):
            return .audioMessage(
                text: transcript,
                attachmentId: attachmentID ?? "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                playbackBehavior: .tapToPlay
            )
        case .error(let message):
            return .status(message: message)
        }
    }
}
