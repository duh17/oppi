import Foundation

// MARK: - Todo Tool Formatting

extension ToolCallFormatting {

    /// Format todo command summary for header display.
    static func todoSummary(args: [String: JSONValue]?, argsSummary: String) -> String {
        let action = todoAction(args: args, argsSummary: argsSummary) ?? ""

        if action.isEmpty {
            return argsSummary
        }

        let id = args?["id"]?.stringValue
            ?? parseArgValue("id", from: argsSummary)
        let title = args?["title"]?.stringValue
            ?? parseArgValue("title", from: argsSummary)
        let status = args?["status"]?.stringValue
            ?? parseArgValue("status", from: argsSummary)

        switch action {
        case "get", "delete", "claim", "release":
            if let id, !id.isEmpty { return "\(action) \(id)" }
            return action

        case "append", "update":
            if let id, !id.isEmpty { return "\(action) \(id)" }
            return action

        case "create":
            if let title, !title.isEmpty {
                return "create \(String(title.prefix(80)))"
            }
            return action

        case "list", "list-all":
            if let status, !status.isEmpty, action == "list" {
                return "list status=\(status)"
            }
            return action

        default:
            return String("\(action) \(id ?? title ?? "")".trimmingCharacters(in: .whitespaces).prefix(120))
        }
    }

    struct TodoOutputPresentation: Equatable, Sendable {
        let text: String
        let trailing: String?
        let usesMarkdown: Bool
    }

    struct TodoMutationDiffPresentation: Sendable {
        let diffLines: [DiffLine]
        let addedLineCount: Int
        let removedLineCount: Int
        let preview: String?
        let unifiedText: String
    }

    /// For todo mutations (`append`, `update`), render change payloads as a
    /// diff so callers can present edits consistently.
    static func todoMutationDiffPresentation(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> TodoMutationDiffPresentation? {
        guard let action = todoAction(args: args, argsSummary: argsSummary) else {
            return nil
        }

        let diffLines: [DiffLine]
        switch action {
        case "append":
            diffLines = todoAppendDiffLines(args: args, argsSummary: argsSummary)
        case "update":
            diffLines = todoUpdateDiffLines(args: args, argsSummary: argsSummary)
        default:
            return nil
        }

        guard !diffLines.isEmpty else { return nil }

        let stats = DiffEngine.stats(diffLines)
        let preview = todoDiffPreview(from: diffLines, maxLines: 2)

        return TodoMutationDiffPresentation(
            diffLines: diffLines,
            addedLineCount: stats.added,
            removedLineCount: stats.removed,
            preview: preview,
            unifiedText: DiffEngine.formatUnified(diffLines)
        )
    }

    /// Backward-compatible helper for append-only callers.
    static func todoAppendDiffPresentation(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> TodoMutationDiffPresentation? {
        guard todoAction(args: args, argsSummary: argsSummary) == "append" else {
            return nil
        }
        return todoMutationDiffPresentation(args: args, argsSummary: argsSummary)
    }

    /// Parse todo tool JSON payloads into readable markdown-like text.
    static func todoOutputPresentation(
        args: [String: JSONValue]?,
        argsSummary: String,
        output: String
    ) -> TodoOutputPresentation? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let list = try? decoder.decode(TodoListPayload.self, from: data),
           list.hasSections {
            return TodoOutputPresentation(
                text: formattedTodoListMarkdown(list),
                trailing: todoListTrailing(list),
                usesMarkdown: true
            )
        }

        if let items = try? decoder.decode([TodoItemPayload].self, from: data),
           !items.isEmpty {
            return TodoOutputPresentation(
                text: formattedTodoFlatListMarkdown(items, sectionTitle: "Todos"),
                trailing: "\(items.count) todos",
                usesMarkdown: true
            )
        }

        if let item = try? decoder.decode(TodoItemPayload.self, from: data),
           item.looksLikeTodo {
            return TodoOutputPresentation(
                text: formattedTodoItemMarkdown(item, action: todoAction(args: args, argsSummary: argsSummary)),
                trailing: normalizedTodoStatus(item.status),
                usesMarkdown: true
            )
        }

        return nil
    }

    // MARK: - Todo Private Helpers

    private static let todoListMaxItemsPerSection = 12

    static func todoAction(args: [String: JSONValue]?, argsSummary: String) -> String? {
        let rawAction = args?["action"]?.stringValue
            ?? parseArgValue("action", from: argsSummary)
        guard let rawAction else { return nil }
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
        return action.isEmpty ? nil : action
    }

    /// Build a concise, human-readable trailing badge for a todo list result.
    /// Shows only non-zero section counts, e.g. "10 open" or "2 assigned · 5 open · 1 closed".
    private static func todoListTrailing(_ list: TodoListPayload) -> String {
        var parts: [String] = []
        if list.assignedItems.count > 0 { parts.append("\(list.assignedItems.count) assigned") }
        if list.openItems.count > 0 { parts.append("\(list.openItems.count) open") }
        if list.closedItems.count > 0 { parts.append("\(list.closedItems.count) closed") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }

    private static let todoUpdateBodyPreviewLineLimit = 8

    private static func todoAppendDiffLines(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> [DiffLine] {
        guard let body = args?["body"]?.stringValue
            ?? parseArgValue("body", from: argsSummary)
        else { return [] }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return todoBodyLines(from: trimmed).map { DiffLine(kind: .added, text: $0) }
    }

    private static func todoUpdateDiffLines(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> [DiffLine] {
        var lines: [DiffLine] = []

        if let title = compactTodoText(
            args?["title"]?.stringValue
                ?? parseArgValue("title", from: argsSummary),
            max: 200
        ) {
            lines.append(DiffLine(kind: .added, text: "title: \(title)"))
        }

        if let status = normalizedTodoStatus(
            args?["status"]?.stringValue
                ?? parseArgValue("status", from: argsSummary)
        ) {
            lines.append(DiffLine(kind: .added, text: "status: \(status)"))
        }

        if let tags = todoTagsText(args: args, argsSummary: argsSummary) {
            lines.append(DiffLine(kind: .added, text: "tags: \(tags)"))
        }

        if let body = args?["body"]?.stringValue
            ?? parseArgValue("body", from: argsSummary) {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                lines.append(DiffLine(kind: .removed, text: "body: <cleared>"))
            } else {
                let bodyLines = todoBodyLines(from: trimmedBody)
                if bodyLines.count == 1 {
                    lines.append(DiffLine(kind: .added, text: "body: \(bodyLines[0])"))
                } else {
                    lines.append(DiffLine(kind: .added, text: "body:"))
                    for line in bodyLines.prefix(todoUpdateBodyPreviewLineLimit) {
                        lines.append(DiffLine(kind: .added, text: "  \(line)"))
                    }
                    if bodyLines.count > todoUpdateBodyPreviewLineLimit {
                        lines.append(
                            DiffLine(kind: .added, text: "  … +\(bodyLines.count - todoUpdateBodyPreviewLineLimit) more lines")
                        )
                    }
                }
            }
        }

        return lines
    }

    private static func todoTagsText(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String? {
        if let tagsArray = args?["tags"]?.arrayValue {
            let tags = tagsArray
                .map { value -> String in
                    if let string = value.stringValue {
                        return string.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return value.summary(maxLength: 40).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

            if !tags.isEmpty {
                return tags.joined(separator: ", ")
            }
        }

        if let tagsRaw = args?["tags"]?.stringValue
            ?? parseArgValue("tags", from: argsSummary) {
            let trimmed = tagsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private static func todoBodyLines(from body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func todoDiffPreview(from diffLines: [DiffLine], maxLines: Int) -> String? {
        let previewLines = diffLines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(maxLines)
            .map(\.text)

        guard !previewLines.isEmpty else { return nil }
        let preview = previewLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    private static func formattedTodoListMarkdown(_ list: TodoListPayload) -> String {
        var sections: [String] = []
        if !list.assignedItems.isEmpty {
            sections.append(formattedTodoFlatListMarkdown(list.assignedItems, sectionTitle: "Assigned"))
        }
        if !list.openItems.isEmpty {
            sections.append(formattedTodoFlatListMarkdown(list.openItems, sectionTitle: "Open"))
        }
        if !list.closedItems.isEmpty {
            sections.append(formattedTodoFlatListMarkdown(list.closedItems, sectionTitle: "Closed"))
        }
        return sections.isEmpty ? "No todos." : sections.joined(separator: "\n\n")
    }

    private static func formattedTodoFlatListMarkdown(_ items: [TodoItemPayload], sectionTitle: String) -> String {
        guard !items.isEmpty else {
            return "### \(sectionTitle) (0)\n- _none_"
        }

        var lines: [String] = ["### \(sectionTitle) (\(items.count))"]
        for item in items.prefix(todoListMaxItemsPerSection) {
            lines.append("- \(formattedTodoListLine(item))")
        }
        if items.count > todoListMaxItemsPerSection {
            lines.append("- … +\(items.count - todoListMaxItemsPerSection) more")
        }
        return lines.joined(separator: "\n")
    }

    private static func formattedTodoListLine(_ item: TodoItemPayload) -> String {
        let id = compactTodoText(item.id, max: 80) ?? "TODO-unknown"
        var parts: [String] = ["`\(id)`"]
        if let status = normalizedTodoStatus(item.status) { parts.append("`\(status)`") }
        if let title = compactTodoText(item.title, max: 140) { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    private static func formattedTodoItemMarkdown(_ item: TodoItemPayload, action: String?) -> String {
        var lines: [String] = []
        if let action, !action.isEmpty {
            lines.append("**todo \(action)**")
            lines.append("")
        }

        let id = compactTodoText(item.id, max: 80) ?? "TODO-unknown"
        var headerParts: [String] = ["`\(id)`"]
        if let status = normalizedTodoStatus(item.status) { headerParts.append("`\(status)`") }
        if let created = compactTodoText(item.createdAt, max: 80) { headerParts.append(created) }
        lines.append(headerParts.joined(separator: " · "))

        if let title = compactTodoText(item.title, max: 200) {
            lines.append("")
            lines.append(title)
        }

        let tags = (item.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            lines.append("")
            lines.append("Tags: \(tags.map { "`\($0)`" }.joined(separator: ", "))")
        }

        let body = item.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append(body)
        }

        return lines.joined(separator: "\n")
    }

    private static func compactTodoText(_ raw: String?, max: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(max))
    }

    static func normalizedTodoStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: "-")
    }

    // MARK: - Todo Payload Types

    struct TodoItemPayload: Decodable, Sendable {
        let id: String?
        let title: String?
        let tags: [String]?
        let status: String?
        let createdAt: String?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case id, title, tags, status, body
            case createdAt = "created_at"
        }

        var looksLikeTodo: Bool {
            id != nil || title != nil || status != nil || createdAt != nil || body != nil || !(tags ?? []).isEmpty
        }
    }

    struct TodoListPayload: Decodable, Sendable {
        let assigned: [TodoItemPayload]?
        let open: [TodoItemPayload]?
        let closed: [TodoItemPayload]?

        var hasSections: Bool { assigned != nil || open != nil || closed != nil }
        var assignedItems: [TodoItemPayload] { assigned ?? [] }
        var openItems: [TodoItemPayload] { open ?? [] }
        var closedItems: [TodoItemPayload] { closed ?? [] }
    }
}
