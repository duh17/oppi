import Foundation
import Testing
@testable import Oppi

@Suite("AppEventMessage decoding")
struct AppEventMessageTests {
    @Test func decodesConnectionFrame() throws {
        let event = try AppEventMessage.decode(from: #"{"type":"app_events_connected","serverTime":1791650000000,"snapshotRequired":true}"#)

        guard case .connected(let serverTime, let snapshotRequired) = event else {
            Issue.record("Expected .connected, got \(event)")
            return
        }
        #expect(serverTime == 1_791_650_000_000)
        #expect(snapshotRequired)
    }

    @Test func decodesSessionSummaryWithPendingAskCount() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "session_summary",
          "sessionId": "s1",
          "workspaceId": "w1",
          "emittedAt": 1791650000001,
          "summary": {
            "id": "s1",
            "workspaceId": "w1",
            "status": "busy",
            "createdAt": 1700000000000,
            "lastActivity": 1700000001000,
            "messageCount": 2,
            "tokens": { "input": 10, "output": 5 },
            "cost": 0.01,
            "pendingAskCount": 0
          }
        }
        """)

        guard case .sessionSummary(let sessionId, let workspaceId, let emittedAt, let summary) = event else {
            Issue.record("Expected .sessionSummary, got \(event)")
            return
        }
        #expect(sessionId == "s1")
        #expect(workspaceId == "w1")
        #expect(emittedAt == 1_791_650_000_001)
        #expect(summary.status == .busy)
        #expect(summary.pendingAskCount == 0)
        #expect(summary.hasPendingAskCount)
    }

    @Test func decodesExtensionUIRequestWithWorkspaceRouting() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "extension_ui_request",
          "sessionId": "s1",
          "workspaceId": "w1",
          "emittedAt": 1791650000002,
          "id": "ask-1",
          "method": "ask",
          "questions": [
            { "id": "q1", "question": "Ship it?", "options": [{ "value": "yes", "label": "Yes" }] }
          ],
          "allowCustom": false
        }
        """)

        guard case .extensionUIRequest(let request, let workspaceId, let emittedAt) = event else {
            Issue.record("Expected .extensionUIRequest, got \(event)")
            return
        }
        #expect(request.id == "ask-1")
        #expect(request.sessionId == "s1")
        #expect(request.workspaceId == "w1")
        #expect(workspaceId == "w1")
        #expect(emittedAt == 1_791_650_000_002)
        #expect(request.askQuestions?.first?.question == "Ship it?")
    }

    @Test func focusedStreamFramesDecodeAsIgnored() throws {
        let event = try AppEventMessage.decode(from: #"{"type":"text_delta","delta":"wrong stream"}"#)

        guard case .ignored(let type) = event else {
            Issue.record("Expected focused frame to be ignored, got \(event)")
            return
        }
        #expect(type == "text_delta")
    }

    @Test func sequenceMetadataIsRejected() {
        #expect(throws: DecodingError.self) {
            try AppEventMessage.decode(from: #"{"type":"session_deleted","sessionId":"s1","emittedAt":1,"seq":1}"#)
        }
    }
}
