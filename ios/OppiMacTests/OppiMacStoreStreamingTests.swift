@testable import OppiMac
import XCTest

@MainActor
final class OppiMacStoreStreamingTests: XCTestCase {
    func testPermissionQueueApproveSendsResponseAndClears() async {
        let store = makeStore()
        let stream = MockStreamingClient()
        store._setStreamingClientForTesting(stream, workspaceID: "ws-1", sessionID: "sess-1")
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"

        let request = PermissionRequest(
            id: "perm-1",
            sessionId: "sess-1",
            tool: "bash",
            input: ["command": .string("rm -rf /tmp/demo")],
            displaySummary: "rm -rf /tmp/demo",
            risk: .high,
            reason: "destructive command",
            timeoutAt: Date().addingTimeInterval(120)
        )

        store._handleStreamMessageForTesting(.permissionRequest(request), workspaceID: "ws-1", sessionID: "sess-1")
        XCTAssertEqual(store.selectedSessionPendingPermissions.map(\.id), ["perm-1"])

        await store.respondToPermission(id: "perm-1", action: .allow)

        XCTAssertTrue(store.selectedSessionPendingPermissions.isEmpty)
        let responses = stream.permissionResponsesSnapshot()
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0].id, "perm-1")
        XCTAssertEqual(responses[0].action, .allow)
    }

    func testPermissionQueueDenyNextSendsResponseAndClears() async {
        let store = makeStore()
        let stream = MockStreamingClient()
        store._setStreamingClientForTesting(stream, workspaceID: "ws-1", sessionID: "sess-1")
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"

        let request = PermissionRequest(
            id: "perm-2",
            sessionId: "sess-1",
            tool: "bash",
            input: ["command": .string("sudo rm -rf /")],
            displaySummary: "sudo rm -rf /",
            risk: .critical,
            reason: "dangerous command",
            timeoutAt: Date().addingTimeInterval(120)
        )

        store._handleStreamMessageForTesting(.permissionRequest(request), workspaceID: "ws-1", sessionID: "sess-1")
        XCTAssertEqual(store.selectedSessionPendingPermissions.map(\.id), ["perm-2"])

        await store.denyFirstPendingPermission()

        XCTAssertTrue(store.selectedSessionPendingPermissions.isEmpty)
        let responses = stream.permissionResponsesSnapshot()
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0].id, "perm-2")
        XCTAssertEqual(responses[0].action, .deny)
    }

    func testAssistantStreamingDeltasCollapseIntoSingleItem() {
        let store = makeStore()
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"

        store._handleStreamMessageForTesting(.textDelta(delta: "hel"), workspaceID: "ws-1", sessionID: "sess-1")
        store._handleStreamMessageForTesting(.textDelta(delta: "lo"), workspaceID: "ws-1", sessionID: "sess-1")
        store._handleStreamMessageForTesting(.messageEnd(role: "assistant", content: "hello"), workspaceID: "ws-1", sessionID: "sess-1")

        guard let last = store.timelineItems.last else {
            XCTFail("Expected assistant timeline item")
            return
        }

        XCTAssertEqual(last.kind, .assistant)
        XCTAssertEqual(last.detail, "hello")
        XCTAssertEqual(last.metadata["source"], "ws")
    }

    func testCompactionEventsUseCompactionTimelineKind() {
        let store = makeStore()
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"

        store._handleStreamMessageForTesting(.compactionStart(reason: "context usage high"), workspaceID: "ws-1", sessionID: "sess-1")

        guard let last = store.timelineItems.last else {
            XCTFail("Expected compaction timeline item")
            return
        }

        XCTAssertEqual(last.kind, .compaction)
        XCTAssertEqual(last.metadata["source"], "ws")
        XCTAssertTrue(last.detail.localizedCaseInsensitiveContains("compaction"))
    }

    func testSendPromptFromComposerUsesWebSocketPromptMessage() async {
        let store = makeStore()
        let stream = MockStreamingClient()
        store._setStreamingClientForTesting(stream, workspaceID: "ws-1", sessionID: "sess-1")
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"
        store.composerText = "ship it"

        await store.sendPromptFromComposer()

        XCTAssertEqual(store.composerText, "")
        let prompts = stream.promptsSnapshot()
        XCTAssertEqual(prompts, ["ship it"])
    }

    func testSendStopTurnUsesWebSocketStopMessage() async {
        let store = makeStore()
        let stream = MockStreamingClient()
        store._setStreamingClientForTesting(stream, workspaceID: "ws-1", sessionID: "sess-1")
        store.selectedWorkspaceID = "ws-1"
        store.selectedSessionID = "sess-1"

        await store.sendStopTurn()

        XCTAssertEqual(stream.stopMessageCountSnapshot(), 1)
    }

    private func makeStore() -> OppiMacStore {
        let suiteName = "OppiMacStoreStreamingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return OppiMacStore(userDefaults: defaults)
    }
}

@MainActor
private final class MockStreamingClient: OppiMacStreamingClient {
    struct PermissionResponse: Equatable {
        let id: String
        let action: PermissionAction
    }

    private(set) var status: WebSocketClient.Status = .disconnected
    private var permissionResponses: [PermissionResponse] = []
    private var prompts: [String] = []
    private var stopMessageCount = 0

    func connect(sessionId: String, workspaceId: String) -> AsyncStream<ServerMessage> {
        _ = sessionId
        _ = workspaceId
        status = .connected
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func send(_ message: ClientMessage) async throws {
        switch message {
        case .permissionResponse(let id, let action, _, _, _):
            permissionResponses.append(.init(id: id, action: action))
        case .prompt(let message, _, _, _, _):
            prompts.append(message)
        case .stop:
            stopMessageCount += 1
        default:
            break
        }
    }

    func disconnect() {
        status = .disconnected
    }

    func permissionResponsesSnapshot() -> [PermissionResponse] {
        permissionResponses
    }

    func promptsSnapshot() -> [String] {
        prompts
    }

    func stopMessageCountSnapshot() -> Int {
        stopMessageCount
    }
}
