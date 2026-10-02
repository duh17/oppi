import Foundation

/// Pi IDs are authoritative, including nested calls. The sequential fallback is
/// only for old servers omitting IDs; children never replace that open parent.
@MainActor
final class ToolCallCorrelator {
    private var currentToolEventID: String?

    func start(sessionId: String, tool: String, args: [String: JSONValue], toolCallId: String? = nil, callSegments: [StyledSegment]? = nil, inputPresentation: ToolInputPresentation? = nil, display: ToolDisplay? = nil, outputPresentation: ToolOutputPresentation? = nil, parentToolCallId: String? = nil) -> AgentEvent {
        let id = toolCallId ?? UUID().uuidString
        if parentToolCallId == nil { currentToolEventID = id }
        return .toolStart(sessionId: sessionId, toolEventId: id, tool: tool, args: args, callSegments: callSegments, inputPresentation: inputPresentation, display: display, outputPresentation: outputPresentation, parentToolCallId: parentToolCallId)
    }

    func update(sessionId: String, tool: String, args: [String: JSONValue], toolCallId: String? = nil, callSegments: [StyledSegment]? = nil, inputPresentation: ToolInputPresentation? = nil, display: ToolDisplay? = nil, outputPresentation: ToolOutputPresentation? = nil, parentToolCallId: String? = nil) -> AgentEvent {
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        if parentToolCallId == nil { currentToolEventID = id }
        return .toolUpdate(sessionId: sessionId, toolEventId: id, tool: tool, args: args, callSegments: callSegments, inputPresentation: inputPresentation, display: display, outputPresentation: outputPresentation, parentToolCallId: parentToolCallId)
    }

    func output(sessionId: String, output: String, isError: Bool, toolCallId: String? = nil, mode: ToolOutputMode = .append, truncated: Bool = false, totalBytes: Int? = nil, details: JSONValue? = nil, outputAvailability: ToolOutputAvailability? = nil, parentToolCallId: String? = nil, outputStream: ToolOutputStreamChunk? = nil) -> AgentEvent {
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        return .toolOutput(.init(sessionId: sessionId, toolEventId: id, output: output, isError: isError, mode: mode, truncated: truncated, totalBytes: totalBytes, details: details, outputAvailability: outputAvailability, parentToolCallId: parentToolCallId, outputStream: outputStream))
    }

    func end(sessionId: String, toolCallId: String? = nil, details: JSONValue? = nil, isError: Bool = false, resultSegments: [StyledSegment]? = nil, nestedCalls: NestedToolCalls? = nil, outputPresentation: ToolOutputPresentation? = nil, outputAvailability: ToolOutputAvailability? = nil, parentToolCallId: String? = nil, outputStream: ToolOutputStreamEnd? = nil) -> AgentEvent {
        let id = toolCallId ?? currentToolEventID ?? UUID().uuidString
        if parentToolCallId == nil { currentToolEventID = nil }
        return .toolEnd(sessionId: sessionId, toolEventId: id, details: details, isError: isError, resultSegments: resultSegments, nestedCalls: nestedCalls, outputPresentation: outputPresentation, outputAvailability: outputAvailability, parentToolCallId: parentToolCallId, outputStream: outputStream)
    }

    func reset() { currentToolEventID = nil }
}
