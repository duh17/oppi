import Foundation

/// An answer for a single question in an ask request.
enum AskAnswer: Equatable, Sendable {
    case single(String)
    case multi(Set<String>)
    case custom(String)
}

/// Encodes collected answers into the wire format for `extension_ui_response`.
///
/// Shared by iOS and Mac. `AskResponseEncoding` still decides how that JSON
/// (or a raw confirm/select/input value) is wrapped in `ClientMessage`.
///
/// - Single-select: `{"questionId": "value"}`
/// - Multi-select: `{"questionId": ["a", "b"]}`
/// - Custom text: `{"questionId": "free text"}`
/// - Ignored questions: omitted from map
enum AskResponseEncoder {
    /// Encode answers to a JSON string. Questions without answers are omitted.
    static func encode(_ answers: [String: AskAnswer]) -> String {
        var result: [String: Any] = [:]
        for (key, answer) in answers {
            switch answer {
            case .single(let value):
                result[key] = value
            case .multi(let values):
                result[key] = Array(values).sorted()
            case .custom(let text):
                result[key] = text
            }
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Build answer map from raw answers dict.
    /// Returns nil values for questions that were not answered (ignored).
    static func answerMap(
        answers: [String: AskAnswer],
        questions: [AskQuestion]
    ) -> [(question: AskQuestion, answer: AskAnswer?)] {
        questions.map { q in
            (question: q, answer: answers[q.id])
        }
    }
}
