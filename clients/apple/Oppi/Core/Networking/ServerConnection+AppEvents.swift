import Foundation

// MARK: - Global App Event Routing

extension ServerConnection {
    /// Route a global app event directly to app/store surfaces.
    ///
    /// This path is intentionally separate from focused-session timeline routing.
    /// Do not convert these events into `ServerMessage` or feed them to
    /// `ChatSessionManager.routeToTimeline(...)` / `TimelineReducer`.
    func handleAppEvent(_ event: AppEventMessage) {
        switch event {
        case .connected:
            break

        case .sessionCreated(_, let workspaceId, _, let summary),
             .sessionImported(_, let workspaceId, _, let summary),
             .sessionDiscovered(_, let workspaceId, _, let summary),
             .sessionSummary(_, let workspaceId, _, let summary):
            applyAppEventSummary(summary, workspaceId: workspaceId)

        case .sessionDeleted(let sessionId, let workspaceId, _):
            removeSessionFromAppEvent(sessionId: sessionId, workspaceId: workspaceId)

        case .sessionEnded(let sessionId, let workspaceId, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .stopped)
            clearSessionScopedAppEventState(sessionId: sessionId)

        case .stopRequested(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .stopping)

        case .stopConfirmed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .ready, onlyFrom: .stopping)
            clearSessionScopedAppEventState(sessionId: sessionId)

        case .stopFailed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .busy, onlyFrom: .stopping)

        case .sessionError(let sessionId, let workspaceId, _, _, _, let fatal):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .error)
            if fatal {
                clearSessionScopedAppEventState(sessionId: sessionId)
            }

        case .extensionUIRequest(let request, let workspaceId, _):
            var routedRequest = request
            if routedRequest.workspaceId == nil {
                routedRequest.workspaceId = workspaceId
            }
            if let ask = routedRequest.askRequest {
                storeAskRequest(ask, for: routedRequest.sessionId, isFocusedSession: isFocusedSession(routedRequest.sessionId))
            } else {
                storeExtensionDialog(
                    routedRequest,
                    for: routedRequest.sessionId,
                    isFocusedSession: isFocusedSession(routedRequest.sessionId)
                )
            }

        case .extensionUISettled(let id, let sessionId, let workspaceId, _):
            clearAskRequest(id: id)
            clearExtensionDialog(id: id)
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            } else if let resolvedWorkspaceId = sessionStore.workspaceId(for: sessionId) {
                syncWorkspaceSummary(workspaceId: resolvedWorkspaceId)
            }

        case .extensionUINotification(let notification, let sessionId, _, _):
            applyExtensionUINotification(
                method: notification.method,
                message: notification.message,
                notifyType: notification.notifyType,
                statusKey: notification.statusKey,
                statusText: notification.statusText,
                title: notification.title,
                text: notification.text,
                widgetKey: notification.widgetKey,
                widgetLines: notification.widgetLines,
                widgetPlacement: notification.widgetPlacement,
                extensionScopeId: notification.extensionScopeId,
                extensionDisplayName: notification.extensionDisplayName,
                workingIndicator: notification.workingIndicator,
                workingVisible: notification.workingVisible,
                hiddenThinkingLabel: notification.hiddenThinkingLabel,
                toolsExpanded: notification.toolsExpanded,
                nativeSurface: notification.nativeSurface,
                sessionId: sessionId,
                isActiveSession: isFocusedSession(sessionId)
            )

        case .workspaceGitChanged(let workspaceId, let worktreeId, _, _, _):
            invalidateWorkspaceCaches(workspaceId: workspaceId, worktreeId: worktreeId)

        case .ignored:
            break
        }
    }

    func respondToExtensionUI(
        workspaceId: String,
        sessionId: String,
        id: String,
        payload: ExtensionUIResponsePayload
    ) async throws {
        guard let apiClient else { throw APIError.invalidResponse }
        try await apiClient.sendExtensionUIResponse(
            workspaceId: workspaceId,
            sessionId: sessionId,
            id: id,
            payload: payload
        )
        clearExtensionDialog(id: id)
        clearAskRequest(id: id)
    }

    private func applyAppEventSummary(_ summary: SessionSummary, workspaceId: String?) {
        var normalized = summary
        if normalized.workspaceId == nil, let workspaceId, !workspaceId.isEmpty {
            normalized.workspaceId = workspaceId
        }
        let previousSession = sessionStore.session(id: normalized.id)
        let previousWorkspaceId = previousSession?.workspaceId
        sessionStore.applySummary(normalized)
        if previousSession?.status.isRunning == true,
           normalized.status.isTerminal,
           let completedAt = normalized.lastAgentReplyAt,
           completedAt != previousSession?.lastAgentReplyAt {
            recordUnreadCompletionIfNeeded(sessionId: normalized.id, at: completedAt)
        }
        if let previousWorkspaceId, previousWorkspaceId != normalized.workspaceId {
            syncWorkspaceSummary(workspaceId: previousWorkspaceId)
        }
        if let workspaceId = normalized.workspaceId {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
        syncLiveActivityState()
    }

    private func updateSessionStatusFromAppEvent(
        sessionId: String,
        workspaceId: String?,
        status: SessionStatus,
        onlyFrom: SessionStatus? = nil
    ) {
        guard var current = sessionStore.session(id: sessionId) else { return }
        if let onlyFrom, current.status != onlyFrom { return }
        let completedAt = Date()
        current.status = status
        if status == .ready || status == .stopped || status == .error {
            current.currentTurnStartedAt = nil
        }
        current.lastActivity = completedAt
        if current.workspaceId == nil {
            current.workspaceId = workspaceId
        }
        sessionStore.upsert(current)
        if let resolvedWorkspaceId = current.workspaceId ?? workspaceId {
            syncWorkspaceSummary(workspaceId: resolvedWorkspaceId)
        }
        if status.isRunning {
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
        } else {
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
        }
        syncLiveActivityState()
    }

    private func removeSessionFromAppEvent(sessionId: String, workspaceId: String?) {
        let resolvedWorkspaceId = workspaceId ?? sessionStore.workspaceId(for: sessionId)
        sessionStore.remove(id: sessionId)
        clearSessionScopedAppEventState(sessionId: sessionId)
        if let resolvedWorkspaceId {
            syncWorkspaceSummary(workspaceId: resolvedWorkspaceId)
        }
        syncLiveActivityState()
    }

    private func clearSessionScopedAppEventState(sessionId: String) {
        clearAskState(for: sessionId)
        clearExtensionDialog(for: sessionId)
        clearExtensionSurface(for: sessionId)
        messageQueueStore.clear(sessionId: sessionId)
        screenAwakeController.clearSessionActivity(sessionId: sessionId)
        sessionUsageMetricSnapshots.removeValue(forKey: sessionId)
        sessionUsageMetricLastEmittedAt.removeValue(forKey: sessionId)
    }

    private func invalidateWorkspaceCaches(workspaceId: String, worktreeId: String? = nil) {
        gitStatusStore.invalidate(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: apiClient)
        fileIndexStore.invalidate(workspaceId: workspaceId)
        Task { await FileBrowserCache.shared.invalidateWorkspaceCaches(for: workspaceId) }
    }
}
