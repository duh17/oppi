import Foundation

/// Mac-only mapping from a local ask draft onto `ClientMessage`.
///
/// Wire JSON for `.ask` answers lives in `AskResponseEncoder`. This type keeps
/// Mac response-encoding constants and the confirm/select/input wrappers.
enum MacAskResponseEncoder {
    static let inlineQuestionId = "extension-ui"
    static let confirmValue = "__oppi_confirm"
    static let cancelValue = "__oppi_cancel"

    static func responseMessage(request: AskRequest, draft: MacAskResponseDraft) -> ClientMessage {
        switch request.responseEncoding {
        case .ask:
            return .extensionUIResponse(id: request.id, value: draft.encodedValue())

        case .extensionSelect:
            guard case .single(let value) = draft.answers[inlineQuestionId] else {
                return .extensionUIResponse(id: request.id, cancelled: true)
            }
            return .extensionUIResponse(id: request.id, value: value)

        case .extensionConfirm:
            if draft.answers[inlineQuestionId] == .single(confirmValue) {
                return .extensionUIResponse(id: request.id, confirmed: true)
            }
            return .extensionUIResponse(id: request.id, cancelled: true)

        case .extensionInput:
            switch draft.answers[inlineQuestionId] {
            case .custom(let value), .single(let value):
                return .extensionUIResponse(id: request.id, value: value)
            case .multi, nil:
                return .extensionUIResponse(id: request.id, cancelled: true)
            }
        }
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
