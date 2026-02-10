import Foundation

/// Pure formatting logic for tool call display.
///
/// Extracted from `ToolCallRow` so it can be unit-tested without
/// SwiftUI view instantiation. Maps structured args to display strings.
enum ToolCallFormatting {

    // MARK: - Tool Type Detection

    static func isReadTool(_ name: String) -> Bool {
        name == "Read" || name == "read"
    }

    static func isWriteTool(_ name: String) -> Bool {
        name == "Write" || name == "write"
    }

    static func isEditTool(_ name: String) -> Bool {
        name == "Edit" || name == "edit"
    }

    // MARK: - Arg Extraction

    /// Extract file path from structured args.
    static func filePath(from args: [String: JSONValue]?) -> String? {
        args?["path"]?.stringValue ?? args?["file_path"]?.stringValue
    }

    /// Extract read offset (defaults to 1).
    static func readStartLine(from args: [String: JSONValue]?) -> Int {
        args?["offset"]?.numberValue.map { Int($0) } ?? 1
    }

    // MARK: - Display Formatting

    /// Format bash command for header display (truncated to 200 chars).
    static func bashCommand(args: [String: JSONValue]?, argsSummary: String) -> String {
        if let cmd = args?["command"]?.stringValue {
            return String(cmd.prefix(200))
        }
        if argsSummary.hasPrefix("command: ") {
            return String(argsSummary.dropFirst(9).prefix(200))
        }
        return argsSummary
    }

    /// Format todo command summary for header display.
    ///
    /// Examples:
    /// - `list-all`
    /// - `get id-1234abcd`
    /// - `create Add syntax highlighting`
    static func todoSummary(args: [String: JSONValue]?, argsSummary: String) -> String {
        let action = args?["action"]?.stringValue
            ?? parseArgValue("action", from: argsSummary)
            ?? ""

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

    /// Format file path for header display with optional line range.
    static func displayFilePath(
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String {
        let raw = filePath(from: args)
            ?? parseArgValue("path", from: argsSummary)
        guard let path = raw else { return argsSummary }

        var display = path.shortenedPath

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

    /// Format byte count for display (e.g. "1.2KB", "3.4MB").
    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Tool Name Normalization

    /// Canonical lowercase tool name for switch matching.
    static func normalized(_ name: String) -> String {
        name.lowercased()
    }

    static func isBashTool(_ name: String) -> Bool { normalized(name) == "bash" }
    static func isGrepTool(_ name: String) -> Bool { normalized(name) == "grep" }
    static func isFindTool(_ name: String) -> Bool { normalized(name) == "find" }
    static func isLsTool(_ name: String) -> Bool { normalized(name) == "ls" }
    static func isTodoTool(_ name: String) -> Bool { normalized(name) == "todo" }

    // MARK: - Edit Diff Stats

    /// Compute +added/-removed line counts from edit args.
    struct DiffStats {
        let added: Int
        let removed: Int
    }

    static func editDiffStats(from args: [String: JSONValue]?) -> DiffStats? {
        guard let oldText = args?["oldText"]?.stringValue,
              let newText = args?["newText"]?.stringValue else { return nil }
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).count
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).count
        return DiffStats(
            added: max(0, newLines - oldLines),
            removed: max(0, oldLines - newLines)
        )
    }

    // MARK: - Preview Extraction

    /// Extract tail lines from text (for bash collapsed preview).
    static func tailLines(_ text: String, count: Int = 3) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Extract head lines from text (for read collapsed preview).
    static func headLines(_ text: String, count: Int = 3) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(count).joined(separator: "\n")
    }
}
