import Foundation

struct ToolOutputEventPayload: Sendable {
    let sessionId: String
    let toolEventId: String
    let output: String
    let isError: Bool
    let mode: ToolOutputMode
    let truncated: Bool
    let totalBytes: Int?
    let details: JSONValue?

    init(
        sessionId: String,
        toolEventId: String,
        output: String,
        isError: Bool,
        mode: ToolOutputMode = .append,
        truncated: Bool = false,
        totalBytes: Int? = nil,
        details: JSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.toolEventId = toolEventId
        self.output = output
        self.isError = isError
        self.mode = mode
        self.truncated = truncated
        self.totalBytes = totalBytes
        self.details = details
    }
}

/// Transport-agnostic domain events from the agent.
///
/// Produced by translating `ServerMessage` into agent-level semantics.
/// Consumed by the `DeltaCoalescer` → `TimelineReducer` → chat timeline rendering pipeline.
enum AgentEvent: Sendable {
    case agentStart(sessionId: String)
    case agentEnd(sessionId: String)
    /// Authoritative idle boundary after retries/continuations drain.
    /// Open tools are interrupted here, not on `agentEnd`.
    case agentSettled(sessionId: String)

    case textDelta(sessionId: String, delta: String, contentIndex: Int? = nil)
    case thinkingDelta(sessionId: String, delta: String, contentIndex: Int? = nil)
    case messageEnd(
        sessionId: String,
        content: String,
        assistantContent: [AssistantMessageContentPart]? = nil,
        entryId: String? = nil
    )
    case cacheMiss(sessionId: String, id: String, message: String)

    /// Tool events carry a client-generated `toolEventId` (v1: sequential assumption).
    case toolStart(sessionId: String, toolEventId: String, tool: String, args: [String: JSONValue], callSegments: [StyledSegment]? = nil)
    case toolUpdate(sessionId: String, toolEventId: String, tool: String, args: [String: JSONValue], callSegments: [StyledSegment]? = nil)
    case toolOutput(ToolOutputEventPayload)
    case toolEnd(sessionId: String, toolEventId: String, details: JSONValue? = nil, isError: Bool = false, resultSegments: [StyledSegment]? = nil)

    // Compaction
    case compactionStart(sessionId: String, reason: String)
    case compactionEnd(sessionId: String, aborted: Bool, willRetry: Bool, summary: String?, tokensBefore: Int?, errorMessage: String? = nil)

    // Retry
    case retryStart(sessionId: String, attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case retryEnd(sessionId: String, success: Bool, attempt: Int, finalError: String?)

    // Command response (model change, stats, etc.)
    case commandResult(sessionId: String, command: String, requestId: String?, success: Bool, data: JSONValue?, error: String?)

    case sessionEnded(sessionId: String, reason: String)
    case error(sessionId: String, message: String)

    // periphery:ignore - used by OppiTests via @testable import
    var typeLabel: String {
        switch self {
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .agentSettled: "agentSettled"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .messageEnd: "messageEnd"
        case .cacheMiss: "cacheMiss"
        case .toolStart: "toolStart"
        case .toolUpdate: "toolUpdate"
        case .toolOutput: "toolOutput"
        case .toolEnd: "toolEnd"
        case .compactionStart: "compactionStart"
        case .compactionEnd: "compactionEnd"
        case .retryStart: "retryStart"
        case .retryEnd: "retryEnd"
        case .commandResult: "commandResult"
        case .sessionEnded: "sessionEnded"
        case .error: "error"
        }
    }
}
