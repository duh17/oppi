import Foundation

/// A single event from the full pi JSONL trace.
///
/// Returned by `GET /workspaces/:workspaceId/sessions/:id` (`trace` payload).
/// Contains the complete tool call history including tool calls and thinking.
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

    // Tool result details (expandedText, presentationFormat, etc.)
    var details: JSONValue? = nil

    // Thinking
    let thinking: String?

    init(
        id: String,
        type: TraceEventType,
        timestamp: String,
        text: String? = nil,
        tool: String? = nil,
        args: [String: JSONValue]? = nil,
        output: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil,
        details: JSONValue? = nil,
        thinking: String? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.text = text
        self.tool = tool
        self.args = args
        self.output = output
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
        self.details = details
        self.thinking = thinking
    }
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
