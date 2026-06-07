import Foundation
import Testing
@testable import Oppi

@Suite("Session identity decoding")
struct SessionIdentityTests {
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
