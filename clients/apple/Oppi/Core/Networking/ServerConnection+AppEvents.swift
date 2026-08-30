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
            removeSessionFromAppEvent(event, sessionId: sessionId, workspaceId: workspaceId)

        case .sessionEnded(let sessionId, let workspaceId, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .stopped)
            clearSessionScopedAppEventState(for: event, sessionId: sessionId)

        case .stopRequested(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .stopping)

        case .stopConfirmed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .ready, onlyFrom: .stopping)
            clearSessionScopedAppEventState(for: event, sessionId: sessionId)

        case .stopFailed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .busy, onlyFrom: .stopping)

        case .sessionError(let sessionId, let workspaceId, _, _, _, let fatal):
            updateSessionStatusFromAppEvent(sessionId: sessionId, workspaceId: workspaceId, status: .error)
            if fatal {
                clearSessionScopedAppEventState(for: event, sessionId: sessionId)
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

        case .extensionUISettled(_, let sessionId, let workspaceId, _):
            applyCleanupEffects(ServerMessageEffects.cleanupEffects(for: event))
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            } else if let resolvedWorkspaceId = sessionStore.workspaceId(for: sessionId) {
                syncWorkspaceSummary(workspaceId: resolvedWorkspaceId)
            }

        case .extensionUINotification(let notification, let sessionId, _, _):
            applyExtensionUINotification(
                notification,
                sessionId: sessionId,
                isActiveSession: isFocusedSession(sessionId)
            )

        case .workspaceGitChanged(let workspaceId, let worktreeId, _, _, _):
            invalidateWorkspaceCaches(workspaceId: workspaceId, worktreeId: worktreeId)
            refreshWorkspaceSidebarGitSummary(workspaceId: workspaceId, worktreeId: worktreeId)

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
        try await respondToExtensionUI(
            routeScope: .workspace(workspaceId),
            sessionId: sessionId,
            id: id,
            payload: payload
        )
    }

    func respondToExtensionUI(
        routeScope: SessionRouteScope,
        sessionId: String,
        id: String,
        payload: ExtensionUIResponsePayload
    ) async throws {
        guard let apiClient else { throw APIError.invalidResponse }
        try await apiClient.sendExtensionUIResponse(
            scope: routeScope,
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

    private func removeSessionFromAppEvent(
        _ event: AppEventMessage,
        sessionId: String,
        workspaceId: String?
    ) {
        let resolvedWorkspaceId = workspaceId ?? sessionStore.workspaceId(for: sessionId)
        sessionStore.remove(id: sessionId)
        clearSessionScopedAppEventState(for: event, sessionId: sessionId)
        if let resolvedWorkspaceId {
            syncWorkspaceSummary(workspaceId: resolvedWorkspaceId)
        }
        syncLiveActivityState()
    }

    private func clearSessionScopedAppEventState(for event: AppEventMessage, sessionId: String) {
        applyCleanupEffects(ServerMessageEffects.cleanupEffects(for: event))
        screenAwakeController.clearSessionActivity(sessionId: sessionId)
        sessionUsageMetricSnapshots.removeValue(forKey: sessionId)
        sessionUsageMetricLastEmittedAt.removeValue(forKey: sessionId)
    }

    private func refreshWorkspaceSidebarGitSummary(
        workspaceId: String,
        worktreeId: String?
    ) {
        let normalizedWorktreeId = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedWorktreeId == nil || normalizedWorktreeId == WorkspaceWorktree.mainId else {
            return
        }
        let testFetch = _getWorkspaceGitSummaryForTesting
        guard testFetch != nil || apiClient != nil else { return }

        let generation = (workspaceGitSummaryRefreshGeneration[workspaceId] ?? 0) &+ 1
        workspaceGitSummaryRefreshGeneration[workspaceId] = generation
        workspaceGitSummaryRefreshTasks[workspaceId]?.cancel()
        let debounce = workspaceGitSummaryRefreshDebounce

        workspaceGitSummaryRefreshTasks[workspaceId] = Task { @MainActor [weak self, apiClient, testFetch] in
            do {
                try await Task.sleep(for: debounce)
                guard let self,
                      !Task.isCancelled,
                      self.workspaceGitSummaryRefreshGeneration[workspaceId] == generation else {
                    return
                }
                let fetched: WorkspaceGitSummary
                if let testFetch {
                    fetched = try await testFetch(workspaceId)
                } else if let apiClient {
                    fetched = try await apiClient.getWorkspaceGitSummary(workspaceId: workspaceId)
                } else {
                    return
                }
                guard !Task.isCancelled,
                      self.workspaceGitSummaryRefreshGeneration[workspaceId] == generation else {
                    return
                }
                self.workspaceStore.updateGitSummary(
                    fetched.isGitRepo ? fetched : nil,
                    workspaceId: workspaceId
                )
                self.workspaceGitSummaryRefreshTasks.removeValue(forKey: workspaceId)
            } catch is CancellationError {
                // A newer invalidation owns the next compact refresh.
            } catch {
                guard let self,
                      self.workspaceGitSummaryRefreshGeneration[workspaceId] == generation else {
                    return
                }
                self.workspaceGitSummaryRefreshTasks.removeValue(forKey: workspaceId)
                self.recordRefreshEvent(
                    "workspace_git_summary.refresh_failed",
                    level: .warning,
                    metadata: Self.refreshErrorMetadata(error)
                )
            }
        }
    }

    private func invalidateWorkspaceCaches(workspaceId: String, worktreeId: String? = nil) {
        gitStatusStore.invalidate(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: apiClient)
        fileIndexStore.invalidate(workspaceId: workspaceId)
        Task { await FileBrowserCache.shared.invalidateWorkspaceCaches(for: workspaceId) }
    }
}
