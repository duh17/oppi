import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session slash commands")
struct MacSessionTraceStoreSlashCommandTests {
    @Test func loadSlashCommandsSendsGetCommandsAndAppliesResult() async {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        let requestIdBox = SlashCommandRequestIdBox()
        store._sendLiveMessageForTesting = { message in
            guard case .getCommands(let requestId) = message else {
                return true
            }
            if let requestId {
                requestIdBox.complete(requestId)
            }
            return true
        }

        let loadTask = Task {
            await store.loadSlashCommandsFromLocalConfig()
        }

        let requestId = await requestIdBox.value()
        #expect(store.isLoadingSlashCommands)

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_commands",
                requestId: requestId,
                success: true,
                data: [
                    "commands": [
                        [
                            "name": "compact",
                            "description": "Compact context",
                            "source": "prompt",
                        ],
                        [
                            "name": "skill:lint",
                            "description": "Lint",
                            "source": "skill",
                        ],
                    ],
                ],
                error: nil
            ),
            target: target
        )

        await loadTask.value
        #expect(!store.isLoadingSlashCommands)
        #expect(store.slashCommands.map(\.name) == ["compact", "skill:lint"])
        #expect(store.slashCommandsError == nil)
    }

    @Test func ignoresMismatchedSlashCommandRequestId() async {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        store._sendLiveMessageForTesting = { message in
            guard case .getCommands(let requestId) = message else {
                return true
            }
            #expect(requestId != nil)
            return true
        }

        let loadTask = Task {
            await store.loadSlashCommandsFromLocalConfig()
        }
        await loadTask.value

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_commands",
                requestId: "other-request",
                success: true,
                data: [
                    "commands": [
                        [
                            "name": "compact",
                            "description": "Compact context",
                            "source": "prompt",
                        ],
                    ],
                ],
                error: nil
            ),
            target: target
        )

        #expect(store.slashCommands.isEmpty)
        #expect(store.isLoadingSlashCommands)
    }

    @Test func selectClearsSlashCommands() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_commands",
                requestId: nil,
                success: true,
                data: [
                    "commands": [
                        [
                            "name": "compact",
                            "description": "Compact context",
                            "source": "prompt",
                        ],
                    ],
                ],
                error: nil
            ),
            target: target
        )
        #expect(store.slashCommands.map(\.name) == ["compact"])

        store.select(makeTarget(sessionId: "session-slash-2"))
        #expect(store.slashCommands.isEmpty)
    }

    private func makeTarget(sessionId: String = "session-slash") -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: sessionId,
            workspaceId: "workspace-slash",
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
            workspaceId: "workspace-slash",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

@MainActor
private final class SlashCommandRequestIdBox {
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
