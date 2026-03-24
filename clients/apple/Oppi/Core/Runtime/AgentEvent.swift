import Foundation

struct ToolOutputEventPayload: Sendable {
    let sessionId: String
    let toolEventId: String
    let output: String
    let isError: Bool
    let mode: ToolOutputMode
    let truncated: Bool
    let totalBytes: Int?
}

/// Transport-agnostic domain events from the agent.
///
/// Produced by translating `ServerMessage` into agent-level semantics.
/// Consumed by the `DeltaCoalescer` → `TimelineReducer` → chat timeline rendering pipeline.
enum AgentEvent: Sendable {
    case agentStart(sessionId: String)
    case agentEnd(sessionId: String)

    case textDelta(sessionId: String, delta: String)
    case thinkingDelta(sessionId: String, delta: String)
    case messageEnd(sessionId: String, content: String)

    /// Tool events carry a client-generated `toolEventId` (v1: sequential assumption).
    case toolStart(sessionId: String, toolEventId: String, tool: String, args: [String: JSONValue], callSegments: [StyledSegment]? = nil)
    case toolOutput(ToolOutputEventPayload)
    case toolEnd(sessionId: String, toolEventId: String, details: JSONValue? = nil, isError: Bool = false, resultSegments: [StyledSegment]? = nil)

    // Compaction
    case compactionStart(sessionId: String, reason: String)
    case compactionEnd(sessionId: String, aborted: Bool, willRetry: Bool, summary: String?, tokensBefore: Int?)

    // Retry
    case retryStart(sessionId: String, attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case retryEnd(sessionId: String, success: Bool, attempt: Int, finalError: String?)

    // Command response (model change, stats, etc.)
    case commandResult(sessionId: String, command: String, requestId: String?, success: Bool, data: JSONValue?, error: String?)

    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String)
    case sessionEnded(sessionId: String, reason: String)
    case error(sessionId: String, message: String)

    // periphery:ignore - convenience factory used by timeline tests via @testable import
    static func toolOutput(
        sessionId: String,
        toolEventId: String,
        output: String,
        isError: Bool,
        mode: ToolOutputMode = .append,
        truncated: Bool = false,
        totalBytes: Int? = nil
    ) -> Self {
        .toolOutput(.init(
            sessionId: sessionId,
            toolEventId: toolEventId,
            output: output,
            isError: isError,
            mode: mode,
            truncated: truncated,
            totalBytes: totalBytes
        ))
    }

    // periphery:ignore - used by OppiTests via @testable import
    var typeLabel: String {
        switch self {
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .messageEnd: "messageEnd"
        case .toolStart: "toolStart"
        case .toolOutput: "toolOutput"
        case .toolEnd: "toolEnd"
        case .compactionStart: "compactionStart"
        case .compactionEnd: "compactionEnd"
        case .retryStart: "retryStart"
        case .retryEnd: "retryEnd"
        case .commandResult: "commandResult"
        case .permissionRequest: "permissionRequest"
        case .permissionExpired: "permissionExpired"
        case .sessionEnded: "sessionEnded"
        case .error: "error"
        }
    }
}
