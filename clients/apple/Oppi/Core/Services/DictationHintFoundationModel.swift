import Foundation
import FoundationModels
import OSLog

private let dictationHintFoundationModelLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "VoiceInput"
)

/// Optional on-device Foundation Model pass over the latest assistant reply.
/// Never blocks the mic; failures fall back to the cheap extracted list.
enum DictationHintFoundationModel {
    static func extract(from truncatedText: String) async -> [String] {
        let trimmed = truncatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            dictationHintFoundationModelLogger.debug(
                "Dictation Foundation Model unavailable; using cheap hints only"
            )
            return []
        }
        guard !Task.isCancelled else { return [] }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: prompt(for: trimmed),
                generating: DictationHintPhrases.self
            )
            guard !Task.isCancelled else { return [] }
            return DictationHintExtractor.merge(primary: [], extra: response.content.phrases)
        } catch is CancellationError {
            return []
        } catch {
            dictationHintFoundationModelLogger.debug(
                "Dictation Foundation Model hints failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private static let instructions = """
        Extract short dictation vocabulary from one assistant message.
        Return only 1-2 word phrases a person can say without pausing.
        Prefer identifiers, file names, and distinctive terms already in the message.
        Do not invent product names or copy sentences.
        """

    private static func prompt(for text: String) -> String {
        """
        Extract short dictation hints the user may speak next.

        <assistant_message>
        \(text)
        </assistant_message>
        """
    }
}

@Generable
struct DictationHintPhrases {
    @Guide(
        description: "Short one- or two-word phrases the user may speak next.",
        .maximumCount(100)
    )
    var phrases: [String]
}
