import Foundation

/// Pure formatting logic for tool call display.
///
/// Extracted from timeline row rendering so it can be unit-tested without
/// view instantiation. Maps structured args to display strings.
enum ToolCallFormatting {

    // MARK: - Arg Extraction

    /// Extract file path from structured args.
    static func filePath(from args: [String: JSONValue]?) -> String? {
        args?["path"]?.stringValue
    }

    // MARK: - Display Formatting

    /// Collapse directory components to initials while keeping the final file name intact.
    static func breadcrumbDisplayPath(_ displayPath: String) -> String {
        let split = splitLineRangeSuffix(displayPath)
        let path = split.path.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1,
              let fileName = components.last,
              !fileName.isEmpty else {
            return displayPath
        }

        let directoryCrumbs = components.dropLast().enumerated().compactMap { index, component -> String? in
            if component.isEmpty {
                return index == 0 ? "" : nil
            }
            if component == "~" || component == "." || component == ".." {
                return component
            }
            guard let first = component.first else { return nil }
            return String(first)
        }
        let directory = directoryCrumbs.joined(separator: "/")
        guard !directory.isEmpty else { return fileName + split.suffix }
        return directory + "/" + fileName + split.suffix
    }

    /// Return the final file name, preserving any read line range suffix.
    static func fileNameDisplayPath(_ displayPath: String) -> String {
        let split = splitLineRangeSuffix(displayPath)
        let path = split.path.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let fileName = components.last,
              !fileName.isEmpty else {
            return displayPath
        }
        return fileName + split.suffix
    }

    private static func splitLineRangeSuffix(_ displayPath: String) -> (path: String, suffix: String) {
        guard let range = displayPath.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) else {
            return (displayPath, "")
        }
        return (
            String(displayPath[..<range.lowerBound]),
            String(displayPath[range.lowerBound...])
        )
    }

    /// Parse a value from the flat argsSummary string.
    ///
    /// Fallback for when structured args are unavailable. Looks for `key: value`
    /// patterns in the comma-separated summary string.
    static func parseArgValue(_ key: String, from argsSummary: String) -> String? {
        let prefix = "\(key): "
        guard let range = argsSummary.range(of: prefix) else { return nil }
        let after = argsSummary[range.upperBound...]
        if let commaRange = after.range(of: ", ") {
            return String(after[..<commaRange.lowerBound])
        }
        return String(after)
    }

    /// Format byte count for display (e.g. "1.2 KB", "3.4 MB").
    static func formatBytes(_ bytes: Int) -> String {
        SessionFormatting.byteCount(bytes)
    }

    /// Compact elapsed time shared by iOS and Mac tool-row chrome.
    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds > 0
                ? "\(minutes)m \(remainingSeconds)s"
                : "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0
            ? "\(hours)h \(remainingMinutes)m"
            : "\(hours)h"
    }

    // MARK: - Ask Formatting

    static func askCollapsedTitle(
        args: [String: JSONValue]?,
        details: JSONValue?,
        argsSummary: String
    ) -> String {
        let questions = askQuestions(args: args, details: details)
        guard !questions.isEmpty else {
            let trimmed = singleLine(argsSummary)
            return trimmed.isEmpty ? "Ask" : trimmed
        }

        if questions.count == 1 {
            return "1 question"
        }
        return "\(questions.count) questions"
    }

    static func askAnswerSummary(details: JSONValue?) -> String {
        guard let answers = askAnswers(from: details) else { return "" }
        if askAllIgnored(details) { return "" }

        let questions = askQuestions(args: nil, details: details)
        guard !questions.isEmpty else {
            return answers.keys.sorted().compactMap { key in
                guard let value = answers[key] else { return nil }
                return "**Q:** \(singleLine(key))\n**A:** \(displayAnswer(value, question: nil))"
            }.joined(separator: "\n\n")
        }

        var seenQuestionIDs = Set<String>()
        var sections: [String] = []

        for question in questions {
            seenQuestionIDs.insert(question.id)
            if question.options.isEmpty {
                let answer = answers[question.id].map { displayAnswer($0, question: question) } ?? "(skipped)"
                sections.append("**Q:** \(question.displayQuestion)\n**A:** \(answer)")
            } else {
                sections.append(askChecklistSection(question: question, answer: answers[question.id]))
            }
        }

        for key in answers.keys.sorted() where !seenQuestionIDs.contains(key) {
            guard let value = answers[key] else { continue }
            sections.append("**Q:** \(singleLine(key))\n**A:** \(displayAnswer(value, question: nil))")
        }

        return sections.joined(separator: "\n\n")
    }

    private struct AskQuestionDisplay {
        let id: String
        let question: String
        let options: [AskOptionDisplay]

        var displayQuestion: String {
            let text = singleLine(question)
            return text.isEmpty ? id : text
        }
    }

    private struct AskOptionDisplay {
        let value: String
        let label: String
        let description: String?
    }

    private static func askQuestions(args: [String: JSONValue]?, details: JSONValue?) -> [AskQuestionDisplay] {
        let detailQuestions = questions(from: detailsQuestionValue(details))
        if !detailQuestions.isEmpty { return detailQuestions }
        return questions(from: args?["questions"])
    }

    private static func detailsQuestionValue(_ details: JSONValue?) -> JSONValue? {
        guard case .object(let payload) = details else { return nil }
        return payload["questions"]
    }

    private static func questions(from value: JSONValue?) -> [AskQuestionDisplay] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item else { return nil }
            let question = object["question"]?.stringValue ?? ""
            let id = object["id"]?.stringValue ?? question
            let trimmedID = singleLine(id)
            guard !trimmedID.isEmpty else { return nil }

            let options: [AskOptionDisplay]
            if case .array(let optionItems) = object["options"] {
                options = optionItems.compactMap { optionItem in
                    guard case .object(let optionObject) = optionItem else { return nil }
                    let label = optionObject["label"]?.stringValue ?? optionObject["value"]?.stringValue ?? ""
                    let value = optionObject["value"]?.stringValue ?? label
                    let trimmedValue = singleLine(value)
                    let trimmedLabel = singleLine(label)
                    guard !trimmedValue.isEmpty || !trimmedLabel.isEmpty else { return nil }
                    return AskOptionDisplay(
                        value: trimmedValue.isEmpty ? trimmedLabel : trimmedValue,
                        label: trimmedLabel.isEmpty ? trimmedValue : trimmedLabel,
                        description: optionObject["description"]?.stringValue
                    )
                }
            } else {
                options = []
            }

            return AskQuestionDisplay(
                id: trimmedID,
                question: question,
                options: options
            )
        }
    }

    private static func askAnswers(from details: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let payload) = details,
              case .object(let answers) = payload["answers"] else {
            return nil
        }
        return answers
    }

    private static func askAllIgnored(_ details: JSONValue?) -> Bool {
        guard case .object(let payload) = details,
              case .bool(true) = payload["allIgnored"] else {
            return false
        }
        return true
    }

    private static func askChecklistSection(question: AskQuestionDisplay, answer: JSONValue?) -> String {
        var lines: [String] = ["**Q:** \(markdownInline(question.displayQuestion))"]
        for option in question.options {
            let checked = answer.map { isAskOptionSelected(option, answer: $0) } ?? false
            var line = "- [\(checked ? "x" : " ")] \(markdownInline(option.label))"
            if let description = option.description.map(singleLine), !description.isEmpty {
                line += " — \(markdownInline(description))"
            }
            lines.append(line)
        }

        if let answer, !answerMatchesAnyOption(answer, in: question) {
            lines.append("**A:** \(markdownInline(displayAnswer(answer, question: question)))")
        } else if answer == nil {
            lines.append("**A:** (skipped)")
        }

        return lines.joined(separator: "\n")
    }

    private static func displayAnswer(_ answer: JSONValue, question: AskQuestionDisplay?) -> String {
        switch answer {
        case .string(let value):
            return displayAnswerValue(value, question: question)
        case .array(let values):
            return values.map { value in
                if case .string(let string) = value {
                    return displayAnswerValue(string, question: question)
                }
                return value.displayString
            }.joined(separator: ", ")
        default:
            return answer.displayString
        }
    }

    private static func displayAnswerValue(_ value: String, question: AskQuestionDisplay?) -> String {
        let normalized = singleLine(value)
        if let matched = question?.options.first(where: { option in
            option.value == normalized || option.label == normalized
        }) {
            return matched.label
        }
        return normalized
    }

    private static func answerMatchesAnyOption(_ answer: JSONValue, in question: AskQuestionDisplay) -> Bool {
        question.options.contains { isAskOptionSelected($0, answer: answer) }
    }

    private static func isAskOptionSelected(_ option: AskOptionDisplay, answer: JSONValue) -> Bool {
        switch answer {
        case .string(let value):
            let normalized = singleLine(value)
            return normalized == option.value || normalized == option.label
        case .array(let values):
            return values.contains { value in
                guard case .string(let string) = value else { return false }
                let normalized = singleLine(string)
                return normalized == option.value || normalized == option.label
            }
        default:
            return false
        }
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownInline(_ text: String) -> String {
        singleLine(text)
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "`", with: #"\`"#)
            .replacingOccurrences(of: "*", with: #"\*"#)
            .replacingOccurrences(of: "_", with: #"\_"#)
            .replacingOccurrences(of: "[", with: #"\["#)
            .replacingOccurrences(of: "]", with: #"\]"#)
    }

    // MARK: - Edit Diff Stats

    /// Compute +added/-removed line counts from edit args.
    struct DiffStats {
        let added: Int
        let removed: Int
    }

}
