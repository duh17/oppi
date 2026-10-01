import Foundation

// Mac's collapsed-row policy is deferred. Keep its existing summary parser local
// rather than leaving a bash-schema fallback in the shared inspection owner.
extension ToolCallFormatting {
    static func macLegacySFSymbolName(for toolName: String) -> String? {
        if toolName == "bash" || toolName == "Bash" { return "dollarsign" }
        return sfSymbolName(for: toolName)
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
