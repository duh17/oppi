import Foundation

/// Maps sequential server tool events to client-side tool event IDs.
///
/// v1 assumption: tool events are strictly sequential (one open tool at a time).
/// The server doesn't include tool IDs, so we generate UUIDs on `tool_start`
/// and reuse them for subsequent `tool_output` and `tool_end` events.
@MainActor
final class ToolEventMapper {
    private var currentToolEventID: String?

    func start(sessionId: String, tool: String, args: [String: JSONValue]) -> AgentEvent {
        let id = UUID().uuidString
        currentToolEventID = id
        return .toolStart(sessionId: sessionId, toolEventId: id, tool: tool, args: args)
    }

    func output(sessionId: String, output: String, isError: Bool) -> AgentEvent {
        let id = currentToolEventID ?? UUID().uuidString
        return .toolOutput(sessionId: sessionId, toolEventId: id, output: output, isError: isError)
    }

    func end(sessionId: String) -> AgentEvent {
        let id = currentToolEventID ?? UUID().uuidString
        currentToolEventID = nil
        return .toolEnd(sessionId: sessionId, toolEventId: id)
    }

    /// Reset state (e.g., on disconnect/reconnect).
    func reset() {
        currentToolEventID = nil
    }
}
