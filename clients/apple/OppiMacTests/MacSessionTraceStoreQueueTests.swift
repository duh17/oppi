import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace queue handling")
struct MacSessionTraceStoreQueueTests {
    @Test func appliesQueueStateAndStartedEvents() {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)

        let first = item(id: "one", message: "first")
        let second = item(id: "two", message: "second")
        store.applyServerMessageForTesting(
            .queueState(queue: MessageQueueState(version: 1, steering: [first], followUp: [second])),
            target: target
        )

        #expect(store.showsMessageQueue)
        #expect(store.messageQueue.steering.map(\.message) == ["first"])
        #expect(store.messageQueue.followUp.map(\.message) == ["second"])

        store.applyServerMessageForTesting(
            .queueItemStarted(kind: .steer, item: first, queueVersion: 2),
            target: target
        )

        #expect(store.messageQueue.version == 2)
        #expect(store.messageQueue.steering.isEmpty)
        #expect(store.messageQueue.followUp.map(\.message) == ["second"])
    }

    @Test func appliesQueueStateFromCommandResultData() {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_queue",
                requestId: "request-1",
                success: true,
                data: [
                    "version": 5,
                    "steering": [
                        ["id": "s", "message": "steer", "createdAt": 1_800_000_000_000],
                    ],
                    "followUp": [],
                ],
                error: nil
            ),
            target: target
        )

        #expect(store.messageQueue.version == 5)
        #expect(store.messageQueue.steering.map(\.message) == ["steer"])
    }

    @Test func clearsQueueOnSessionEnded() {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)
        store.applyServerMessageForTesting(
            .queueState(queue: MessageQueueState(version: 1, steering: [item(id: "one", message: "first")], followUp: [])),
            target: target
        )

        store.applyServerMessageForTesting(.sessionEnded(reason: "done"), target: target)

        #expect(store.messageQueue == .empty)
    }

    private func makeTarget(status: SessionStatus) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "session-queue",
            workspaceId: "workspace-queue",
            workspaceName: "Workspace",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-queue",
            sessionId: "session-queue",
            summary: SessionSummary(from: session)
        )
    }

    private func item(id: String, message: String) -> MessageQueueItem {
        MessageQueueItem(id: id, message: message, createdAt: 1_800_000_000_000)
    }
}
