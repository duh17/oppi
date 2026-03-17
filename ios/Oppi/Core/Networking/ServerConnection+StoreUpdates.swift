import Foundation

// MARK: - Shared Store Updates

extension ServerConnection {

    /// Context returned by `applySharedStoreUpdate` for callers that need
    /// details about permission removals (e.g. to resolve timeline items).
    struct StoreUpdateResult {
        /// Permission request removed from the store (expired/cancelled).
        var takenPermission: PermissionRequest?
        /// Whether this message type was handled by the shared helper.
        var handled: Bool

        static let notHandled = StoreUpdateResult(handled: false)
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
                    activeSessionId: sessionStore.activeSessionId
                )
            }
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .permissionExpired(let id, _):
            let request = permissionStore.take(id: id)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()
            return StoreUpdateResult(takenPermission: request, handled: true)

        case .permissionCancelled(let id):
            let request = permissionStore.take(id: id)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()
            return StoreUpdateResult(takenPermission: request, handled: true)

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
               current.status == .busy || current.status == .stopping {
                current.status = .ready
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            sessionStore.recordTurnEnded(sessionId: sessionId)
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
            sessionStore.upsert(session)
            emitSessionUsageMetricsIfNeeded(session)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .sessionEnded:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        case .sessionDeleted(let deletedId):
            sessionStore.remove(id: deletedId)
            notificationSessionIds.remove(deletedId)
            sessionUsageMetricSnapshots.removeValue(forKey: deletedId)
            screenAwakeController.clearSessionActivity(sessionId: deletedId)
            syncLiveActivityPermissions()
            return StoreUpdateResult(handled: true)

        default:
            return .notHandled
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
