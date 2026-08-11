import Foundation
import Testing
@testable import Oppi

@Suite("AppEventMessage decoding")
struct AppEventMessageTests {
    private var snapshotURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/app-event-messages.json")
    }

    private func loadSnapshot() throws -> [String: Any] {
        let data = try Data(contentsOf: snapshotURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["messages"] as? [String: Any])
    }

    private func decodeSnapshot(_ key: String) throws -> AppEventMessage {
        let messages = try loadSnapshot()
        let value = try #require(messages[key])
        let messageData = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(AppEventMessage.self, from: messageData)
    }

    @Test func decodesEveryCommittedCanonicalAppEvent() throws {
        let messages = try loadSnapshot()
        var failures: [String] = []

        for (key, value) in messages {
            do {
                let messageData = try JSONSerialization.data(withJSONObject: value)
                let event = try JSONDecoder().decode(AppEventMessage.self, from: messageData)
                if case .ignored(let type) = event {
                    failures.append("\(key): decoded as .ignored(\(type))")
                }
            } catch {
                failures.append("\(key): \(error.localizedDescription)")
            }
        }

        #expect(
            failures.isEmpty,
            "Failed to decode \(failures.count) app-event message(s):\n\(failures.joined(separator: "\n"))"
        )
    }

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
            "agentId": "agent-reviewer",
            "agentIcon": {"kind":"symbol","name":"checkmark.shield"},
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
        #expect(summary.agentId == "agent-reviewer")
        #expect(summary.agentIcon == .symbol("checkmark.shield"))
        #expect(summary.session.launch?.agentIcon == .symbol("checkmark.shield"))
    }

    @Test func parentAppEventsPreserveIconFallbackAcrossEveryTaggedAndFutureCase() throws {
        let assetId = "ia_" + String(repeating: "A", count: 43)
        let cases: [(String, IconChoice)] = [
            ("session_summary_icon_default", .defaultValue),
            ("session_summary_icon_emoji", .emoji("🧘")),
            ("session_summary_icon_genmoji", .genmoji(
                assetId: assetId,
                contentDescription: "A smiling fox"
            )),
            ("session_summary_icon_malformed", .defaultValue),
            ("session_summary_icon_future", .defaultValue),
        ]

        for (key, expected) in cases {
            let event = try decodeSnapshot(key)
            guard case .sessionSummary(_, _, _, let summary) = event else {
                Issue.record("Expected .sessionSummary for \(key), got \(event)")
                continue
            }
            #expect(summary.agentIcon == expected)
            #expect(summary.session.launch?.agentIcon == expected)
        }
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
          "allowCustom": false,
          "extensionScopeId": "npm:review-helper",
          "extensionDisplayName": "Review Helper"
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
        #expect(request.extensionScopeId == "npm:review-helper")
        #expect(request.extensionDisplayName == "Review Helper")
    }

    @Test func decodesExtensionUINotificationScopeMetadata() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "extension_ui_notification",
          "sessionId": "s1",
          "workspaceId": "w1",
          "emittedAt": 1791650000003,
          "method": "setWidget",
          "widgetKey": "review",
          "extensionScopeId": "npm:review-helper",
          "extensionDisplayName": "Review Helper"
        }
        """)

        guard case .extensionUINotification(let notification, let sessionId, let workspaceId, let emittedAt) = event else {
            Issue.record("Expected .extensionUINotification, got \(event)")
            return
        }
        #expect(sessionId == "s1")
        #expect(workspaceId == "w1")
        #expect(emittedAt == 1_791_650_000_003)
        #expect(notification.method == "setWidget")
        #expect(notification.widgetKey == "review")
        #expect(notification.extensionScopeId == "npm:review-helper")
        #expect(notification.extensionDisplayName == "Review Helper")
    }

    @Test func decodesWorkspaceGitChangedWorktreeId() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "workspace_git_changed",
          "workspaceId": "w1",
          "worktreeId": "wt_feature",
          "sessionId": "s1",
          "emittedAt": 1791650000004,
          "reason": "mutation_tool"
        }
        """)

        guard case .workspaceGitChanged(let workspaceId, let worktreeId, let emittedAt, let sessionId, let reason) = event else {
            Issue.record("Expected .workspaceGitChanged, got \(event)")
            return
        }
        #expect(workspaceId == "w1")
        #expect(worktreeId == "wt_feature")
        #expect(emittedAt == 1_791_650_000_004)
        #expect(sessionId == "s1")
        #expect(reason == "mutation_tool")
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
