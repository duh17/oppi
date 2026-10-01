import Foundation

// Mac's collapsed-row policy is deferred. Keep its existing summary parser local
// rather than leaving a bash-schema fallback in the shared inspection owner.
// Slice 6 deletes these Mac-target-only name adapters when Mac paints shared facts.
extension ToolCallFormatting {
    static func macLegacySFSymbolName(for toolName: String) -> String? {
        if toolName == "bash" || toolName == "Bash" { return "dollarsign" }
        switch normalized(toolName) {
        case "read": return "magnifyingglass"
        case "write": return "pencil"
        case "edit": return "arrow.left.arrow.right"
        default: return sfSymbolName(for: toolName)
        }
    }

    // Mac chrome is explicitly deferred to slice 6. These legacy name/schema
    // adapters are local to Mac, not fallbacks in the shared inspection owner.
    static func isReadTool(_ name: String) -> Bool { normalized(name) == "read" }
    static func isWriteTool(_ name: String) -> Bool { normalized(name) == "write" }
    static func isEditTool(_ name: String) -> Bool { normalized(name) == "edit" }
    static func displayFilePath(tool: String, args: [String: JSONValue]?, argsSummary: String) -> String {
        guard let raw = filePath(from: args) ?? parseArgValue("path", from: argsSummary) else { return argsSummary }
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count > 2 { path = "~/" + parts.dropFirst(2).joined(separator: "/") }
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path + (isReadTool(tool) ? readLineRangeSuffix(from: args) : "")
    }
    static func compactReadDisplayTitle(tool: String, args: [String: JSONValue]?, argsSummary: String) -> String? {
        guard isReadTool(tool), let path = filePath(from: args) ?? parseArgValue("path", from: argsSummary) else { return nil }
        let parts = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard parts.last == "SKILL.md", parts.count >= 2 else { return nil }
        return "[skill] \(parts[parts.count - 2])\(readLineRangeSuffix(from: args))"
    }
    static func readLineRangeSuffix(from args: [String: JSONValue]?) -> String {
        let offset = args?["offset"]?.numberValue.map(Int.init)
        let limit = args?["limit"]?.numberValue.map(Int.init)
        guard offset != nil || limit != nil else { return "" }
        let start = offset ?? 1
        return ":\(start)\(limit.map { "-\(start + $0 - 1)" } ?? "")"
    }
    static func editDiffStats(from args: [String: JSONValue]?) -> DiffStats? {
        let pairs = (args?["edits"]?.arrayValue ?? []).compactMap { value -> (String, String)? in
            guard let old = value.objectValue?["oldText"]?.stringValue, let new = value.objectValue?["newText"]?.stringValue else { return nil }
            return (old, new)
        }
        guard !pairs.isEmpty else { return nil }
        let stats = DiffEngine.stats(DiffEngine.compute(old: pairs.map { $0.0 }.joined(separator: "\n"), new: pairs.map { $0.1 }.joined(separator: "\n")))
        return .init(added: stats.added, removed: stats.removed)
    }
    static func editResultDiffLines(from details: JSONValue?) -> [DiffLine]? {
        guard let patch = details?.objectValue?["patch"]?.stringValue,
              let document = UnifiedPatchParser.parse(patch, options: .strict), !document.isMultiFile,
              let file = document.files.first, !file.lines.isEmpty else { return nil }
        return file.lines
    }

    static func bashCommand(args: [String: JSONValue]?, argsSummary: String) -> String {
        String(bashCommandFull(args: args, argsSummary: argsSummary).prefix(200))
    }

    static func bashCommandFull(args: [String: JSONValue]?, argsSummary: String) -> String {
        let raw: String
        if let cmd = args?["command"]?.stringValue { raw = cmd }
        else if let parsed = parseArgValue("command", from: argsSummary) { raw = parsed }
        else if argsSummary.hasPrefix("command: ") { raw = String(argsSummary.dropFirst(9)) }
        else { raw = argsSummary }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if let first = value.first, let last = value.last,
           first == "'" || first == "\"", first == last, value.count >= 2 {
            return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
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
}
