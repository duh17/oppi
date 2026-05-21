import Foundation

/// Pure formatting logic for tool call display.
///
/// Extracted from timeline row rendering so it can be unit-tested without
/// view instantiation. Maps structured args to display strings.
enum ToolCallFormatting {

    // MARK: - Tool Type Detection

    static func isReadTool(_ name: String) -> Bool {
        normalized(name) == "read"
    }

    // periphery:ignore - used by OppiTests via @testable import
    static func isWriteTool(_ name: String) -> Bool {
        normalized(name) == "write"
    }

    static func isEditTool(_ name: String) -> Bool {
        normalized(name) == "edit"
    }

    // MARK: - Arg Extraction

    /// Extract file path from structured args.
    static func filePath(from args: [String: JSONValue]?) -> String? {
        args?["path"]?.stringValue
    }

    /// Extract read offset (defaults to 1).
    static func readStartLine(from args: [String: JSONValue]?) -> Int {
        args?["offset"]?.numberValue.map { Int($0) } ?? 1
    }

    /// Extract file content from write tool args.
    static func writeContent(from args: [String: JSONValue]?) -> String? {
        args?["content"]?.stringValue
    }

    // MARK: - Display Formatting

    /// Format bash command for header display (truncated to 200 chars).
    static func bashCommand(args: [String: JSONValue]?, argsSummary: String) -> String {
        String(bashCommandFull(args: args, argsSummary: argsSummary).prefix(200))
    }

    /// Full bash command text for expanded views and copy actions.
    static func bashCommandFull(args: [String: JSONValue]?, argsSummary: String) -> String {
        let raw: String
        if let cmd = args?["command"]?.stringValue {
            raw = cmd
        } else if let parsed = parseArgValue("command", from: argsSummary) {
            raw = parsed
        } else if argsSummary.hasPrefix("command: ") {
            raw = String(argsSummary.dropFirst(9))
        } else {
            raw = argsSummary
        }

        return normalizedBashCommand(raw)
    }

    private static func normalizedBashCommand(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        if let first = value.first, let last = value.last,
           first == "'" || first == "\"", first == last, value.count >= 2 {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            return value
        }

        if value.hasPrefix("\""), !value.dropFirst().contains("\"") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.hasSuffix("\""), !value.dropLast().contains("\"") {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("'"), !value.dropFirst().contains("'") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.hasSuffix("'"), !value.dropLast().contains("'") {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }

    /// Format file path for header display with optional read line range.
    ///
    /// Keeps the full (shortened) path string so collapsed rows can use
    /// middle truncation (showing both prefix and filename), while expanded
    /// rows can wrap to reveal the complete path.
    static func displayFilePath(
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String {
        let raw = filePath(from: args)
            ?? parseArgValue("path", from: argsSummary)
        guard let path = raw else { return argsSummary }

        var display = normalizedDisplayPath(path)

        // Append line range for read tool
        if isReadTool(tool) {
            let offset = args?["offset"]?.numberValue.map(Int.init)
            let limit = args?["limit"]?.numberValue.map(Int.init)
            if let offset {
                let end = limit.map { offset + $0 - 1 }
                display += ":\(offset)\(end.map { "-\($0)" } ?? "")"
            }
        }

        return display
    }

    private static func normalizedDisplayPath(_ rawPath: String) -> String {
        var normalized = rawPath.shortenedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return rawPath }

        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized
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

    // MARK: - Tool Name Normalization

    /// Canonical lowercase tool name for switch matching.
    ///
    /// Tool names may arrive namespaced (for example `functions.read` or
    /// `tools/write`). We keep only the final segment so rendering and parity
    /// rules stay stable regardless of transport prefixes.
    static func normalized(_ name: String) -> String {
        let trimmed = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !trimmed.isEmpty else { return trimmed }

        let components = trimmed.split(whereSeparator: { character in
            character == "." || character == "/" || character == ":"
        })

        guard let suffix = components.last, !suffix.isEmpty else {
            return trimmed
        }

        return String(suffix)
    }

    static func isBashTool(_ name: String) -> Bool { normalized(name) == "bash" }
    static func isGrepTool(_ name: String) -> Bool { normalized(name) == "grep" }
    static func isFindTool(_ name: String) -> Bool { normalized(name) == "find" }
    static func isLsTool(_ name: String) -> Bool { normalized(name) == "ls" }

    // MARK: - Tool SF Symbol

    /// Canonical SF Symbol name for a built-in tool.
    ///
    /// Accepts either a raw tool name (`"bash"`, `"Read"`) or a
    /// `toolNamePrefix` (`"$"`, `"read"`). Returns `nil` for unknown/extension tools.
    static func sfSymbolName(for toolName: String) -> String? {
        switch toolName {
        case "$", "bash", "Bash":
            return "dollarsign"
        case "read", "Read":
            return "magnifyingglass"
        case "write", "Write":
            return "pencil"
        case "edit", "Edit":
            return "arrow.left.arrow.right"
        case "voice_speak", "voice_create", "Voice_speak", "Voice_create":
            return "speaker.wave.2.fill"
        case "ask", "Ask", "?":
            return "questionmark"
        default:
            return nil
        }
    }

    // MARK: - Ask Formatting

    static func askCollapsedTitle(
        args: [String: JSONValue]?,
        details: JSONValue?,
        argsSummary: String
    ) -> String {
        let questions = askQuestions(args: args, details: details)
        guard let first = questions.first else {
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

    static func editOldAndNewText(from args: [String: JSONValue]?) -> (oldText: String, newText: String)? {
        guard let editsArray = args?["edits"]?.arrayValue, !editsArray.isEmpty else { return nil }

        var olds: [String] = []
        var news: [String] = []

        for edit in editsArray {
            guard let editObj = edit.objectValue,
                  let old = editObj["oldText"]?.stringValue,
                  let new = editObj["newText"]?.stringValue else {
                continue
            }
            olds.append(old)
            news.append(new)
        }

        guard !olds.isEmpty else { return nil }
        return (oldText: olds.joined(separator: "\n"), newText: news.joined(separator: "\n"))
    }

    static func editDiffStats(from args: [String: JSONValue]?) -> DiffStats? {
        guard let editText = editOldAndNewText(from: args) else { return nil }

        // Keep collapsed +N/-N badges aligned with the expanded diff renderer.
        // Both should use the same LCS diff implementation.
        let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
        let stats = DiffEngine.stats(lines)
        return DiffStats(added: stats.added, removed: stats.removed)
    }

}
