import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session model persist")
struct MacSessionTraceStoreModelTests {
    @Test func persistSetModelWaitsForCommandResultBeforeRefreshingCatalog() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(runtime: .oppi)
        store.select(target)

        let requestIdBox = RequestIdBox()
        store._sendLiveMessageForTesting = { message in
            guard case .setModel(_, _, let requestId, let persist) = message else {
                return true
            }
            #expect(persist == true)
            if let requestId {
                requestIdBox.complete(requestId)
            }
            return true
        }

        var listModelsCalls = 0
        store._listModelsForTesting = {
            listModelsCalls += 1
            return [Self.gpt]
        }

        let persistTask = Task {
            await store.setModel(Self.gpt, target: target, client: Self.unusedClient, persist: true)
        }

        let requestId = await requestIdBox.value()
        #expect(listModelsCalls == 0)
        #expect(store.isUpdatingModel)

        store.applyServerMessageForTesting(
            .commandResult(
                command: "set_model",
                requestId: requestId,
                success: true,
                data: nil,
                error: nil
            ),
            target: target
        )

        await persistTask.value
        #expect(listModelsCalls == 1)
        #expect(!store.isUpdatingModel)
        #expect(store.lastError == nil)
    }

    @Test func persistSetModelRefreshesCatalogWhenCommandResultArrivesDuringSend() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(runtime: .oppi)
        store.select(target)

        var listModelsCalls = 0
        store._listModelsForTesting = {
            listModelsCalls += 1
            return [Self.gpt]
        }
        store._sendLiveMessageForTesting = { message in
            guard case .setModel(_, _, let requestId, let persist) = message,
                  persist == true,
                  let requestId else {
                return true
            }
            store.applyServerMessageForTesting(
                .commandResult(
                    command: "set_model",
                    requestId: requestId,
                    success: true,
                    data: nil,
                    error: nil
                ),
                target: target
            )
            return true
        }

        await store.setModel(Self.gpt, target: target, client: Self.unusedClient, persist: true)

        #expect(listModelsCalls == 1)
        #expect(!store.isUpdatingModel)
        #expect(store.lastError == nil)
    }

    @Test func persistSetModelDoesNotRefreshCatalogOnDelayedFailure() async {
        let store = MacSessionTraceStore()
        let target = makeTarget(runtime: .oppi)
        store.select(target)

        let requestIdBox = RequestIdBox()
        store._sendLiveMessageForTesting = { message in
            if case .setModel(_, _, let requestId, _) = message, let requestId {
                requestIdBox.complete(requestId)
            }
            return true
        }

        var listModelsCalls = 0
        store._listModelsForTesting = {
            listModelsCalls += 1
            return [Self.gpt]
        }

        let persistTask = Task {
            await store.setModel(Self.gpt, target: target, client: Self.unusedClient, persist: true)
        }

        let requestId = await requestIdBox.value()
        store.applyServerMessageForTesting(
            .commandResult(
                command: "set_model",
                requestId: requestId,
                success: false,
                data: nil,
                error: "persist failed"
            ),
            target: target
        )

        await persistTask.value
        #expect(listModelsCalls == 0)
        #expect(store.lastError == "persist failed")
        #expect(store.session?.model == "provider/model")
    }

    @Test func persistSetModelOnMirroredSessionFailsWithoutRefreshingCatalog() async {
        let store = MacSessionTraceStore()
        store.select(makeTarget(runtime: .piTui))

        var sent = false
        store._sendLiveMessageForTesting = { _ in
            sent = true
            return true
        }
        var listModelsCalls = 0
        store._listModelsForTesting = {
            listModelsCalls += 1
            return [Self.gpt]
        }

        await store.setModel(Self.gpt, target: store.selectedTarget!, client: Self.unusedClient, persist: true)

        #expect(!sent)
        #expect(listModelsCalls == 0)
        #expect(store.lastError == SessionRuntimeKind.persistUnsupportedMessage)
    }

    private static let gpt = ModelInfo(
        id: "gpt-5.5",
        name: "GPT 5.5",
        provider: "openai",
        contextWindow: 200_000
    )

    private static let unusedClient = MacWorkspaceClient(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        token: "test"
    )

    private func makeTarget(runtime: SessionRuntimeKind) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "session-model",
            workspaceId: "workspace-model",
            workspaceName: "Workspace",
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello",
            runtime: runtime
        )
        return MacSelectedSessionTarget(
            workspaceId: "workspace-model",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

@MainActor
private final class RequestIdBox {
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
