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

    @Test func refreshRemainsInFlightUntilCorrelatedQueueResultArrives() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)

        let getQueueRequest = QueueRequestIdBox()
        store._sendLiveMessageForTesting = { message in
            guard case .getQueue(let requestId) = message else {
                Issue.record("Unexpected queue command: \(message)")
                return true
            }
            guard let requestId else {
                Issue.record("Queue refresh should include a request ID")
                return true
            }
            getQueueRequest.complete(requestId)
            return true
        }

        let refreshTask = Task {
            await store.refreshQueue(target: target, client: Self.unusedClient)
        }

        let requestId = await getQueueRequest.value()
        #expect(store.isRefreshingQueue)

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_queue",
                requestId: requestId,
                success: true,
                data: [
                    "version": 3,
                    "steering": [],
                    "followUp": [],
                ],
                error: nil
            ),
            target: target
        )

        await refreshTask.value
        #expect(!store.isRefreshingQueue)
        #expect(store.messageQueue.version == 3)
        #expect(store.messageQueueError == nil)
    }

    @Test func rejectedMutationWaitsForCommandResultAndReconcilesLatestQueue() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)
        store.applyServerMessageForTesting(
            .queueState(queue: MessageQueueState(
                version: 1,
                steering: [item(id: "old", message: "old queue")],
                followUp: []
            )),
            target: target
        )

        let setQueueRequest = QueueRequestIdBox()
        var sentCommands: [String] = []
        store._sendLiveMessageForTesting = { message in
            switch message {
            case .setQueue(_, _, _, let requestId):
                sentCommands.append("set_queue")
                if let requestId {
                    setQueueRequest.complete(requestId)
                }
            case .getQueue(let requestId):
                sentCommands.append("get_queue")
                store.applyServerMessageForTesting(
                    .commandResult(
                        command: "get_queue",
                        requestId: requestId,
                        success: true,
                        data: [
                            "version": 2,
                            "steering": [
                                ["id": "latest", "message": "server latest", "createdAt": 1_800_000_000_001],
                            ],
                            "followUp": [],
                        ],
                        error: nil
                    ),
                    target: target
                )
            default:
                Issue.record("Unexpected queue command: \(message)")
            }
            return true
        }

        let mutation = MacMessageQueueMutationRequest(
            baseVersion: 1,
            steering: [],
            followUp: []
        )
        let mutationTask = Task {
            try await store.applyQueueMutation(
                mutation,
                target: target,
                client: Self.unusedClient
            )
        }

        let requestId = await setQueueRequest.value()
        store.applyServerMessageForTesting(
            .commandResult(
                command: "set_queue",
                requestId: requestId,
                success: false,
                data: nil,
                error: "Queue version mismatch"
            ),
            target: target
        )

        await #expect(throws: MacSessionTraceStoreError.commandRejected("Queue version mismatch")) {
            try await mutationTask.value
        }
        #expect(sentCommands == ["set_queue", "get_queue"])
        #expect(store.messageQueue.version == 2)
        #expect(store.messageQueue.steering.map(\.message) == ["server latest"])
        #expect(store.messageQueueError == "Queue version mismatch")
        #expect(!store.isUpdatingQueue)
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

    private static let unusedClient = MacWorkspaceClient(
        socketPath: "/tmp/oppi-mac-queue-unused.sock",
        token: "test"
    )
}

@MainActor
private final class QueueRequestIdBox {
    private var requestId: String?
    private var continuation: CheckedContinuation<String, Never>?

    func complete(_ requestId: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: requestId)
        } else {
            self.requestId = requestId
        }
    }

    func value() async -> String {
        if let requestId {
            return requestId
        }
        return await withCheckedContinuation { continuation in
            if let requestId {
                continuation.resume(returning: requestId)
            } else {
                self.continuation = continuation
            }
        }
    }
}
