import Foundation
import Testing
@testable import Oppi

@Suite("Server detail configuration")
struct ServerDetailConfigurationTests {
    @Test func mobileOutputGuideStateDistinguishesLoadingAvailableAndFailure() {
        #expect(ServerDetailMobileOutputGuideState.resolve(configuration: nil, isLoading: true, error: nil) == .loading)
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: MobileOutputGuideConfiguration(enabled: true, revision: 4),
            isLoading: false,
            error: nil
        ) == .available(enabled: true, revision: 4, error: nil))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: nil,
            isLoading: false,
            error: "Offline"
        ) == .failed("Offline"))
    }

    @Test func mobileOutputGuideFailureKeepsLastTrustworthyValueAndSurfacesTheError() {
        let current = MobileOutputGuideConfiguration(enabled: false, revision: 7)

        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: false,
            error: "Save failed"
        ) == .available(enabled: false, revision: 7, error: "Save failed"))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: true,
            error: "Refresh failed"
        ) == .available(enabled: false, revision: 7, error: "Refresh failed"))
    }
}

// MARK: - Provider sign-in attempt

private func flowSnapshot(
    id: String = "pa_1",
    status: ProviderAuthFlowSnapshot.Status,
    updatedAt: Double
) -> ProviderAuthFlowSnapshot {
    ProviderAuthFlowSnapshot(
        flowId: id,
        providerId: "openai-codex",
        flowType: .oauth,
        launchMode: .phoneBrowser,
        status: status,
        auth: nil,
        prompt: nil,
        lastProgress: nil,
        error: nil,
        createdAt: 0,
        updatedAt: updatedAt,
        expiresAt: 600_000
    )
}

/// Scripted server for one flow. Each poll suspends until the test answers it.
private actor ScriptedProviderAuthClient: ProviderAuthFlowClient {
    enum Call: Equatable {
        case get(String)
        case manualCode(String, String)
        case cancel(String)
    }

    private(set) var calls: [Call] = []
    private var pendingGets: [CheckedContinuation<ProviderAuthFlowSnapshot, Error>] = []
    private let cancelResult: Result<ProviderAuthFlowSnapshot, Error>

    init(cancelResult: Result<ProviderAuthFlowSnapshot, Error>) {
        self.cancelResult = cancelResult
    }

    var pendingGetCount: Int { pendingGets.count }

    func answerGet(_ index: Int, with result: Result<ProviderAuthFlowSnapshot, Error>) {
        pendingGets.remove(at: index).resume(with: result)
    }

    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        calls.append(.get(flowId))
        return try await withCheckedThrowingContinuation { pendingGets.append($0) }
    }

    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }

    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        calls.append(.manualCode(flowId, input))
        return flowSnapshot(id: flowId, status: .awaitingExternal, updatedAt: 5)
    }

    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot {
        calls.append(.cancel(flowId))
        return try cancelResult.get()
    }
}

@MainActor
private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition was not met")
    throw CancellationError()
}

@MainActor
@Suite("Provider sign-in attempt")
struct ProviderAuthFlowAttemptTests {
    private func makeAttempt(
        client: ScriptedProviderAuthClient,
        sleep: @escaping ProviderAuthFlowAttempt.Sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
    ) -> ProviderAuthFlowAttempt {
        ProviderAuthFlowAttempt(
            flow: flowSnapshot(status: .awaitingManualCode, updatedAt: 1),
            client: client,
            serverId: "server-a",
            serverName: "Studio",
            providerName: "ChatGPT (Codex)",
            sleep: sleep
        )
    }

    @Test func pastedCodeAndCancelGoToTheServerThatStartedTheFlow() async throws {
        let starter = ScriptedProviderAuthClient(
            cancelResult: .success(flowSnapshot(status: .cancelled, updatedAt: 9))
        )
        let attempt = makeAttempt(client: starter)

        attempt.input = "  pasted-code "
        await attempt.submitManualCode()
        #expect(await attempt.cancel(reason: "Cancelled by user"))

        #expect(await starter.calls == [.manualCode("pa_1", "pasted-code"), .cancel("pa_1")])
        #expect(attempt.flow.status == .cancelled)
        #expect(attempt.isSettled)
    }

    @Test func dismissingALiveSheetKeepsTheLoginAndPolling() async throws {
        let client = ScriptedProviderAuthClient(cancelResult: .failure(APIError.invalidResponse))
        let attempt = makeAttempt(client: client)
        attempt.startPolling()
        try await eventually { await client.pendingGetCount == 1 }

        #expect(attempt.sheetDismissed())
        #expect(attempt.isPolling)
        #expect(await client.calls == [.get("pa_1")])

        await client.answerGet(0, with: .success(flowSnapshot(status: .completed, updatedAt: 2)))
        try await eventually { !attempt.isPolling }
        #expect(attempt.flow.status == .completed)
        #expect(!attempt.sheetDismissed())
    }

    @Test func failedCancelKeepsTheAttemptLiveWithTheError() async throws {
        let client = ScriptedProviderAuthClient(
            cancelResult: .failure(APIError.server(status: 503, message: "Server busy"))
        )
        let attempt = makeAttempt(client: client)

        #expect(await attempt.cancel(reason: "Cancelled by user") == false)
        #expect(!attempt.isSettled)
        #expect(attempt.actionError?.contains("Server busy") == true)
    }

    @Test func latePollFromAReplacedTaskIsIgnoredAndKeepsTheNewerPoll() async throws {
        let client = ScriptedProviderAuthClient(cancelResult: .failure(APIError.invalidResponse))
        let attempt = makeAttempt(client: client)

        attempt.startPolling()
        try await eventually { await client.pendingGetCount == 1 }
        // App became active again: polling restarts for the same flow.
        attempt.startPolling()
        try await eventually { await client.pendingGetCount == 2 }

        await client.answerGet(1, with: .success(flowSnapshot(status: .awaitingExternal, updatedAt: 3)))
        try await eventually { attempt.flow.status == .awaitingExternal }

        // The replaced request answers last, with a newer terminal state.
        await client.answerGet(0, with: .success(flowSnapshot(status: .completed, updatedAt: 4)))
        for _ in 0..<50 { await Task.yield() }

        #expect(attempt.flow.status == .awaitingExternal)
        #expect(attempt.isPolling)
        attempt.stopPolling()
    }

    @Test func pollingRetriesTransientErrorsAndStopsWhenTheFlowIsGone() async throws {
        let client = ScriptedProviderAuthClient(cancelResult: .failure(APIError.invalidResponse))
        let attempt = makeAttempt(client: client, sleep: { _ in })

        attempt.startPolling()
        try await eventually { await client.pendingGetCount == 1 }
        await client.answerGet(0, with: .failure(URLError(.networkConnectionLost)))
        try await eventually { await client.pendingGetCount == 1 }
        #expect(attempt.refreshError != nil)
        #expect(!attempt.isSettled)

        await client.answerGet(0, with: .failure(APIError.server(status: 404, message: "Flow not found")))
        try await eventually { !attempt.isPolling }
        #expect(attempt.isGone)
        #expect(await attempt.cancel(reason: "Cancelled by user"))
        #expect(await client.calls == [.get("pa_1"), .get("pa_1")])
    }

    @Test func retryDelayBacksOffAndIsBounded() {
        let first = ProviderAuthFlowAttempt.retryDelay(afterFailures: 1)
        #expect(first > ProviderAuthFlowAttempt.pollInterval)
        #expect(ProviderAuthFlowAttempt.retryDelay(afterFailures: 2) > first)
        #expect(ProviderAuthFlowAttempt.retryDelay(afterFailures: 50) == ProviderAuthFlowAttempt.maxRetryDelay)
        #expect(ProviderAuthFlowAttempt.retryDelay(afterFailures: Int.max) == ProviderAuthFlowAttempt.maxRetryDelay)
    }

    @Test func onlyHTTPSOrLoopbackHTTPSignInLinksAreOpenable() {
        #expect(ProviderAuthFlowPresentation.signInURL("https://auth.openai.com/authorize") != nil)
        #expect(ProviderAuthFlowPresentation.signInURL("http://localhost:1455/cb") != nil)
        #expect(ProviderAuthFlowPresentation.signInURL("http://127.0.0.1:1455/cb") != nil)
        #expect(ProviderAuthFlowPresentation.signInURL("javascript:alert(1)") == nil)
        #expect(ProviderAuthFlowPresentation.signInURL("http://auth.example.com/authorize") == nil)
        #expect(ProviderAuthFlowPresentation.signInURL("oppi://session/1") == nil)
    }
}
