import Foundation

/// A structured question request from the `ask` extension.
///
/// Agents use `ask` to pose clarifying questions with predefined options.
/// The iOS client renders these as an inline card in the chat input capsule.
struct AskRequest: Identifiable, Sendable, Equatable {
    let id: String
    let sessionId: String
    let questions: [AskQuestion]
    let allowCustom: Bool
    let timeout: Int? // ms
}

/// A single question within an ask request.
struct AskQuestion: Identifiable, Sendable, Equatable, Decodable {
    let id: String
    let question: String
    let options: [AskOption]
    let multiSelect: Bool

    init(id: String, question: String, options: [AskOption], multiSelect: Bool) {
        self.id = id
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decode([AskOption].self, forKey: .options)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, options, multiSelect
    }
}

/// A selectable option within an ask question.
struct AskOption: Sendable, Equatable, Decodable {
    let value: String
    let label: String
    let description: String?

    init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}
