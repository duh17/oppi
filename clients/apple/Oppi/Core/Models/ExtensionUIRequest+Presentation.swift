import Foundation

struct ExtensionUIResponsePayload: Equatable, Sendable {
    let value: String?
    let confirmed: Bool?
    let cancelled: Bool?

    init(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) {
        self.value = value
        self.confirmed = confirmed
        self.cancelled = cancelled
    }

    static let cancelled = ExtensionUIResponsePayload(cancelled: true)
}

enum ExtensionUIPresentation: Equatable, Sendable {
    case askCard
    case inlineAskCard
    case editorSheet
    case fallbackSheet
}

extension ExtensionUIRequest {
    var nativePresentation: ExtensionUIPresentation {
        switch method {
        case "ask":
            .askCard
        case "select" where options?.isEmpty == false:
            .inlineAskCard
        case "confirm", "input":
            .inlineAskCard
        case "editor":
            .editorSheet
        default:
            .fallbackSheet
        }
    }

    var askRequest: AskRequest? {
        switch nativePresentation {
        case .askCard:
            guard let questions = askQuestions, !questions.isEmpty else {
                return nil
            }

            return AskRequest(
                id: id,
                sessionId: sessionId,
                questions: questions,
                allowCustom: allowCustom ?? true,
                timeout: timeout
            )

        case .inlineAskCard:
            return inlineAskRequest

        case .editorSheet, .fallbackSheet:
            return nil
        }
    }

    var inlineAskRequest: AskRequest? {
        guard nativePresentation == .inlineAskCard else { return nil }

        let prompt = inlinePromptParts(optionLabels: options ?? [])
        let resolvedQuestion = prompt.question.isEmpty ? "Choose an option" : prompt.question

        let askOptions: [AskOption]
        let allowCustom: Bool
        let customPlaceholder: String?
        let responseEncoding: AskResponseEncoding
        switch method {
        case "select":
            let values = options ?? []
            guard !values.isEmpty else { return nil }
            askOptions = values.map {
                AskOption(value: $0, label: $0, description: prompt.optionDescriptions[$0])
            }
            allowCustom = false
            customPlaceholder = nil
            responseEncoding = .extensionSelect

        case "confirm":
            askOptions = [
                AskOption(value: Self.confirmValue, label: "Confirm"),
                AskOption(value: Self.cancelValue, label: "Cancel"),
            ]
            allowCustom = false
            customPlaceholder = nil
            responseEncoding = .extensionConfirm

        case "input":
            askOptions = []
            allowCustom = true
            customPlaceholder = placeholder
            responseEncoding = .extensionInput

        default:
            return nil
        }

        return AskRequest(
            id: id,
            sessionId: sessionId,
            questions: [
                AskQuestion(
                    id: Self.inlineQuestionId,
                    question: resolvedQuestion,
                    options: askOptions,
                    multiSelect: false
                ),
            ],
            allowCustom: allowCustom,
            timeout: timeout,
            customPlaceholder: customPlaceholder,
            responseEncoding: responseEncoding
        )
    }

    static let inlineQuestionId = "extension-ui"
    static let confirmValue = "__oppi_confirm"
    static let cancelValue = "__oppi_cancel"

    private struct InlinePromptParts {
        let question: String
        let optionDescriptions: [String: String]
    }

    private func inlinePromptParts(optionLabels: [String]) -> InlinePromptParts {
        let rawPrompt = [title, message]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")

        guard !rawPrompt.isEmpty, !optionLabels.isEmpty else {
            return InlinePromptParts(question: rawPrompt, optionDescriptions: [:])
        }

        let lines = rawPrompt.components(separatedBy: .newlines)
        guard let trailingDescriptions = Self.trailingOptionDescriptions(in: lines, optionLabels: optionLabels) else {
            return InlinePromptParts(question: rawPrompt, optionDescriptions: [:])
        }

        return InlinePromptParts(
            question: lines[..<trailingDescriptions.startIndex]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            optionDescriptions: trailingDescriptions.descriptions
        )
    }

    private static func trailingOptionDescriptions(
        in lines: [String],
        optionLabels: [String]
    ) -> (startIndex: Int, descriptions: [String: String])? {
        var index = lines.count
        while index > 0, lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index -= 1
        }

        var descriptions: [String: String] = [:]
        while index > 0,
              let parsed = parseIndentedOptionDescription(lines[index - 1], optionLabels: optionLabels) {
            descriptions[parsed.label] = parsed.description
            index -= 1
        }

        let requiredLabels = Set(optionLabels)
        guard !descriptions.isEmpty, requiredLabels.isSubset(of: Set(descriptions.keys)) else {
            return nil
        }

        return (startIndex: index, descriptions: descriptions)
    }

    private static func parseIndentedOptionDescription(
        _ line: String,
        optionLabels: [String]
    ) -> (label: String, description: String)? {
        guard line.hasPrefix("  ") || line.hasPrefix("\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for label in optionLabels.sorted(by: { $0.count > $1.count }) {
            let prefix = "\(label):"
            guard trimmed.hasPrefix(prefix) else { continue }
            let description = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { return nil }
            return (label, description)
        }

        return nil
    }
}

extension AskRequest {
    func responsePayload(from answers: [String: AskAnswer]) -> ExtensionUIResponsePayload? {
        switch responseEncoding {
        case .ask:
            return ExtensionUIResponsePayload(value: AskResponseEncoder.encode(answers))

        case .extensionSelect:
            guard case .single(let value) = answers[ExtensionUIRequest.inlineQuestionId] else {
                return .cancelled
            }
            return ExtensionUIResponsePayload(value: value)

        case .extensionConfirm:
            if answers[ExtensionUIRequest.inlineQuestionId] == .single(ExtensionUIRequest.confirmValue) {
                return ExtensionUIResponsePayload(confirmed: true)
            }
            return .cancelled

        case .extensionInput:
            switch answers[ExtensionUIRequest.inlineQuestionId] {
            case .custom(let value), .single(let value):
                return ExtensionUIResponsePayload(value: value)
            case .multi, nil:
                return .cancelled
            }
        }
    }
}
