import Foundation

// TEMPORARY: delete this file and its one call in `ChatViewController.sendPrompt` in the next
// release, when servers without `capabilities.promptContext` no longer need support. Such a
// server drops context items, so the chat folds the staged comments into the message text as
// the app did before the server rendered them.
enum ReviewCommentsTextFallback {
    /// The text and context items a chat message sends: unchanged when the server takes context
    /// items, or while its capabilities are unknown (the send's refusal covers that); else the
    /// comments as a Markdown block after the typed text, and no items.
    static func prompt(
        text: String,
        context: [PromptContextItem],
        capabilities: ServerInfo.Capabilities?
    ) -> (text: String, context: [PromptContextItem]) {
        guard !context.isEmpty, let capabilities, capabilities.promptContext?.version ?? 0 < 1 else {
            return (text, context)
        }
        let block = reviewBlock(context)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? block : "\(trimmed)\n\n\(block)", [])
    }

    private static func reviewBlock(_ items: [PromptContextItem]) -> String {
        var lines = ["## Review comments", "", "Please address these review comments.", ""]
        for (index, item) in items.enumerated() {
            lines += ["### Comment \(index + 1)", "", "**Where:** \(place(item))"]
            if let quote = item.quote {
                let quoteLines = quote.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).map(String.init)
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: quote) + 1))
                let language = item.language ?? item.path.map { ($0 as NSString).pathExtension } ?? ""
                lines += ["", "**Selected text:**", "", fence + language] + quoteLines + [fence]
            }
            if let anchor = item.anchor {
                lines += ["", anchor]
            }
            lines += ["", "**Comment:**", ""]
            lines += (item.note ?? "").split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.isEmpty ? ">" : "> \($0)"
            }
            if index < items.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    private static func place(_ item: PromptContextItem) -> String {
        let source = switch item.source {
        case .gitDiff: "git diff"
        case .file: "file"
        case .timelineText: "timeline text"
        case .toolOutput: "tool output"
        case .terminalOutput: "terminal output"
        case .image: "image"
        case .unknown: "unknown source"
        }
        guard let path = item.path else {
            return item.label.map { "\($0) (\(source))" } ?? source
        }
        var title = "`\(path)`"
        if let start = item.startLine {
            title += item.endLine.map { $0 == start ? ":\(start)" : ":\(start)-\($0)" } ?? ":\(start)"
        }
        if let start = item.startPage {
            title += item.endPage.map { $0 == start ? " page \(start)" : " pages \(start)–\($0)" } ?? " page \(start)"
        }
        return title + (item.side.map { " (\($0), \(source))" } ?? " (\(source))")
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
