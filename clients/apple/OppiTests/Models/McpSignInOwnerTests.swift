import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("MCP sign-in list ownership")
struct McpSignInOwnerTests {
    private func makeOwner(client: McpOwnerClient) -> McpSignInOwner {
        let owner = McpSignInOwner()
        owner.adopt(ProviderAuthFlowAttempt(
            flow: mcpOwnerFlow(.awaitingManualCode), client: client,
            serverId: "original-host", serverName: "Studio", providerName: "remote"
        ), scopeId: "project")
        return owner
    }

    @Test func leavingDetailAndClosingSheetRetainContinueAndHostBoundCancel() async {
        let client = McpOwnerClient()
        let owner = makeOwner(client: client)
        defer { owner.attempt?.stopPolling() }
        weak var detailAttempt = owner.attempt
        owner.sheetDismissed()
        #expect(owner.hasActive)
        #expect(owner.attempt === detailAttempt)
        #expect(owner.scopeId == "project")
        #expect(owner.attempt?.serverId == "original-host")
        owner.resume()
        #expect(owner.showingSheet)
        await owner.cancel()
        #expect(await client.cancellations == ["pa_mcp"])
        #expect(!owner.hasActive)
        #expect(!owner.showingSheet)
    }

    @Test func acceptedPasteShowsProgressAcrossCloseAndResumeAndCannotSubmitTwice() async {
        let client = McpOwnerClient()
        let owner = makeOwner(client: client)
        defer { owner.attempt?.stopPolling() }
        owner.attempt?.input = "http://127.0.0.1/callback?code=fixture"
        #expect(owner.canSubmitCallback)
        await owner.submitCallback()
        #expect(owner.callbackAccepted)
        #expect(owner.hasActive) // Relay acceptance does not claim completion.
        owner.sheetDismissed()
        owner.resume()
        owner.attempt?.input = "another callback"
        #expect(!owner.canSubmitCallback)
        await owner.submitCallback()
        #expect(await client.submissions == 1)
    }

    @Test func failedPasteAndCancelKeepTheRecoveryHandle() async {
        let client = McpOwnerClient(failActions: true)
        let owner = makeOwner(client: client)
        defer { owner.attempt?.stopPolling() }
        owner.attempt?.input = "bad callback"
        await owner.submitCallback()
        #expect(!owner.callbackAccepted)
        #expect(owner.canSubmitCallback)
        #expect(owner.attempt?.actionError != nil)
        await owner.cancel()
        #expect(owner.hasActive)
        #expect(owner.showingSheet)
        #expect(owner.attempt?.actionError != nil)
    }
}

private func mcpOwnerFlow(_ status: ProviderAuthFlowSnapshot.Status) -> ProviderAuthFlowSnapshot {
    ProviderAuthFlowSnapshot(
        flowId: "pa_mcp", providerId: "remote", flowType: .oauthCallback,
        launchMode: .phoneBrowser, status: status, auth: nil, prompt: nil,
        lastProgress: nil, error: nil, createdAt: 1, updatedAt: 2, expiresAt: 9
    )
}
private actor McpOwnerClient: ProviderAuthFlowClient {
    let failActions: Bool
    private(set) var submissions = 0
    private(set) var cancellations: [String] = []
    init(failActions: Bool = false) { self.failActions = failActions }
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        try await Task.sleep(for: .seconds(3600))
        return mcpOwnerFlow(.awaitingManualCode)
    }
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        submissions += 1
        if failActions { throw APIError.server(status: 400, message: "Invalid callback") }
        return mcpOwnerFlow(.awaitingManualCode)
    }
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot {
        cancellations.append(flowId)
        if failActions { throw APIError.server(status: 503, message: "Try again") }
        return mcpOwnerFlow(.cancelled)
    }
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.invalidResponse
    }
}
