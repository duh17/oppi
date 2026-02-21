import Testing
@testable import Oppi

@Suite("ServerMessage decoding")
struct ServerMessageTests {

    // MARK: - Connection lifecycle

    @Test func decodesConnected() throws {
        let json = """
        {"type":"connected","session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected, got \(msg)")
            return
        }
        #expect(session.id == "abc")
        #expect(session.status == .ready)
    }

    @Test func decodesConnectedWithCurrentSeq() throws {
        let json = """
        {"type":"connected","currentSeq":42,"session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected")
            return
        }
        #expect(session.id == "abc")
    }

    @Test func decodesState() throws {
        let json = """
        {"type":"state","session":{"id":"abc","status":"busy","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":5,"tokens":{"input":100,"output":200},"cost":0.05,"lastMessage":"hello"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .state(let session) = msg else {
            Issue.record("Expected .state")
            return
        }
        #expect(session.status == .busy)
        #expect(session.messageCount == 5)
        #expect(session.lastMessage == "hello")
    }

    @Test func decodesSessionEnded() throws {
        let json = """
        {"type":"session_ended","reason":"stopped"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .sessionEnded(let reason) = msg else {
            Issue.record("Expected .sessionEnded")
            return
        }
        #expect(reason == "stopped")
    }

    @Test func decodesStopRequested() throws {
        let json = #"{"type":"stop_requested","source":"user","reason":"Stopping current turn"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopRequested(let source, let reason) = msg else {
            Issue.record("Expected .stopRequested")
            return
        }
        #expect(source == .user)
        #expect(reason == "Stopping current turn")
    }

    @Test func decodesStopConfirmed() throws {
        let json = #"{"type":"stop_confirmed","source":"timeout"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopConfirmed(let source, let reason) = msg else {
            Issue.record("Expected .stopConfirmed")
            return
        }
        #expect(source == .timeout)
        #expect(reason == nil)
    }

    @Test func decodesStopFailed() throws {
        let json = #"{"type":"stop_failed","source":"server","reason":"timed out"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopFailed(let source, let reason) = msg else {
            Issue.record("Expected .stopFailed")
            return
        }
        #expect(source == .server)
        #expect(reason == "timed out")
    }

    // MARK: - Agent streaming

    @Test func decodesAgentStart() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_start"}"#)
        #expect(msg == .agentStart)
    }

    @Test func decodesAgentEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_end"}"#)
        #expect(msg == .agentEnd)
    }

    @Test func decodesMessageEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"message_end","role":"assistant","content":"Done"}"#)
        guard case .messageEnd(let role, let content) = msg else {
            Issue.record("Expected .messageEnd")
            return
        }
        #expect(role == "assistant")
        #expect(content == "Done")
    }

    @Test func decodesTextDelta() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"text_delta","delta":"Hello "}"#)
        guard case .textDelta(let delta) = msg else {
            Issue.record("Expected .textDelta")
            return
        }
        #expect(delta == "Hello ")
    }

    @Test func decodesThinkingDelta() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"thinking_delta","delta":"Let me think..."}"#)
        guard case .thinkingDelta(let delta) = msg else {
            Issue.record("Expected .thinkingDelta")
            return
        }
        #expect(delta == "Let me think...")
    }

    // MARK: - Tool execution

    @Test func decodesToolStart() throws {
        let json = """
        {"type":"tool_start","tool":"bash","args":{"command":"ls -la"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, let args, let toolCallId, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(args["command"] == .string("ls -la"))
        #expect(toolCallId == nil)
    }

    @Test func decodesToolStartWithToolCallId() throws {
        let json = """
        {"type":"tool_start","tool":"bash","args":{"command":"ls"},"toolCallId":"tc-42"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, _, let toolCallId, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolOutput() throws {
        let json = """
        {"type":"tool_output","output":"total 42\\ndrwxr-xr-x"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, let isError, let toolCallId) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output.contains("total 42"))
        #expect(!isError)
        #expect(toolCallId == nil)
    }

    @Test func decodesToolOutputWithToolCallId() throws {
        let json = """
        {"type":"tool_output","output":"data","toolCallId":"tc-42"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, _, let toolCallId) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolOutputWithError() throws {
        let json = """
        {"type":"tool_output","output":"command not found","isError":true}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, let isError, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(isError)
    }

    @Test func decodesToolEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"bash"}"#)
        guard case .toolEnd(let tool, let toolCallId, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == nil)
        #expect(details == nil)
        #expect(isError == false)
    }

    @Test func decodesToolEndWithToolCallId() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"bash","toolCallId":"tc-42"}"#)
        guard case .toolEnd(let tool, let toolCallId, _, _, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolEndWithDetails() throws {
        let json = #"{"type":"tool_end","tool":"remember","toolCallId":"tc-ext","details":{"file":"2026-02-18.md","redacted":false},"isError":false}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolEnd(let tool, let toolCallId, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "remember")
        #expect(toolCallId == "tc-ext")
        #expect(isError == false)
        // Verify details structure
        guard case .object(let dict) = details else {
            Issue.record("Expected object details")
            return
        }
        #expect(dict["file"] == .string("2026-02-18.md"))
        #expect(dict["redacted"] == .bool(false))
    }

    @Test func decodesToolEndWithIsError() throws {
        let json = #"{"type":"tool_end","tool":"bash","toolCallId":"tc-err","details":{"exitCode":127},"isError":true}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolEnd(_, _, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(isError == true)
        guard case .object(let dict) = details else {
            Issue.record("Expected object details")
            return
        }
        #expect(dict["exitCode"] == .number(127))
    }

    @Test func decodesTurnAck() throws {
        let json = #"{"type":"turn_ack","command":"prompt","clientTurnId":"turn-1","stage":"dispatched","requestId":"req-1","duplicate":false}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .turnAck(let command, let clientTurnId, let stage, let requestId, let duplicate) = msg else {
            Issue.record("Expected .turnAck")
            return
        }
        #expect(command == "prompt")
        #expect(clientTurnId == "turn-1")
        #expect(stage == .dispatched)
        #expect(requestId == "req-1")
        #expect(!duplicate)
    }

    // MARK: - Permissions

    @Test func decodesPermissionRequest() throws {
        let json = """
        {"type":"permission_request","id":"perm1","sessionId":"s1","tool":"bash","input":{"command":"rm -rf /"},"displaySummary":"bash: rm -rf /","reason":"Destructive command","timeoutAt":1700000120000}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .permissionRequest(let perm) = msg else {
            Issue.record("Expected .permissionRequest")
            return
        }
        #expect(perm.id == "perm1")
        #expect(perm.tool == "bash")
        #expect(perm.displaySummary == "bash: rm -rf /")
        #expect(perm.expires)
    }

    @Test func decodesPermissionRequestWithoutExpiry() throws {
        let json = """
        {"type":"permission_request","id":"perm1","sessionId":"s1","tool":"bash","input":{"command":"git push"},"displaySummary":"bash: git push","reason":"Git push","timeoutAt":1700000120000,"expires":false}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .permissionRequest(let perm) = msg else {
            Issue.record("Expected .permissionRequest")
            return
        }
        #expect(!perm.expires)
        #expect(!perm.hasExpiry)
    }

    @Test func decodesPermissionExpired() throws {
        let json = """
        {"type":"permission_expired","id":"perm1","reason":"timeout"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .permissionExpired(let id, let reason) = msg else {
            Issue.record("Expected .permissionExpired")
            return
        }
        #expect(id == "perm1")
        #expect(reason == "timeout")
    }

    // MARK: - Error

    @Test func decodesError() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"error","error":"something broke"}"#)
        guard case .error(let message, let code, let fatal) = msg else {
            Issue.record("Expected .error")
            return
        }
        #expect(message == "something broke")
        #expect(code == nil)
        #expect(!fatal)
    }

    @Test func decodesFatalError() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"error","error":"Workspace session limit reached (3)","code":"SESSION_LIMIT_WORKSPACE","fatal":true}"#)
        guard case .error(let message, let code, let fatal) = msg else {
            Issue.record("Expected .error")
            return
        }
        #expect(message == "Workspace session limit reached (3)")
        #expect(code == "SESSION_LIMIT_WORKSPACE")
        #expect(fatal)
    }

    // MARK: - Unknown type handling

    @Test func unknownTypeDecodesToUnknown() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"future_feature","data":"stuff"}"#)
        guard case .unknown(let type) = msg else {
            Issue.record("Expected .unknown")
            return
        }
        #expect(type == "future_feature")
    }

    // MARK: - Extension UI

    @Test func decodesExtensionUIRequest() throws {
        let json = """
        {"type":"extension_ui_request","id":"ext1","sessionId":"s1","method":"select","title":"Choose option","options":["A","B","C"]}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest")
            return
        }
        #expect(req.id == "ext1")
        #expect(req.method == "select")
        #expect(req.options == ["A", "B", "C"])
    }

    // MARK: - Malformed / Edge Cases

    @Test func missingTypeFieldThrows() {
        let json = #"{"data":"no type field"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func emptyStringThrows() {
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: "")
        }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: "not json at all {{{")
        }
    }

    @Test func textDeltaMissingDeltaFieldThrows() {
        // text_delta requires a "delta" field
        let json = #"{"type":"text_delta"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func toolStartMissingToolFieldThrows() {
        let json = #"{"type":"tool_start","args":{}}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func errorMissingMessageFieldThrows() {
        let json = #"{"type":"error"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func extraFieldsAreIgnored() throws {
        // Extra fields should not break decoding
        let json = #"{"type":"agent_start","extra":"ignored","nested":{"a":1}}"#
        let msg = try ServerMessage.decode(from: json)
        #expect(msg == .agentStart)
    }

    @Test func toolStartWithNullArgsDefaultsToEmpty() throws {
        let json = #"{"type":"tool_start","tool":"read"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, let args, _, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "read")
        #expect(args.isEmpty)
    }

    @Test func toolOutputDefaultsIsErrorToFalse() throws {
        let json = #"{"type":"tool_output","output":"data"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, let isError, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output == "data")
        #expect(!isError)
    }

    @Test func multipleUnknownTypesAllDecode() throws {
        let types = ["new_feature", "v2_event", "debug_info", ""]
        for type in types {
            let json = #"{"type":"\#(type)"}"#
            let msg = try ServerMessage.decode(from: json)
            guard case .unknown(let decoded) = msg else {
                Issue.record("Expected .unknown for type '\(type)', got \(msg)")
                return
            }
            #expect(decoded == type)
        }
    }

    @Test func sessionEndedMissingReasonThrows() {
        let json = #"{"type":"session_ended"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func permissionRequestMissingFieldsThrows() {
        // Missing required fields like tool, etc.
        let json = #"{"type":"permission_request","id":"p1","sessionId":"s1"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func decodesPermissionCancelled() throws {
        let json = #"{"type":"permission_cancelled","id":"perm42"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .permissionCancelled(let id) = msg else {
            Issue.record("Expected .permissionCancelled")
            return
        }
        #expect(id == "perm42")
    }

    @Test func extensionUINotification() throws {
        let json = """
        {"type":"extension_ui_notification","method":"status","message":"Building...","notifyType":"info"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let method, let message, let notifyType, _, _) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        #expect(method == "status")
        #expect(message == "Building...")
        #expect(notifyType == "info")
    }

    // MARK: - RPC Result

    @Test func decodesRpcResult() throws {
        let json = """
        {"type":"rpc_result","command":"set_model","requestId":"req-1","success":true,"data":{"id":"claude-sonnet-4"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .rpcResult(let command, let requestId, let success, let data, let error) = msg else {
            Issue.record("Expected .rpcResult")
            return
        }
        #expect(command == "set_model")
        #expect(requestId == "req-1")
        #expect(success)
        #expect(data != nil)
        #expect(error == nil)
    }

    @Test func decodesRpcResultFailure() throws {
        let json = """
        {"type":"rpc_result","command":"bash","success":false,"error":"Permission denied"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .rpcResult(let command, _, let success, _, let error) = msg else {
            Issue.record("Expected .rpcResult")
            return
        }
        #expect(command == "bash")
        #expect(!success)
        #expect(error == "Permission denied")
    }

    // MARK: - Compaction

    @Test func decodesCompactionStart() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"compaction_start","reason":"threshold"}"#)
        guard case .compactionStart(let reason) = msg else {
            Issue.record("Expected .compactionStart")
            return
        }
        #expect(reason == "threshold")
    }

    @Test func decodesCompactionEnd() throws {
        let json = """
        {"type":"compaction_end","aborted":false,"willRetry":true,"summary":"Summarized context","tokensBefore":150000}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore) = msg else {
            Issue.record("Expected .compactionEnd")
            return
        }
        #expect(!aborted)
        #expect(willRetry)
        #expect(summary == "Summarized context")
        #expect(tokensBefore == 150_000)
    }

    // MARK: - Retry

    @Test func decodesRetryStart() throws {
        let json = """
        {"type":"retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage) = msg else {
            Issue.record("Expected .retryStart")
            return
        }
        #expect(attempt == 1)
        #expect(maxAttempts == 3)
        #expect(delayMs == 2000)
        #expect(errorMessage == "529 overloaded")
    }

    @Test func decodesRetryEnd() throws {
        let json = """
        {"type":"retry_end","success":false,"attempt":3,"finalError":"Max retries exceeded"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .retryEnd(let success, let attempt, let finalError) = msg else {
            Issue.record("Expected .retryEnd")
            return
        }
        #expect(!success)
        #expect(attempt == 3)
        #expect(finalError == "Max retries exceeded")
    }

    // MARK: - Full session

    @Test func connectedWithFullSessionFields() throws {
        let json = """
        {"type":"connected","session":{"id":"s1","status":"busy","createdAt":1700000000000,\
        "lastActivity":1700000000000,"messageCount":3,"tokens":{"input":50,"output":100},"cost":0.02,\
        "model":"anthropic/claude-sonnet-4-0","contextTokens":150,"contextWindow":200000,"lastMessage":"working"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected")
            return
        }
        #expect(session.model == "anthropic/claude-sonnet-4-0")
        #expect(session.contextTokens == 150)
        #expect(session.contextWindow == 200_000)
    }
}
