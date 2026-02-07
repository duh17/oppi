import Testing
@testable import PiRemote

@Suite("ServerMessage decoding")
struct ServerMessageTests {

    // MARK: - Connection lifecycle

    @Test func decodesConnected() throws {
        let json = """
        {"type":"connected","session":{"id":"abc","userId":"u1","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected, got \(msg)")
            return
        }
        #expect(session.id == "abc")
        #expect(session.status == .ready)
    }

    @Test func decodesState() throws {
        let json = """
        {"type":"state","session":{"id":"abc","userId":"u1","status":"busy","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":5,"tokens":{"input":100,"output":200},"cost":0.05,"lastMessage":"hello"}}
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

    // MARK: - Agent streaming

    @Test func decodesAgentStart() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_start"}"#)
        #expect(msg == .agentStart)
    }

    @Test func decodesAgentEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_end"}"#)
        #expect(msg == .agentEnd)
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
        guard case .toolStart(let tool, let args) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(args["command"] == .string("ls -la"))
    }

    @Test func decodesToolOutput() throws {
        let json = """
        {"type":"tool_output","output":"total 42\\ndrwxr-xr-x"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, let isError) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output.contains("total 42"))
        #expect(!isError)
    }

    @Test func decodesToolOutputWithError() throws {
        let json = """
        {"type":"tool_output","output":"command not found","isError":true}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, let isError) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(isError)
    }

    @Test func decodesToolEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"bash"}"#)
        guard case .toolEnd(let tool) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "bash")
    }

    // MARK: - Permissions

    @Test func decodesPermissionRequest() throws {
        let json = """
        {"type":"permission_request","id":"perm1","sessionId":"s1","tool":"bash","input":{"command":"rm -rf /"},"displaySummary":"bash: rm -rf /","risk":"critical","reason":"Destructive command","timeoutAt":1700000120000}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .permissionRequest(let perm) = msg else {
            Issue.record("Expected .permissionRequest")
            return
        }
        #expect(perm.id == "perm1")
        #expect(perm.tool == "bash")
        #expect(perm.risk == .critical)
        #expect(perm.displaySummary == "bash: rm -rf /")
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
        guard case .error(let message) = msg else {
            Issue.record("Expected .error")
            return
        }
        #expect(message == "something broke")
    }

    // MARK: - Forward compatibility

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
}
