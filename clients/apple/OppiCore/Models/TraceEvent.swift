import Foundation

/// A single event from the full pi JSONL trace.
///
/// Returned by `GET /workspaces/:workspaceId/sessions/:id` (`trace` payload).
/// Contains the complete tool call history including tool calls and thinking.
struct TraceLifecycleEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case agentStart
        case agentEnd
        case agentSettled
        case turnStart
        case turnEnd
        case toolStart
        case toolEnd
    }

    let id: String
    let event: Kind
    let timestamp: String
    let turnIndex: Int?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool?

    init(
        id: String,
        event: Kind,
        timestamp: String,
        turnIndex: Int? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil
    ) {
        self.id = id
        self.event = event
        self.timestamp = timestamp
        self.turnIndex = turnIndex
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
    }
}

struct TraceEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let type: TraceEventType
    let timestamp: String

    // Text content (user, assistant, system)
    let text: String?

    // Tool call fields
    let tool: String?
    let args: [String: JSONValue]?
    let callSegments: [StyledSegment]?

    // Tool result fields
    let output: String?
    let outputTruncated: Bool?
    let outputPreviewBytes: Int?
    let outputTotalBytes: Int?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool?
    let resultSegments: [StyledSegment]?

    // Persisted lifecycle rides on original trace event types so older clients
    // safely ignore these fields instead of rejecting new enum discriminators.
    let lifecycleBefore: [TraceLifecycleEvent]?
    let lifecycleAfter: [TraceLifecycleEvent]?

    // Tool result details (expandedText, presentationFormat, etc.)
    var details: JSONValue? = nil

    // Thinking
    let thinking: String?

    // Optional semantic presentation for custom/system events.
    let presentation: TraceEventPresentation?

    init(
        id: String,
        type: TraceEventType,
        timestamp: String,
        text: String? = nil,
        tool: String? = nil,
        args: [String: JSONValue]? = nil,
        callSegments: [StyledSegment]? = nil,
        output: String? = nil,
        outputTruncated: Bool? = nil,
        outputPreviewBytes: Int? = nil,
        outputTotalBytes: Int? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil,
        resultSegments: [StyledSegment]? = nil,
        lifecycleBefore: [TraceLifecycleEvent]? = nil,
        lifecycleAfter: [TraceLifecycleEvent]? = nil,
        details: JSONValue? = nil,
        thinking: String? = nil,
        presentation: TraceEventPresentation? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.text = text
        self.tool = tool
        self.args = args
        self.callSegments = callSegments
        self.output = output
        self.outputTruncated = outputTruncated
        self.outputPreviewBytes = outputPreviewBytes
        self.outputTotalBytes = outputTotalBytes
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.isError = isError
        self.resultSegments = resultSegments
        self.lifecycleBefore = lifecycleBefore
        self.lifecycleAfter = lifecycleAfter
        self.details = details
        self.thinking = thinking
        self.presentation = presentation
    }
}

struct TracePageMetadata: Codable, Equatable, Sendable {
    let hasOlder: Bool
    let olderCursor: String?
    let traceVersion: String
    let previewBytes: Int
    let staleCursor: Bool
}

struct TracePageMetrics: Codable, Equatable, Sendable {
    let rawEntryCount: Int
    let traceEventCount: Int
    let selectedRawEntryCount: Int
    let jsonlBytes: Int
    let scannedBytes: Int
    let readMs: Double
    let parseMs: Double
    let selectMs: Double
    let formatMs: Double
    let previewMs: Double
    let jsonBytes: Int?
    let gzipBytes: Int?
    let stringifyMs: Double?
    let gzipMs: Double?
}

struct TraceEventPresentation: Codable, Equatable, Sendable {
    let kind: String
    let title: String
    let subtitle: String?
    let status: String?
    let body: String?
    let fields: [TraceEventPresentationField]?
    let accent: String?
}

struct TraceEventPresentationField: Codable, Equatable, Sendable {
    let label: String
    let value: String
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
