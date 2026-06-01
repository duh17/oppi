import Foundation

extension ExtensionUIRequest {
    var shouldPresentAsInlineAskCard: Bool {
        method == "select" || method == "confirm" || method == "input"
    }

    var shouldPresentAsSheet: Bool {
        !shouldPresentAsInlineAskCard
    }

    var inlineAskRequest: AskRequest? {
        guard shouldPresentAsInlineAskCard else { return nil }

        let question = [title, message]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")
        let resolvedQuestion = question.isEmpty ? "Choose an option" : question

        let askOptions: [AskOption]
        let allowCustom: Bool
        let customPlaceholder: String?
        switch method {
        case "select":
            let values = options ?? []
            guard !values.isEmpty else { return nil }
            askOptions = values.map { AskOption(value: $0, label: $0) }
            allowCustom = false
            customPlaceholder = nil

        case "confirm":
            askOptions = [
                AskOption(value: Self.confirmValue, label: "Confirm"),
                AskOption(value: Self.cancelValue, label: "Cancel"),
            ]
            allowCustom = false
            customPlaceholder = nil

        case "input":
            askOptions = []
            allowCustom = true
            customPlaceholder = placeholder

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
            customPlaceholder: customPlaceholder
        )
    }

    static let inlineQuestionId = "extension-ui"
    static let confirmValue = "__oppi_confirm"
    static let cancelValue = "__oppi_cancel"
}
