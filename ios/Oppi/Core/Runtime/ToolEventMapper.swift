import Foundation

/// Correlates server tool events to client-side tool call IDs.
///
/// Prefers the server-provided `toolCallId` (from pi RPC) when available.
/// Falls back to synthetic UUIDs for servers that omit `toolCallId`.
///
/// v1 assumption: tool events are strictly sequential (one open tool at a time).
@MainActor
final class ToolCallCorrelator {
    private var currentToolEventID: String?

    func start(sessionId: String, tool: String, args: [String: JSONValue], toolCallId: String? = nil, callSegments: [StyledSegment]? = nil) -> AgentEvent {
        let id = toolCallId ?? UUID().uuidString
        currentToolEventID = id
        return .toolStart(sessionId: sessionId, toolEventId: id, tool: tool, args: args, callSegments: callSegments)
    }

    func output(sessionId: String, output: String, isError: Bool, toolCallId: String? = nil) -> AgentEvent {
        // Prefer server-provided toolCallId, then current open tool, then synthetic
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        return .toolOutput(sessionId: sessionId, toolEventId: id, output: output, isError: isError)
    }

    func end(sessionId: String, toolCallId: String? = nil, details: JSONValue? = nil, isError: Bool = false, resultSegments: [StyledSegment]? = nil) -> AgentEvent {
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        currentToolEventID = nil
        return .toolEnd(sessionId: sessionId, toolEventId: id, details: details, isError: isError, resultSegments: resultSegments)
    }

    /// Reset state (e.g., on disconnect/reconnect).
    func reset() {
        currentToolEventID = nil
    }
}

typealias ToolEventMapper = ToolCallCorrelator
