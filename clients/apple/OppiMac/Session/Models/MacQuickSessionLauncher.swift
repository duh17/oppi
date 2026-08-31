import Foundation

enum MacQuickSessionLauncher {
    static func launch(
        attempt: MacQuickSessionLaunchAttempt,
        client: MacWorkspaceClient
    ) async throws -> MacSelectedSessionTarget {
        switch attempt.plan.mode {
        case .plainPi:
            let response = try await client.createWorkspaceSession(
                workspaceId: attempt.plan.workspaceId,
                prompt: attempt.plan.shouldAutoSend ? attempt.plan.prompt : nil,
                worktreeId: attempt.plan.worktreeId,
                idempotencyKey: attempt.idempotencyKey
            )
            return MacSelectedSessionTarget(
                workspaceId: response.session.workspaceId ?? attempt.plan.workspaceId,
                sessionId: response.session.id,
                summary: SessionSummary(from: response.session)
            )
        case .agent(let agentId):
            let response = try await client.launchAgentSession(
                agentId: agentId,
                prompt: attempt.plan.prompt,
                workspaceId: attempt.plan.workspaceId,
                worktreeId: attempt.plan.worktreeId,
                idempotencyKey: attempt.idempotencyKey
            )
            guard QuickSessionLaunchRouting.canNavigateAfterAgentLaunch(response),
                  let session = response.session else {
                throw MacQuickSessionLaunchError.agentLaunchRejected
            }
            return MacSelectedSessionTarget(
                workspaceId: session.workspaceId ?? attempt.plan.workspaceId,
                sessionId: session.id,
                summary: SessionSummary(from: session)
            )
        }
    }

    /// Completes a launch into the pane that started it. Returns nil when that
    /// pane is gone instead of replacing whatever is focused now.
    @MainActor
    static func launchIntoOriginatingPane(
        attempt: MacQuickSessionLaunchAttempt,
        originatingRuntime: MacSessionPaneRuntime,
        deck: MacSessionPaneDeck,
        client: MacWorkspaceClient
    ) async throws -> MacSelectedSessionTarget? {
        let target = try await launch(attempt: attempt, client: client)
        originatingRuntime.quickSession.markLaunchSucceeded(idempotencyKey: attempt.idempotencyKey)
        guard deck.replace(paneID: originatingRuntime.id, with: target) != nil else {
            return nil
        }
        return target
    }
}

enum MacQuickSessionLaunchError: Error, Equatable, LocalizedError {
    case agentLaunchRejected

    var errorDescription: String? {
        switch self {
        case .agentLaunchRejected:
            "The Agent launch was not delivered."
        }
    }
}
