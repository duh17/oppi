import Foundation

// MARK: - Shared Store Updates

extension ServerConnection {

    /// Context returned by `applySharedStoreUpdate` for callers that need
    /// details about pre-update session state or permission removals.
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

        /// Permission request removed from the store (expired/cancelled).
        var takenPermission: PermissionRequest?
        /// Pre-update context for `.state(session:)` messages.
        var stateContext: SessionStateContext?
        /// Whether this message type was handled by the shared helper.
        var handled: Bool

        init(
            takenPermission: PermissionRequest? = nil,
            stateContext: SessionStateContext? = nil,
            handled: Bool
        ) {
            self.takenPermission = takenPermission
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
    /// Handles permission store, session store, screen-awake, and Live Activity sync
    /// updates that are common to both message routing paths.
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

        // MARK: Permission events

        case .permissionRequest(let perm):
            permissionStore.add(perm)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.notifyIfNeeded(
                    perm,
                    activeSessionId: focusedSessionId
                )
            }
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .permissionExpired(let id, _), .permissionCancelled(let id):
            let request = permissionStore.take(id: id)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()
            return StoreUpdateResult(takenPermission: request, handled: true)

        // MARK: Tool activity tracking

        case .toolStart(let tool, let args, _, _),
             .toolUpdate(let tool, let args, _, _):
            activityStore.recordToolStart(sessionId: sessionId, tool: tool, args: args)
            return .notHandled  // let active-session path also process (watchdog, coalescer)

        // MARK: Agent lifecycle

        case .agentStart:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }),
               current.status != .stopping {
                current.status = .busy
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .agentEnd:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }),
               current.status.isRunning {
                current.status = .ready
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            sessionStore.recordTurnEnded(sessionId: sessionId)
            activityStore.clear(sessionId: sessionId)
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        // MARK: Stop lifecycle

        case .stopRequested:
            updateStopStatus(sessionId, status: .stopping)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .stopConfirmed:
            updateStopStatus(sessionId, status: .ready, onlyFrom: .stopping)
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .stopFailed:
            updateStopStatus(sessionId, status: .busy, onlyFrom: .stopping)
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        // MARK: Session state

        case .state(let session):
            let previousSession = sessionStore.sessions.first(where: { $0.id == session.id })
            let stateContext = StoreUpdateResult.SessionStateContext(
                previousSession: previousSession,
                currentSession: session
            )

            sessionStore.upsert(session)
            emitSessionUsageMetricsIfNeeded(session)

            if stateContext.didTransitionOutOfRunning {
                sessionStore.recordTurnEnded(sessionId: session.id)
                activityStore.clear(sessionId: session.id)
                screenAwakeController.setSessionActivity(false, sessionId: session.id)
            }

            syncLiveActivityPermissions()
            return StoreUpdateResult(stateContext: stateContext, handled: true)

        case .sessionEnded:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            activityStore.clear(sessionId: sessionId)
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .sessionDeleted(let deletedId):
            sessionStore.remove(id: deletedId)
            subscriptionRegistry.remove(sessionId: deletedId)
            sessionUsageMetricSnapshots.removeValue(forKey: deletedId)
            activityStore.clear(sessionId: deletedId)
            screenAwakeController.clearSessionActivity(sessionId: deletedId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        default:
            return .notHandled
        }
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
