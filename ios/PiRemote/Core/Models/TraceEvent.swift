import Foundation

/// A single event from the full pi JSONL trace.
///
/// Returned by `GET /workspaces/:workspaceId/sessions/:id` (`trace` payload).
/// Contains the complete tool call history that `SessionMessage`
/// (user/assistant only) drops.
struct TraceEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let type: TraceEventType
    let timestamp: String

    // Text content (user, assistant, system)
    let text: String?

    // Tool call fields
    let tool: String?
    let args: [String: JSONValue]?

    // Tool result fields
    let output: String?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool?

    // Thinking
    let thinking: String?
}

enum TraceEventType: String, Codable, Sendable {
    case user
    case assistant
    case toolCall
    case toolResult
    case thinking
    case system
    case compaction
}
