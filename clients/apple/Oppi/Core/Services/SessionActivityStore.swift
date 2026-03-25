import Foundation

/// Lightweight store tracking the most recent tool activity per session.
///
/// Fed from `toolStart` events in the message router. SessionRow reads
/// from this store (via its caller) to show "reading server/src/types.ts"
/// style activity summaries.
///
/// Separate from TimelineReducer — that's per-chat-view and heavyweight.
/// This store is global, lightweight, and only tracks the last tool.
@MainActor @Observable
final class SessionActivityStore {
    struct Activity: Equatable {
        let toolName: String
        let keyArg: String?
    }

    private var activities: [String: Activity] = [:]

    func recordToolStart(sessionId: String, tool: String, args: [String: JSONValue]) {
        let keyArg = Self.extractKeyArg(tool: tool, args: args)
        activities[sessionId] = Activity(toolName: tool, keyArg: keyArg)
    }

    func lastActivity(for sessionId: String) -> Activity? {
        activities[sessionId]
    }

    func clear(sessionId: String) {
        activities.removeValue(forKey: sessionId)
    }

    // MARK: - Key Arg Extraction

    /// Pull the most relevant argument from tool args for display.
    ///
    /// - Read/Write/Edit: `path`
    /// - Bash: first ~40 chars of `command`
    /// - Others: first string value found
    static func extractKeyArg(tool: String, args: [String: JSONValue]) -> String? {
        let toolLower = tool.lowercased()

        // File operations: path is the key arg
        if toolLower == "read" || toolLower == "write" || toolLower == "edit" {
            return args["path"]?.stringValue
        }

        // Shell commands: truncated command string
        if toolLower == "bash" || toolLower == "execute" {
            if let cmd = args["command"]?.stringValue {
                return cmd.count > 40 ? String(cmd.prefix(40)) + "..." : cmd
            }
        }

        // Fallback: first string value we find
        for (_, value) in args.sorted(by: { $0.key < $1.key }) {
            if let s = value.stringValue, !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "..." : s
            }
        }
        return nil
    }
}
