import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace tool output")
struct MacSessionTraceStoreToolOutputTests {
    @Test func exposesReducerToolOutputStore() {
        let store = MacSessionTraceStore()
        store.toolOutputStore.replace("preview", for: "tool-1", previewOnly: true, totalBytes: 1_200)

        #expect(store.toolOutputStore.fullOutput(for: "tool-1") == "preview")
        #expect(store.toolOutputStore.hasPreviewOnlyOutput(for: "tool-1"))
        #expect(!store.toolOutputStore.hasCompleteOutput(for: "tool-1"))
    }

    @Test func expandFetchesFullOutputAndReplacesPreview() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"output":"full untruncated tool output"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.toolOutputStore.replace(
            String(repeating: "p", count: 500),
            for: "tool-1",
            previewOnly: true,
            totalBytes: 4_096
        )

        await store.loadFullToolOutputIfNeeded(itemID: "tool-1", target: target, client: client)

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/workspace-tool-output/sessions/session-tool-output/tool-output/tool-1?full=true")
        #expect(store.toolOutputStore.fullOutput(for: "tool-1") == "full untruncated tool output")
        #expect(store.toolOutputStore.hasCompleteOutput(for: "tool-1"))
        #expect(!store.toolOutputStore.hasPreviewOnlyOutput(for: "tool-1"))
        #expect(store.lastError == nil)
    }

    @Test func expandSkipsFetchWhenStoreAlreadyHasCompleteOutput() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"output":"should not replace"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.toolOutputStore.replace("already complete", for: "tool-1", previewOnly: false)

        await store.loadFullToolOutputIfNeeded(itemID: "tool-1", target: target, client: client)

        #expect(await transport.requests.isEmpty)
        #expect(store.toolOutputStore.fullOutput(for: "tool-1") == "already complete")
        #expect(store.toolOutputStore.hasCompleteOutput(for: "tool-1"))
    }

    @Test func expandKeepsPreviewOn404() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 404,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"not found"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.toolOutputStore.replace("bounded preview", for: "tool-1", previewOnly: true, totalBytes: 2_000)

        await store.loadFullToolOutputIfNeeded(itemID: "tool-1", target: target, client: client)

        #expect(store.toolOutputStore.fullOutput(for: "tool-1") == "bounded preview")
        #expect(store.toolOutputStore.hasPreviewOnlyOutput(for: "tool-1"))
        #expect(!store.toolOutputStore.hasCompleteOutput(for: "tool-1"))
        #expect(store.lastError == nil)
    }

    @Test func controlSessionExpansionLoadsFullOutputFromControlRoute() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"output":"full control-session output"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacSessionTraceStore()
        let target = makeControlTarget()
        store.select(target)
        store.toolOutputStore.replace(
            "bounded preview",
            for: "tool-1",
            previewOnly: true,
            totalBytes: 2_000
        )

        await store.loadFullToolOutputIfNeeded(itemID: "tool-1", target: target, client: client)

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/control-sessions/session-tool-output/tool-output/tool-1?full=true")
        #expect(store.toolOutputStore.fullOutput(for: "tool-1") == "full control-session output")
        #expect(store.toolOutputStore.hasCompleteOutput(for: "tool-1"))
    }

    @Test func expandPaintsPreviewOnlyStoreSnapshotNotChatItemPreview() {
        let storeSnapshot = String(repeating: "x", count: 1_200)
        let chatPreview = String(repeating: "p", count: ChatItem.maxPreviewLength)
        #expect(
            MacToolRowOutput.displayed(
                isExpanded: true,
                storeOutput: storeSnapshot,
                outputPreview: chatPreview
            ) == storeSnapshot
        )
        #expect(
            MacToolRowOutput.displayed(
                isExpanded: false,
                storeOutput: storeSnapshot,
                outputPreview: chatPreview
            ) == chatPreview
        )
        #expect(
            MacToolRowOutput.displayed(
                isExpanded: true,
                storeOutput: "",
                outputPreview: chatPreview
            ) == chatPreview
        )

        let outputs = ToolOutputStore()
        outputs.replace(
            storeSnapshot,
            for: "tool-preview",
            previewOnly: true,
            totalBytes: storeSnapshot.utf8.count
        )
        let collapsed = MacToolRowPresentation.make(
            toolRowID: "tool-preview",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: chatPreview,
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore(),
            isExpanded: false
        )
        let expanded = MacToolRowPresentation.make(
            toolRowID: "tool-preview",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: chatPreview,
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore(),
            isExpanded: true
        )
        guard case .terminal(let collapsedTerminal) = collapsed.content else {
            Issue.record("Expected collapsed .terminal, got \(String(describing: collapsed.content))")
            return
        }
        guard case .terminal(let expandedTerminal) = expanded.content else {
            Issue.record("Expected expanded .terminal, got \(String(describing: expanded.content))")
            return
        }
        #expect(collapsedTerminal.output == chatPreview)
        #expect(expandedTerminal.output == storeSnapshot)
    }

    private func makeTarget() -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "session-tool-output",
            workspaceId: "workspace-tool-output",
            workspaceName: "Workspace",
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-tool-output",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }

    private func makeControlTarget() -> MacSelectedSessionTarget {
        var session = makeTarget().summary.session
        session.workspaceId = nil
        session.workspaceName = "Pi Control"
        session.control = ControlSessionMetadata(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Agent"
        )
        return MacSelectedSessionTarget(
            workspaceId: "",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}
