import Foundation

// MARK: - Shared Store Updates

extension ServerConnection {

    /// Context returned by `applySharedStoreUpdate` for callers that need
    /// details about pre-update session state.
    struct StoreUpdateResult {
        struct SessionStateContext {
            let previousSession: Session?
            let currentSession: Session

            var previousStatus: SessionStatus? { previousSession?.status }
            var previousWorkspaceId: String? { previousSession?.workspaceId }

            var didTransitionOutOfRunning: Bool {
                guard let previousStatus else { return false }
                return previousStatus.isRunning && currentSession.status.isTerminal
            }
        }

        /// Pre-update context for `.state(session:)` messages.
        var stateContext: SessionStateContext?
        /// Whether this message type was handled by the shared helper.
        var handled: Bool

        init(
            stateContext: SessionStateContext? = nil,
            handled: Bool
        ) {
            self.stateContext = stateContext
            self.handled = handled
        }

        var previousStatus: SessionStatus? { stateContext?.previousStatus }
        var previousWorkspaceId: String? { stateContext?.previousWorkspaceId }
        var didTransitionOutOfRunning: Bool { stateContext?.didTransitionOutOfRunning ?? false }

        static let notHandled = Self(handled: false)
    }

    /// Apply store-level mutations shared by both active-session and cross-session paths.
    ///
    /// Handles session store, screen-awake, and Live Activity sync updates that
    /// are common to both message routing paths.
    ///
    /// Does NOT handle:
    /// - Coalescer/reducer routing (active-session only)
    /// - Silence watchdog (active-session only)
    /// - Message queue mutations (active-session only)
    /// - Live Activity event recording (cross-session records directly;
    ///   active-session records via coalescer flush)
    @discardableResult
    func applySharedStoreUpdate(
        for message: ServerMessage,
        sessionId: String
    ) -> StoreUpdateResult {
        switch message {

        // MARK: Tool activity tracking

        case .toolStart(let tool, let args, _, _),
             .toolUpdate(let tool, let args, _, _):
            activityStore.recordToolStart(sessionId: sessionId, tool: tool, args: args)
            return .notHandled  // let active-session path also process (watchdog, coalescer)

        // MARK: Agent lifecycle

        case .agentStart:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }),
               current.status != .stopping {
                let now = Date()
                current.status = .busy
                current.currentTurnStartedAt = now
                current.lastActivity = now
                sessionStore.upsert(current)
                if let workspaceId = current.workspaceId {
                    syncWorkspaceSummary(workspaceId: workspaceId)
                }
            }
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        case .agentEnd:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }),
               current.status.isRunning {
                current.status = .ready
                current.currentTurnStartedAt = nil
                current.lastActivity = Date()
                sessionStore.upsert(current)
                if let workspaceId = current.workspaceId {
                    syncWorkspaceSummary(workspaceId: workspaceId)
                }
            }
            sessionStore.recordTurnEnded(sessionId: sessionId)
            activityStore.clear(sessionId: sessionId)
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        // MARK: Stop lifecycle

        case .stopRequested:
            updateStopStatus(sessionId, status: .stopping)
            if let workspaceId = sessionStore.session(id: sessionId)?.workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        case .stopConfirmed:
            updateStopStatus(sessionId, status: .ready, onlyFrom: .stopping)
            if let workspaceId = sessionStore.session(id: sessionId)?.workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        case .stopFailed:
            updateStopStatus(sessionId, status: .busy, onlyFrom: .stopping)
            if let workspaceId = sessionStore.session(id: sessionId)?.workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        // MARK: Session state

        case .state(let session):
            return applySessionProjection(session)

        case .sessionSummary(let summary):
            return applySessionSummary(summary)

        case .sessionEnded:
            let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.currentTurnStartedAt = nil
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            activityStore.clear(sessionId: sessionId)
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        case .sessionDeleted(let deletedId):
            let workspaceId = sessionStore.session(id: deletedId)?.workspaceId
            sessionStore.remove(id: deletedId)
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            sessionUsageMetricSnapshots.removeValue(forKey: deletedId)
            sessionUsageMetricLastEmittedAt.removeValue(forKey: deletedId)
            activityStore.clear(sessionId: deletedId)
            screenAwakeController.clearSessionActivity(sessionId: deletedId)
            syncLiveActivityState()
            return StoreUpdateResult(handled: true)

        default:
            return .notHandled
        }
    }

    private func applySessionProjection(_ session: Session) -> StoreUpdateResult {
        applySessionProjection(sessionId: session.id, fallbackSession: session) {
            sessionStore.upsert(session)
        }
    }

    private func applySessionSummary(_ summary: SessionSummary) -> StoreUpdateResult {
        let fallbackSession = summary.session
        return applySessionProjection(sessionId: summary.id, fallbackSession: fallbackSession) {
            sessionStore.applySummary(summary)
        }
    }

    private func applySessionProjection(
        sessionId: String,
        fallbackSession: Session,
        applyStoreUpdate: () -> Void
    ) -> StoreUpdateResult {
        let previousSession = sessionStore.sessions.first(where: { $0.id == sessionId })
        applyStoreUpdate()

        let currentSession = sessionStore.sessions.first(where: { $0.id == sessionId }) ?? fallbackSession
        let stateContext = StoreUpdateResult.SessionStateContext(
            previousSession: previousSession,
            currentSession: currentSession
        )
        emitSessionUsageMetricsIfNeeded(currentSession)

        if let previousWorkspaceId = previousSession?.workspaceId,
           previousWorkspaceId != currentSession.workspaceId {
            syncWorkspaceSummary(workspaceId: previousWorkspaceId)
        }
        if let currentWorkspaceId = currentSession.workspaceId {
            syncWorkspaceSummary(workspaceId: currentWorkspaceId)
        }

        if currentSession.status.isRunning {
            screenAwakeController.setSessionActivity(true, sessionId: currentSession.id)
        } else if stateContext.didTransitionOutOfRunning {
            sessionStore.recordTurnEnded(sessionId: currentSession.id)
            activityStore.clear(sessionId: currentSession.id)
            screenAwakeController.setSessionActivity(false, sessionId: currentSession.id)
        }

        syncLiveActivityState()
        return StoreUpdateResult(stateContext: stateContext, handled: true)
    }

    func attentionWorkspaceId(explicitWorkspaceId: String?, sessionId: String?) -> String? {
        if let explicitWorkspaceId, !explicitWorkspaceId.isEmpty {
            return explicitWorkspaceId
        }
        guard let sessionId else { return nil }
        return sessionStore.workspaceId(for: sessionId)
    }

    func syncWorkspaceSummary(workspaceId: String) {
        guard !workspaceId.isEmpty else { return }

        var summaries = workspaceStore.workspaceSummaries
        let storedSummary = workspaceStore.storedWorkspaceSummaries[workspaceId]
        let fallbackSummary = fallbackWorkspaceSummary(workspaceId: workspaceId)

        guard storedSummary != nil || fallbackSummary != nil else {
            if summaries.removeValue(forKey: workspaceId) != nil {
                workspaceStore.workspaceSummaries = summaries
            }
            return
        }

        let nextSummary: WorkspaceListSummary
        if let storedSummary {
            let hasErrorRoot = storedSummary.hasErrorRoot || (fallbackSummary?.hasErrorRoot ?? false)
            let hasAttention = hasErrorRoot || (fallbackSummary?.hasAttention ?? false)
            let latestActivity = [storedSummary.latestActivity, fallbackSummary?.latestActivity]
                .compactMap { $0 }
                .max()
            nextSummary = WorkspaceListSummary(
                workspaceId: workspaceId,
                activeCount: storedSummary.activeCount,
                stoppedCount: storedSummary.stoppedCount,
                hasAttention: hasAttention,
                hasErrorRoot: hasErrorRoot,
                latestActivity: latestActivity
            )
        } else if let fallbackSummary {
            nextSummary = fallbackSummary
        } else {
            return
        }

        if summaries[workspaceId] != nextSummary {
            summaries[workspaceId] = nextSummary
            workspaceStore.workspaceSummaries = summaries
        }
    }

    func syncAllWorkspaceSummariesFromLocalState() {
        var workspaceIds = Set(workspaceStore.workspaceSummaries.keys)
        workspaceIds.formUnion(workspaceStore.storedWorkspaceSummaries.keys)

        for session in sessionStore.listProjectionSessions {
            if let workspaceId = session.workspaceId, !workspaceId.isEmpty {
                workspaceIds.insert(workspaceId)
            }
        }
        for ask in askRequestStore.pending.values {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: ask.workspaceId,
                sessionId: ask.sessionId
            ) {
                workspaceIds.insert(workspaceId)
            }
        }
        for request in pendingExtensionDialogRequests {
            if let workspaceId = attentionWorkspaceId(explicitWorkspaceId: nil, sessionId: request.sessionId) {
                workspaceIds.insert(workspaceId)
            }
        }

        for workspaceId in workspaceIds where !workspaceId.isEmpty {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

    private func fallbackWorkspaceSummary(workspaceId: String) -> WorkspaceListSummary? {
        let workspaceSessions = sessionStore.listProjectionSessions(workspaceId: workspaceId)
        let workspaceSessionIds = Set(workspaceSessions.map(\.id))
        let hasPendingAsk = askRequestStore.pending.values.contains { ask in
            ask.workspaceId == workspaceId
                || (ask.workspaceId == nil && workspaceSessionIds.contains(ask.sessionId))
        }
        let hasPendingExtensionDialog = pendingExtensionDialogRequests.contains { request in
            workspaceSessionIds.contains(request.sessionId)
        }
        let hasListAttention = workspaceSessions.contains { session in
            sessionStore.listPendingAskCount(for: session.id) > 0
        }
        let hasLiveErrorRoot = workspaceSessions.contains { $0.status == .error }

        guard !workspaceSessions.isEmpty
            || hasPendingAsk
            || hasPendingExtensionDialog
            || hasListAttention else {
            return nil
        }

        let latestActivity = workspaceSessions.map(\.lastActivity).max()
        return WorkspaceListSummary(
            workspaceId: workspaceId,
            activeCount: workspaceSessions.filter { $0.status != .stopped }.count,
            stoppedCount: workspaceSessions.filter { $0.status == .stopped }.count,
            hasAttention: hasLiveErrorRoot
                || hasPendingAsk
                || hasPendingExtensionDialog
                || hasListAttention,
            hasErrorRoot: hasLiveErrorRoot,
            latestActivity: latestActivity
        )
    }

    /// Apply an authoritative workspace-scoped attention snapshot fetched over HTTP.
    ///
    /// The snapshot is destructive only inside the target workspace: pending
    /// asks missing from a successful response are stale and should be removed
    /// from list badges.
    func applyWorkspaceAttentionSnapshot(_ response: APIClient.WorkspaceAttentionResponse) {
        let workspaceId = response.workspaceId
        let workspaceSessionIds = Set(
            sessionStore.sessions
                .filter { $0.workspaceId == workspaceId }
                .map(\.id)
        )

        let changedAskSessionIds = askRequestStore.applyWorkspaceSnapshot(
            workspaceId: workspaceId,
            asks: response.attention.asks,
            workspaceSessionIds: workspaceSessionIds
        )
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            for sessionId in changedAskSessionIds {
                AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
                if let nextAsk = askRequestStore.pending(for: sessionId) {
                    AttentionNotificationService.shared.notifyAskIfNeeded(
                        nextAsk,
                        activeSessionId: focusedSessionId
                    )
                }
            }
        }

        syncWorkspaceSummary(workspaceId: workspaceId)
        syncLiveActivityState()
    }

    /// Apply a session snapshot fetched outside the live WS stream.
    ///
    /// Reuses the normal `.state` transition path so REST refreshes and stop
    /// reconciliation get the same terminal side effects as streamed state.
    func applyFetchedSessionState(_ session: Session) {
        let message = ServerMessage.state(session: session)
        let result = applySharedStoreUpdate(for: message, sessionId: session.id)

        if isFocusedSession(session.id) {
            handleActiveSessionUI(message, sessionId: session.id, storeResult: result)
        } else {
            handleInactiveSessionUI(message, sessionId: session.id)
        }
    }

    /// Record Live Activity events for cross-session messages.
    ///
    /// Cross-session events bypass the coalescer, so they must record
    /// Live Activity events directly. Active-session events go through
    /// `coalescer.onFlush → handleLiveActivityFlush` instead.
    func recordCrossSessionLiveActivityEvent(
        _ message: ServerMessage,
        sessionId: String
    ) {
        guard ReleaseFeatures.liveActivitiesEnabled else { return }

        let event: AgentEvent?
        switch message {
        case .agentStart:
            event = .agentStart(sessionId: sessionId)
        case .agentEnd:
            event = .agentEnd(sessionId: sessionId)
        case .stopConfirmed:
            event = .agentEnd(sessionId: sessionId)
        case .stopFailed:
            event = .agentStart(sessionId: sessionId)
        case .sessionEnded(let reason):
            event = .sessionEnded(sessionId: sessionId, reason: reason)
        default:
            event = nil
        }

        if let event {
            LiveActivityManager.shared.recordEvent(
                connectionId: liveActivityConnectionId,
                event: event
            )
        }
    }
}
