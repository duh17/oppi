import Foundation

/// How composer answers are converted back to Pi extension UI response payloads.
enum AskResponseEncoding: Equatable, Sendable {
    case ask
    case extensionSelect
    case extensionConfirm
    case extensionInput
}

/// A structured question request from the `ask` extension.
///
/// Agents use `ask` to pose clarifying questions with predefined options.
/// The iOS client renders these as an inline card in the chat input capsule.
struct AskRequest: Identifiable, Sendable, Equatable, Decodable {
    let id: String
    let sessionId: String
    let questions: [AskQuestion]
    let allowCustom: Bool
    let timeout: Int? // ms
    let workspaceId: String?
    let customPlaceholder: String?
    let responseEncoding: AskResponseEncoding

    init(
        id: String,
        sessionId: String,
        questions: [AskQuestion],
        allowCustom: Bool,
        timeout: Int?,
        workspaceId: String? = nil,
        customPlaceholder: String? = nil,
        responseEncoding: AskResponseEncoding = .ask
    ) {
        self.id = id
        self.sessionId = sessionId
        self.questions = questions
        self.allowCustom = allowCustom
        self.timeout = timeout
        self.workspaceId = workspaceId
        self.customPlaceholder = customPlaceholder
        self.responseEncoding = responseEncoding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        questions = try c.decode([AskQuestion].self, forKey: .questions)
        allowCustom = try c.decodeIfPresent(Bool.self, forKey: .allowCustom) ?? true
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        customPlaceholder = try c.decodeIfPresent(String.self, forKey: .customPlaceholder)
        responseEncoding = .ask
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, questions, allowCustom, timeout, workspaceId, customPlaceholder
    }
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
