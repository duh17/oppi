import Foundation

/// Adapts explicit audio lifecycle presentation into the existing native tool row
/// rendering model.
///
/// Keep this mapping outside `ToolTimelineRowContentView`: the row view should
/// render `ToolExpandedContent`, while lifecycle policy decides which voice
/// presentation state should be shown.
enum VoiceTimelinePresentationAdapter {
    static func expandedContent(
        from presentation: VoiceTimelinePresentation?,
        fallback: ToolPresentationBuilder.ToolExpandedContent?
    ) -> ToolPresentationBuilder.ToolExpandedContent? {
        guard let presentation else { return fallback }

        switch presentation {
        case .hidden:
            return fallback
        case .streamingTranscript(let text, let delivery):
            return .voiceMessage(
                text: text,
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: delivery
            )
        case .speakingTranscript(let text, _):
            return .voiceMessage(
                text: text,
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: .directSpeak
            )
        case .finalCard(let transcript, let attachmentID, _):
            return .voiceMessage(
                text: transcript,
                attachmentId: attachmentID ?? "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: .voiceMessage
            )
        case .error(let message):
            return .status(message: message)
        }
    }
}
