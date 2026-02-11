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
           (first == "'" || first == "\""), first == last, value.count >= 2 {
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
    ///
    /// Prioritizes the most relevant suffix (`parent/file`) so the filename and
    /// read line range remain visible in narrow tool rows.
    static func displayFilePath(
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String {
        let raw = filePath(from: args)
            ?? parseArgValue("path", from: argsSummary)
        guard let path = raw else { return argsSummary }

        var display = compactDisplayPath(path)

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

    /// Keep only the path tail for compact row headers.
    ///
    /// Examples:
    /// - `/Users/chenda/workspace/pios/ios/PiRemote/Features/Chat/File.swift`
    ///   -> `Chat/File.swift`
    /// - `src/server.ts` -> `src/server.ts`
    /// - `README.md` -> `README.md`
    private static func compactDisplayPath(_ rawPath: String) -> String {
        let shortened = rawPath.shortenedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortened.isEmpty else { return rawPath }

        var components = shortened
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if components.first == "~" {
            components.removeFirst()
        }

        guard !components.isEmpty else {
            return shortened
        }

        if components.count == 1 {
            return components[0]
        }

        return components.suffix(2).joined(separator: "/")
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

        if oldText == newText {
            return DiffStats(added: 0, removed: 0)
        }

        var oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Keep line counts aligned with DiffEngine behavior (trim synthetic
        // trailing empty line created by terminal newline).
        if oldLines.count > 1, oldLines.last == "" {
            oldLines.removeLast()
        }
        if newLines.count > 1, newLines.last == "" {
            newLines.removeLast()
        }

        let sharedCount = min(oldLines.count, newLines.count)
        var added = 0
        var removed = 0

        // Count in-place replacements as one removed + one added line so
        // edits like "rename var" surface as changed lines in collapsed rows.
        if sharedCount > 0 {
            for index in 0..<sharedCount where oldLines[index] != newLines[index] {
                added += 1
                removed += 1
            }
        }

        if newLines.count > sharedCount {
            added += newLines.count - sharedCount
        }
        if oldLines.count > sharedCount {
            removed += oldLines.count - sharedCount
        }

        return DiffStats(added: added, removed: removed)
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
