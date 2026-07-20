import Foundation
import Testing
@testable import Oppi

@Suite("Session identity decoding")
struct SessionIdentityTests {
    @Test func decodesLaunchTimeAgentIconOnFullSessionAndSummary() throws {
        let fullJSON = Data("""
        {
          "id": "session-1",
          "workspaceId": "ws-1",
          "status": "ready",
          "createdAt": 1000,
          "lastActivity": 2000,
          "messageCount": 0,
          "tokens": { "input": 0, "output": 0 },
          "cost": 0,
          "launch": {
            "agentId": "agent-reviewer",
            "agentVersion": 4,
            "agentIcon": "checkmark.shield",
            "status": "accepted",
            "requestedAt": 900
          }
        }
        """.utf8)
        let summaryJSON = Data("""
        {
          "id": "session-1",
          "workspaceId": "ws-1",
          "status": "ready",
          "createdAt": 1000,
          "lastActivity": 2000,
          "messageCount": 0,
          "tokens": { "input": 0, "output": 0 },
          "cost": 0,
          "agentId": "agent-reviewer",
          "agentIcon": "checkmark.shield"
        }
        """.utf8)

        let session = try JSONDecoder().decode(Session.self, from: fullJSON)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: summaryJSON)

        #expect(session.launch?.agentId == "agent-reviewer")
        #expect(session.launch?.agentIcon == "checkmark.shield")
        #expect(summary.agentId == "agent-reviewer")
        #expect(summary.agentIcon == "checkmark.shield")
        #expect(summary.session.launch?.agentIcon == "checkmark.shield")
    }

    @Test func missingOrMalformedAgentIconRemainsDecodeSafe() throws {
        let oldJSON = Data("""
        {"id":"old","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}
        """.utf8)
        let malformedJSON = Data("""
        {"id":"bad","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"agentId":"agent-1","agentIcon":"not/a/symbol"}
        """.utf8)

        let old = try JSONDecoder().decode(SessionSummary.self, from: oldJSON)
        let malformed = try JSONDecoder().decode(SessionSummary.self, from: malformedJSON)

        #expect(old.agentId == nil)
        #expect(old.agentIcon == nil)
        #expect(malformed.agentId == "agent-1")
        #expect(malformed.agentIcon == "not/a/symbol")
        #expect(AgentIconContent.resolve(malformed.agentIcon) == .fallback)
    }

    @Test func decodesPiSessionIdOnSessionAndSummary() throws {
        let json = Data("""
        {
          "id": "session-1",
          "workspaceId": "ws-1",
          "status": "ready",
          "createdAt": 1000,
          "lastActivity": 2000,
          "messageCount": 0,
          "tokens": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "cost": 0,
          "piSessionId": "pi-session-uuid"
        }
        """.utf8)

        let session = try JSONDecoder().decode(Session.self, from: json)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: json)

        #expect(session.piSessionId == "pi-session-uuid")
        #expect(summary.piSessionId == "pi-session-uuid")
        #expect(summary.session.piSessionId == "pi-session-uuid")
    }
}
