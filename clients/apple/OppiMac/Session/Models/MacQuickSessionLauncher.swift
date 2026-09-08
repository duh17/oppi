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

    /// Completes a launch into the pane that started it. Always returns the
    /// created session so the catalog can keep it. Placement happens only when
    /// that same runtime is still empty and still waiting on this attempt.
    @MainActor
    static func launchIntoOriginatingPane(
        attempt: MacQuickSessionLaunchAttempt,
        originatingRuntime: MacSessionPaneRuntime,
        deck: MacSessionPaneDeck,
        client: MacWorkspaceClient
    ) async throws -> MacSelectedSessionTarget? {
        let target = try await launch(attempt: attempt, client: client)
        // Server creation succeeded. Place only when this same empty pane is
        // still waiting on this attempt; otherwise keep the created session
        // discoverable without clobbering a later draft or session B.
        if canPlace(
            attempt: attempt,
            originatingRuntime: originatingRuntime,
            deck: deck
        ) {
            originatingRuntime.quickSession.markLaunchSucceeded(
                idempotencyKey: attempt.idempotencyKey
            )
            _ = deck.replace(paneID: originatingRuntime.id, with: target)
        }
        return target
    }

    @MainActor
    static func canPlace(
        attempt: MacQuickSessionLaunchAttempt,
        originatingRuntime: MacSessionPaneRuntime,
        deck: MacSessionPaneDeck
    ) -> Bool {
        guard deck.runtime(for: originatingRuntime.id) === originatingRuntime else {
            return false
        }
        guard originatingRuntime.isEmpty else { return false }
        return originatingRuntime.quickSession.pendingLaunchAttempt?.idempotencyKey
            == attempt.idempotencyKey
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
