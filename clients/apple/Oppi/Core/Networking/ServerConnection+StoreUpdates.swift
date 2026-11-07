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

        init(stateContext: SessionStateContext? = nil) {
            self.stateContext = stateContext
        }

        var previousWorkspaceId: String? { stateContext?.previousWorkspaceId }
        var didTransitionOutOfRunning: Bool { stateContext?.didTransitionOutOfRunning ?? false }

        static let notHandled = Self()
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

        // MARK: Agent lifecycle

        case .agentStart, .agentEnd, .agentSettled:
            // The server's busy/ready status and its side effects (screen awake,
            // workspace summary, push discovery, Live Activity) arrive on the
            // state/session_summary that follows; these events carry none.
            return StoreUpdateResult()

        // MARK: Stop lifecycle

        case .stopRequested, .stopConfirmed, .stopFailed:
            // The server's state frame carries the authoritative stopping/ready/busy
            // status and side effects; these events carry none.
            return StoreUpdateResult()

        // MARK: Session state

        case .state(let session):
            return applySessionProjection(session)

        case .sessionSummary(let summary):
            return applySessionSummary(summary)

        case .sessionEnded:
            let workspaceId = sessionStore.applySessionEnded(id: sessionId)?.workspaceId
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            syncScreenAwake()
            syncLiveActivityState()
            return StoreUpdateResult()

        case .sessionDeleted(let deletedId):
            let workspaceId = sessionStore.session(id: deletedId)?.workspaceId
            sessionStore.remove(id: deletedId)
            if let currentServerId {
                scopedLocks.forgetSession(serverId: currentServerId, sessionId: deletedId)
            }
            if let workspaceId {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            sessionUsageMetrics.forget(sessionId: deletedId)
            syncScreenAwake()
            syncLiveActivityState()
            return StoreUpdateResult()

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
        sessionUsageMetrics.reportIfNeeded(currentSession)

        if let previousWorkspaceId = previousSession?.workspaceId,
           previousWorkspaceId != currentSession.workspaceId {
            syncWorkspaceSummary(workspaceId: previousWorkspaceId)
        }
        if let currentWorkspaceId = currentSession.workspaceId {
            syncWorkspaceSummary(workspaceId: currentWorkspaceId)
        }

        if stateContext.didTransitionOutOfRunning {
            notePushDiscoveryMoment()
        }

        syncScreenAwake()
        syncLiveActivityState()
        return StoreUpdateResult(stateContext: stateContext)
    }

    /// Screen-awake follows this connection's stored rows, recomputed whole after each live
    /// store apply: a summary missed while a socket was down, or a row a resync dropped, is
    /// corrected by the next apply instead of holding its reason. Cached list loads do not
    /// call this, so a stale busy row cannot hold the screen while the server is unreachable.
    func syncScreenAwake() {
        screenAwakeController.reconcileSessionActivity(
            sessionIds: Set(sessionStore.sessions.lazy.filter(\.holdsScreenAwake).map(\.id)),
            owner: ObjectIdentifier(self)
        )
    }

    func attentionWorkspaceId(explicitWorkspaceId: String?, sessionId: String?) -> String? {
        if let explicitWorkspaceId = explicitWorkspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitWorkspaceId.isEmpty {
            return explicitWorkspaceId
        }
        guard let sessionId else { return nil }
        return sessionReentryWorkspaceId(for: sessionId)
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
                latestActivity: latestActivity,
                gitSummary: storedSummary.gitSummary
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
        for request in extensionDialogs.requests {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: request.workspaceId,
                sessionId: request.sessionId
            ) {
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
        let hasPendingExtensionDialog = extensionDialogs.requests.contains { request in
            request.workspaceId == workspaceId
                || (request.workspaceId == nil && workspaceSessionIds.contains(request.sessionId))
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
        for sessionId in changedAskSessionIds {
            AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
            if let nextAsk = askRequestStore.pending(for: sessionId) {
                AttentionNotificationService.shared.notifyAskIfNeeded(
                    nextAsk,
                    serverId: currentServerId,
                    activeSessionId: focusedSessionId,
                    hidesQuestionText: askTextIsLocked(nextAsk)
                )
            }
        }

        syncWorkspaceSummary(workspaceId: workspaceId)
        syncLiveActivityState()
    }

    /// The first time a session on this server finishes or needs input, make the push
    /// discovery card due (`PushDiscovery`). Later calls change nothing.
    func notePushDiscoveryMoment() {
        guard let currentServerId else { return }
        PushDiscovery.noteAttention(
            serverId: currentServerId,
            pushEnabled: PushRegistration.isEnabled(serverId: currentServerId)
        )
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
}
