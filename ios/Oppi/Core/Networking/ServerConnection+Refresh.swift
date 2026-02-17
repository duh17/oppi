import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

// MARK: - Session & Workspace Refresh + Foreground Reconnect

extension ServerConnection {

    static func elapsedMs(since startedAt: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(startedAt) * 1_000.0).rounded()))
    }

    static func compactError(_ error: any Error, maxLength: Int = 200) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "unknown" }
        if message.count <= maxLength {
            return message
        }
        return String(message.prefix(maxLength)) + "…"
    }

    static func workspaceCount(from sessions: [Session]) -> Int {
        let workspaceIDs = Set(sessions.compactMap(\.workspaceId).filter { !$0.isEmpty })
        return workspaceIDs.count
    }

    func recordRefreshBreadcrumb(
        _ message: String,
        level: ClientLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        _onRefreshBreadcrumbForTesting?(message, metadata, level)

        Task.detached(priority: .utility) {
#if DEBUG
            await ClientLogBuffer.shared.record(
                level: level,
                category: "Refresh",
                message: message,
                metadata: metadata
            )
#endif
            await SentryService.shared.recordBreadcrumb(
                level: level,
                category: "Refresh",
                message: message,
                metadata: metadata
            )
        }
    }

    func shouldRefreshSessionList(now: Date = Date(), force: Bool) -> Bool {
        if force { return true }
        if sessionStore.sessions.isEmpty { return true }
        if sessionStore.lastSyncFailed { return true }
        guard let sessionSyncAt = sessionStore.lastSuccessfulSyncAt else { return true }
        return now.timeIntervalSince(sessionSyncAt) >= Self.listRefreshMinimumInterval
    }

    func shouldRefreshWorkspaceCatalog(now: Date = Date(), force: Bool) -> Bool {
        if force { return true }
        if !workspaceStore.isLoaded { return true }
        if workspaceStore.lastSyncFailed { return true }
        guard let workspaceSyncAt = workspaceStore.lastSuccessfulSyncAt else { return true }
        return now.timeIntervalSince(workspaceSyncAt) >= Self.listRefreshMinimumInterval
    }

    /// Refresh global session list (`/workspaces` + workspace session fan-out).
    /// Uses single-flight coalescing so overlapping callers share one request.
    func refreshSessionList(force: Bool = false) async {
        guard let apiClient else { return }

        let callStartedAt = Date()
        let callMetadata: [String: String] = [
            "force": force ? "1" : "0",
            "cachedSessionCount": String(sessionStore.sessions.count),
            "cachedWorkspaceCount": String(workspaceStore.workspaces.count),
        ]

        if let inFlight = sessionListRefreshTask {
            recordRefreshBreadcrumb(
                "session_list.coalesced",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            await inFlight.value
            return
        }

        guard shouldRefreshSessionList(force: force) else {
            logger.debug("Skipping session list refresh (recent successful sync)")
            recordRefreshBreadcrumb(
                "session_list.skip",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            return
        }

        recordRefreshBreadcrumb("session_list.start", metadata: callMetadata)

        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            let requestStartedAt = Date()
            defer { self.sessionListRefreshTask = nil }

            if self.sessionStore.sessions.isEmpty,
               let cached = await TimelineCache.shared.loadSessionList() {
                self.sessionStore.applyServerSnapshot(cached)
            }

            self.sessionStore.markSyncStarted()
            do {
                let sessions = try await apiClient.listSessions()
                self.sessionStore.applyServerSnapshot(sessions)
                self.sessionStore.markSyncSucceeded()
                Task.detached { await TimelineCache.shared.saveSessionList(sessions) }

                self.recordRefreshBreadcrumb(
                    "session_list.end",
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "success",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "sessionCount": String(sessions.count),
                        "workspaceCount": String(Self.workspaceCount(from: sessions)),
                    ]
                )
            } catch {
                self.sessionStore.markSyncFailed()
                logger.error("Failed to refresh sessions: \(error)")

                self.recordRefreshBreadcrumb(
                    "session_list.end",
                    level: .warning,
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "failure",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "sessionCount": String(self.sessionStore.sessions.count),
                        "workspaceCount": String(self.workspaceStore.workspaces.count),
                        "error": Self.compactError(error),
                    ]
                )
            }
        }

        sessionListRefreshTask = task
        await task.value
    }

    /// Refresh workspaces + skills catalog with single-flight coalescing.
    func refreshWorkspaceCatalog(force: Bool = false) async {
        guard let apiClient else { return }

        let callStartedAt = Date()
        let callMetadata: [String: String] = [
            "force": force ? "1" : "0",
            "cachedWorkspaceCount": String(workspaceStore.workspaces.count),
            "cachedSessionCount": String(sessionStore.sessions.count),
            "isLoaded": workspaceStore.isLoaded ? "1" : "0",
        ]

        if let inFlight = workspaceCatalogRefreshTask {
            recordRefreshBreadcrumb(
                "workspace_catalog.coalesced",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            await inFlight.value
            return
        }

        guard shouldRefreshWorkspaceCatalog(force: force) else {
            logger.debug("Skipping workspace catalog refresh (recent successful sync)")
            recordRefreshBreadcrumb(
                "workspace_catalog.skip",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            return
        }

        recordRefreshBreadcrumb("workspace_catalog.start", metadata: callMetadata)

        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            let requestStartedAt = Date()
            defer { self.workspaceCatalogRefreshTask = nil }

            await self.workspaceStore.load(api: apiClient)

            let level: ClientLogLevel = self.workspaceStore.lastSyncFailed ? .warning : .info
            let result = self.workspaceStore.lastSyncFailed ? "failure" : "success"
            self.recordRefreshBreadcrumb(
                "workspace_catalog.end",
                level: level,
                metadata: [
                    "force": force ? "1" : "0",
                    "result": result,
                    "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                    "workspaceCount": String(self.workspaceStore.workspaces.count),
                    "sessionCount": String(self.sessionStore.sessions.count),
                    "skillCount": String(self.workspaceStore.skills.count),
                ]
            )
        }

        workspaceCatalogRefreshTask = task
        await task.value
    }

    /// Refresh both global lists. Each branch has its own single-flight task,
    /// so overlapping callers don't trigger duplicate network fan-out.
    func refreshWorkspaceAndSessionLists(force: Bool = false) async {
        await refreshSessionList(force: force)
        await refreshWorkspaceCatalog(force: force)
    }

    /// Called when app returns to foreground.
    ///
    /// Refreshes session list, workspaces, and session metadata.
    /// Does NOT touch the timeline — `ChatSessionManager` owns trace loading,
    /// catch-up, and reconnect. Mixing both paths causes double-load races
    /// and visual flashes.
    func reconnectIfNeeded() async {
        guard let apiClient else { return }
        guard !foregroundRecoveryInFlight else { return }
        foregroundRecoveryInFlight = true
        defer { foregroundRecoveryInFlight = false }

        // 1. Refresh global lists as needed (single-flight + freshness-gated).
        await refreshWorkspaceAndSessionLists(force: false)

        // 2. Sweep expired permissions (safety net for missed WS messages)
        let expiredRequests = permissionStore.sweepExpired()
        for request in expiredRequests {
            reducer.resolvePermission(
                id: request.id, outcome: .expired,
                tool: request.tool, summary: request.displaySummary
            )
            PermissionNotificationService.shared.cancelNotification(permissionId: request.id)
        }
        if !expiredRequests.isEmpty {
            syncLiveActivityPermissions()
        }

        // 3. Refresh active session metadata (not timeline — ChatSessionManager owns that)
        guard let sessionId = activeSessionId else { return }
        guard let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId,
              !workspaceId.isEmpty else {
            logger.error("Missing workspaceId for active session \(sessionId)")
            return
        }

        let streamAttached = wsClient?.connectedSessionId == sessionId
        let streamAlive: Bool
        if streamAttached {
            switch wsClient?.status {
            case .connected, .connecting, .reconnecting:
                streamAlive = true
            default:
                streamAlive = false
            }
        } else {
            streamAlive = false
        }

        if !streamAlive {
            activeExtensionDialog = nil
            extensionTimeoutTask?.cancel()
            extensionTimeoutTask = nil

            do {
                let (session, _) = try await apiClient.getSession(workspaceId: workspaceId, id: sessionId)
                sessionStore.upsert(session)
            } catch {
                logger.error("Failed to refresh session \(sessionId): \(error)")
            }
        } else {
            do {
                let (session, _) = try await apiClient.getSession(workspaceId: workspaceId, id: sessionId)
                sessionStore.upsert(session)
            } catch {
                logger.error("Failed to refresh session metadata: \(error)")
            }
        }

        // 4. Ask server for freshest state once the active stream is connected.
        if streamAttached, wsClient?.status == .connected {
            try? await requestState()
        }
    }
}
