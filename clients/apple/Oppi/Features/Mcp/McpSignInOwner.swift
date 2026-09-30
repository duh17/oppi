import SwiftUI

/// The list owns the host-bound attempt, so popping a detail cannot lose its
/// Continue/Cancel handle. Closing the sheet and backgrounding do not cancel it.
@MainActor @Observable
final class McpSignInOwner {
    private(set) var attempt: ProviderAuthFlowAttempt?
    private(set) var scopeId: String?
    private(set) var callbackAccepted = false
    var showingSheet = false

    var hasActive: Bool { attempt?.isSettled == false }
    var canSubmitCallback: Bool {
        guard let attempt else { return false }
        return !callbackAccepted && !attempt.isSettled && !attempt.isSubmitting && !attempt.isCancelling
            && attempt.flow.status == .awaitingManualCode
            && !attempt.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func adopt(_ attempt: ProviderAuthFlowAttempt, scopeId: String) {
        self.attempt = attempt
        self.scopeId = scopeId
        callbackAccepted = false
        resume()
    }

    /// Adopt the host's live flow when this view has no handle for it (a fresh list view,
    /// another sidebar destination, a switched host). Continue/Cancel appear; the sheet does not.
    func reconcile(_ flow: McpAuthFlowSnapshot, client: any ProviderAuthFlowClient, serverId: String, serverName: String) {
        guard !flow.status.isTerminal, attempt?.flow.flowId != flow.flowId || attempt?.isSettled == true else { return }
        attempt?.stopPolling()
        let adopted = ProviderAuthFlowAttempt(
            flow: flow.providerPresentation, client: client,
            serverId: serverId, serverName: serverName, providerName: flow.serverName
        )
        attempt = adopted
        scopeId = flow.scopeId
        callbackAccepted = false
        adopted.startPolling()
    }

    func resume() {
        showingSheet = true
        attempt?.startPolling()
    }

    func sheetDismissed() {
        showingSheet = false
        if let attempt, !attempt.sheetDismissed() {
            self.attempt = nil
            scopeId = nil
            callbackAccepted = false
        }
    }

    func submitCallback() async {
        guard canSubmitCallback, let attempt else { return }
        await attempt.submitManualCode()
        // The relay's 200 is acceptance, not OAuth completion. Suppress a second
        // paste while the host child exchanges tokens and reconnects.
        if attempt.input.isEmpty && attempt.actionError == nil { callbackAccepted = true }
    }

    func cancel() async {
        guard let attempt else { return }
        if await attempt.cancel(reason: "Cancelled from MCP Servers") { showingSheet = false }
    }
}

extension McpAuthFlowSnapshot {
    var providerPresentation: ProviderAuthFlowSnapshot {
        ProviderAuthFlowSnapshot(
            flowId: flowId, providerId: serverName, flowType: .oauthCallback,
            launchMode: launchMode, status: status == .awaitingExternal ? .awaitingManualCode : status,
            auth: auth, prompt: nil, lastProgress: nil, error: error,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt
        )
    }
}
struct McpFlowClient: ProviderAuthFlowClient {
    let client: APIClient
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        try await client.getMcpAuthFlow(flowId: flowId).providerPresentation
    }
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        try await client.submitMcpCallback(flowId: flowId, input: input).providerPresentation
    }
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot {
        try await client.cancelMcpAuthFlow(flowId: flowId).providerPresentation
    }
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.server(status: 400, message: "MCP sign-in accepts a callback URL, not a prompt response")
    }
}
