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

    /// Format bash command for header display (truncated to 120 chars).
    static func bashCommand(args: [String: JSONValue]?, argsSummary: String) -> String {
        if let cmd = args?["command"]?.stringValue {
            return String(cmd.prefix(120))
        }
        if argsSummary.hasPrefix("command: ") {
            return String(argsSummary.dropFirst(9).prefix(120))
        }
        return argsSummary
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
}
