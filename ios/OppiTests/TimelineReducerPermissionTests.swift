import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Permissions")
struct TimelineReducerPermissionTests {

    @MainActor
    @Test func permissionRequestSkipsTimeline() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": "rm -rf /"],
            displaySummary: "bash: rm -rf /",
            reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        reducer.process(.permissionRequest(perm))
        #expect(reducer.items.isEmpty, "Pending permissions should not appear in timeline")

        reducer.resolvePermission(id: "p1", outcome: .denied, tool: "bash", summary: "bash: rm -rf /")
        #expect(reducer.items.count == 1)
        guard case .permissionResolved(_, let outcome, let tool, _) = reducer.items[0] else {
            Issue.record("Expected permissionResolved")
            return
        }
        #expect(outcome == .denied)
        #expect(tool == "bash")
    }

    @MainActor
    @Test func permissionExpiredIsNoOpInReducer() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: ls",
            reason: "Read",
            timeoutAt: Date().addingTimeInterval(60)
        )

        reducer.process(.permissionRequest(perm))
        reducer.process(.permissionExpired(id: "p1"))

        #expect(reducer.items.isEmpty, "Reducer should ignore permission events (handled by ServerConnection)")
    }
}
