import Foundation
import Testing
@testable import Oppi

@Suite("SessionActivitySummary")
struct SessionActivitySummaryTests {

    // MARK: - Test helpers

    private func makeSession(
        id: String = "s1",
        status: SessionStatus = .busy,
        changeStats: SessionChangeStats? = nil
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: "Test Session",
            status: status,
            createdAt: Date(),
            lastActivity: Date(),
            model: "test/model",
            messageCount: 5,
            tokens: TokenUsage(input: 100, output: 50),
            cost: 1.50,
            changeStats: changeStats
        )
    }

    private func makePermission(
        tool: String = "Write",
        input: [String: JSONValue] = ["path": .string("src/types.ts")]
    ) -> PermissionRequest {
        PermissionRequest(
            id: "perm-1",
            sessionId: "s1",
            tool: tool,
            input: input,
            displaySummary: "Write to src/types.ts",
            reason: "needs approval",
            timeoutAt: Date().addingTimeInterval(60)
        )
    }

    // MARK: - Pending permissions

    @Test func pendingPermission_showsPathPermission() {
        let session = makeSession(status: .busy)
        let perms = [makePermission(tool: "Write", input: ["path": .string("src/types.ts")])]
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 1,
            pendingPermissions: perms,
            activity: nil
        )
        #expect(result == "permission: write src/types.ts")
    }

    @Test func pendingPermission_showsCommandPermission() {
        let session = makeSession(status: .busy)
        let perms = [makePermission(tool: "Bash", input: ["command": .string("rm -rf build")])]
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 1,
            pendingPermissions: perms,
            activity: nil
        )
        #expect(result == "permission: rm -rf build")
    }

    @Test func pendingPermission_truncatesLongCommand() {
        let longCmd = String(repeating: "x", count: 50)
        let session = makeSession(status: .busy)
        let perms = [makePermission(tool: "Bash", input: ["command": .string(longCmd)])]
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 1,
            pendingPermissions: perms,
            activity: nil
        )
        #expect(result != nil)
        #expect(result!.contains("..."))
    }

    @Test func pendingPermission_fallsBackToToolName() {
        let session = makeSession(status: .busy)
        let perms = [makePermission(tool: "CustomTool", input: ["data": .number(42)])]
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 1,
            pendingPermissions: perms,
            activity: nil
        )
        #expect(result == "permission: CustomTool")
    }

    @Test func pendingPermission_overridesActivity() {
        let session = makeSession(status: .busy)
        let perms = [makePermission()]
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "file.swift")
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 1,
            pendingPermissions: perms,
            activity: activity
        )
        // Should show permission, not the tool activity
        #expect(result?.hasPrefix("permission:") == true)
    }

    // MARK: - Working sessions

    @Test func working_showsToolActivity() {
        let session = makeSession(status: .busy)
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "server/src/types.ts")
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: activity
        )
        #expect(result == "reading src/types.ts")
    }

    @Test func working_noActivity_returnsNil() {
        let session = makeSession(status: .busy)
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: nil
        )
        #expect(result == nil)
    }

    @Test func starting_showsToolActivity() {
        let session = makeSession(status: .starting)
        let activity = SessionActivityStore.Activity(toolName: "Write", keyArg: "output.txt")
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: activity
        )
        #expect(result == "writing output.txt")
    }

    // MARK: - Idle sessions

    @Test func idle_showsTurnEnded() {
        let session = makeSession(status: .ready)
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: nil
        )
        #expect(result == "turn ended")
    }

    // MARK: - Stopped sessions

    @Test func stopped_showsFileCount() {
        let stats = SessionChangeStats(
            mutatingToolCalls: 5,
            filesChanged: 3,
            changedFiles: ["a.swift", "b.swift", "c.swift"],
            addedLines: 50,
            removedLines: 10
        )
        let session = makeSession(status: .stopped, changeStats: stats)
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: nil
        )
        #expect(result == "3 files changed")
    }

    @Test func stopped_noChanges_returnsNil() {
        let session = makeSession(status: .stopped)
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: nil
        )
        #expect(result == nil)
    }

    // MARK: - Error sessions

    @Test func error_showsAgentError() {
        let session = makeSession(status: .error)
        let result = SessionActivitySummary.text(
            session: session,
            pendingCount: 0,
            pendingPermissions: [],
            activity: nil
        )
        #expect(result == "agent error")
    }

    // MARK: - formatToolActivity

    @Test func formatToolActivity_readVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "a/b/c/file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading c/file.swift")
    }

    @Test func formatToolActivity_editVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Edit", keyArg: "src/main.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "editing src/main.swift")
    }

    @Test func formatToolActivity_bashVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Bash", keyArg: "npm test")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "running npm test")
    }

    @Test func formatToolActivity_noKeyArg() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: nil)
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading")
    }

    @Test func formatToolActivity_unknownTool() {
        let activity = SessionActivityStore.Activity(toolName: "spawn_agent", keyArg: "worker-1")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "spawn_agent worker-1")
    }

    @Test func formatToolActivity_shortPathNotTruncated() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading file.swift")
    }

    @Test func formatToolActivity_twoComponentPathKept() {
        let activity = SessionActivityStore.Activity(toolName: "Write", keyArg: "src/file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "writing src/file.swift")
    }
}
