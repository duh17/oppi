import Foundation

/// Mac-only mapping from a local ask draft onto `ClientMessage`.
///
/// Payload encoding lives on `AskRequest.responsePayload(from:)`.
enum MacAskResponseEncoder {
    static func responseMessage(request: AskRequest, draft: MacAskResponseDraft) -> ClientMessage {
        let payload = request.responsePayload(from: draft.answers) ?? .cancelled
        return .extensionUIResponse(
            id: request.id,
            value: payload.value,
            confirmed: payload.confirmed,
            cancelled: payload.cancelled
        )
    }
}

struct MacAskResponseDraft: Equatable, Sendable {
    private(set) var answers: [String: AskAnswer] = [:]

    var isEmpty: Bool { answers.isEmpty }

    mutating func toggle(_ option: AskOption, question: AskQuestion) {
        if question.multiSelect {
            let existing: Set<String>
            if case .multi(let values) = answers[question.id] {
                existing = values
            } else {
                existing = []
            }
            var next = existing
            if next.contains(option.value) {
                next.remove(option.value)
            } else {
                next.insert(option.value)
            }
            answers[question.id] = next.isEmpty ? nil : .multi(next)
        } else {
            answers[question.id] = .single(option.value)
        }
    }

    mutating func setCustom(_ text: String, question: AskQuestion) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        answers[question.id] = trimmed.isEmpty ? nil : .custom(trimmed)
    }

    func isSelected(_ option: AskOption, question: AskQuestion) -> Bool {
        guard let answer = answers[question.id] else { return false }
        switch answer {
        case .single(let value):
            return value == option.value
        case .multi(let values):
            return values.contains(option.value)
        case .custom:
            return false
        }
    }

    func encodedValue() -> String {
        AskResponseEncoder.encode(answers)
    }
}
