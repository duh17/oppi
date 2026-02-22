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

    static func isWriteTool(_ name: String) -> Bool {
        normalized(name) == "write"
    }

    static func isEditTool(_ name: String) -> Bool {
        normalized(name) == "edit"
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
    /// - `/Users/example/workspace/oppi/ios/Oppi/Features/Chat/File.swift`
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
    static func isTodoTool(_ name: String) -> Bool { normalized(name) == "todo" }
    static func isRememberTool(_ name: String) -> Bool { normalized(name) == "remember" }
    static func isRecallTool(_ name: String) -> Bool { normalized(name) == "recall" }

    // MARK: - Edit Diff Stats

    /// Compute +added/-removed line counts from edit args.
    struct DiffStats {
        let added: Int
        let removed: Int
    }

    private static func firstStringValue(
        in args: [String: JSONValue]?,
        keys: [String]
    ) -> String? {
        guard let args else { return nil }
        for key in keys {
            if let value = args[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    static func editOldAndNewText(from args: [String: JSONValue]?) -> (oldText: String, newText: String)? {
        let oldText = firstStringValue(
            in: args,
            keys: ["oldText", "old_text", "oldString", "old_string", "before", "beforeText"]
        )
        let newText = firstStringValue(
            in: args,
            keys: ["newText", "new_text", "newString", "new_string", "after", "afterText"]
        )

        guard let oldText, let newText else { return nil }
        return (oldText: oldText, newText: newText)
    }

    static func editDiffStats(from args: [String: JSONValue]?) -> DiffStats? {
        guard let editText = editOldAndNewText(from: args) else { return nil }

        // Keep collapsed +N/-N badges aligned with the expanded diff renderer.
        // Both should use the same LCS diff implementation.
        let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
        let stats = DiffEngine.stats(lines)
        return DiffStats(added: stats.added, removed: stats.removed)
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
