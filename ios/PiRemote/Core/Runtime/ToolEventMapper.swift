import Foundation

/// Maps server tool events to client-side tool event IDs.
///
/// Prefers the server-provided `toolCallId` (from pi RPC) when available.
/// Falls back to synthetic UUIDs for backward compatibility with servers
/// that don't yet send `toolCallId`.
///
/// v1 assumption: tool events are strictly sequential (one open tool at a time).
@MainActor
final class ToolEventMapper {
    private var currentToolEventID: String?

    func start(sessionId: String, tool: String, args: [String: JSONValue], toolCallId: String? = nil) -> AgentEvent {
        let id = toolCallId ?? UUID().uuidString
        currentToolEventID = id
        return .toolStart(sessionId: sessionId, toolEventId: id, tool: tool, args: args)
    }

    func output(sessionId: String, output: String, isError: Bool, toolCallId: String? = nil) -> AgentEvent {
        // Prefer server-provided toolCallId, then current open tool, then synthetic
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        return .toolOutput(sessionId: sessionId, toolEventId: id, output: output, isError: isError)
    }

    func end(sessionId: String, toolCallId: String? = nil) -> AgentEvent {
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        currentToolEventID = nil
        return .toolEnd(sessionId: sessionId, toolEventId: id)
    }

    /// Reset state (e.g., on disconnect/reconnect).
    func reset() {
        currentToolEventID = nil
    }
}
