import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

// MARK: - Session & Workspace Refresh + Foreground Reconnect

extension ServerConnection {

    private static let globalSessionRefreshRecentDays = 3

    static func elapsedMs(since startedAt: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(startedAt) * 1_000.0).rounded()))
    }

    static func refreshErrorMetadata(_ error: Error) -> [String: String] {
        var metadata = [
            "errorKind": MessageSender.telemetryErrorKind(from: error),
        ]
        if error is URLError {
            metadata.merge(ClientLog.networkErrorMetadata(error)) { current, _ in current }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .server(let status, _), .codedServer(let status, _, _):
                metadata["errorKind"] = "http"
                metadata["statusCode"] = String(status)
            case .invalidResponse:
                metadata["errorKind"] = "invalid_response"
            }
        }
        return metadata
    }

    private static let refreshTelemetryKeys: Set<String> = [
        "force",
        "cachedSessionCount",
        "cachedWorkspaceCount",
        "isLoaded",
        "durationMs",
        "result",
        "sessionCount",
        "workspaceCount",
        "skillCount",
        "source",
        "errorKind",
        "errorDomain",
        "errorCode",
        "urlErrorCode",
        "statusCode",
    ]

    private static func boundedRefreshMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, entry in
            guard refreshTelemetryKeys.contains(entry.key) else { return }
            result[entry.key] = entry.value
        }
    }

    func recordRefreshEvent(
        _ message: String,
        level: ClientLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        let safeMetadata = Self.boundedRefreshMetadata(metadata)
        // Lifecycle tracing stays local; only outcome ends should upload.
        let uploadLevel: ClientLogLevel = message.hasSuffix(".end") ? level : .debug
        ClientLog.record(
            uploadLevel,
            category: "Network",
            message: message,
            metadata: safeMetadata
        )
        _onRefreshEventForTesting?(message, safeMetadata, level)
    }

    private struct ListRefreshOwnership {
        let apiClient: APIClient
        let generation: UInt64
    }

    private func ownsListRefresh(_ ownership: ListRefreshOwnership) -> Bool {
        apiClient === ownership.apiClient
            && listRefreshGeneration == ownership.generation
    }

    private func noteExternalListFailureForAppEventRepair(origin: ServerListRefreshOrigin) {
        guard origin == .external else { return }
        guard appEventStreamTransportState == .connected else { return }

        // An active owner consumes at most one late external failure after the
        // current pass. Repair-originated failures never enter this path.
        if appEventListRepairTask != nil {
            appEventListPendingExternalFailure = true
            return
        }

        guard !appEventListRepairFollowUpUsed else { return }
        appEventListRepairFollowUpUsed = true
        let connectedAt = appEventStreamConnectedAt
        Task { @MainActor [weak self] in
            // Let the failed list task unwind its defer before the owner starts.
            await Task.yield()
            guard let self,
                  self.appEventStreamTransportState == .connected,
                  self.appEventStreamConnectedAt == connectedAt else {
                return
            }
            _ = await self.reconcileListSnapshotsAfterAppEventConnection(snapshotRequired: true)
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

    /// Refresh the recent workspace-scoped session projection used by cold UI.
    /// Uses single-flight coalescing so overlapping callers share one request.
    ///
    /// `retryAfterJoinedFailure` is only for route recovery: after joining a
    /// pre-recovery pass that left `lastSyncFailed`, run exactly one fresh pass
    /// on the post-recovery client. Ordinary callers join once and return.
    func refreshSessionList(
        force: Bool = false,
        retryAfterJoinedFailure: Bool = false,
        origin: ServerListRefreshOrigin = .external
    ) async {
        // Cold list/home paths also need capability discovery so the global
        // app-event stream starts before users focus a chat session.
        await refreshStreamCapabilitiesIfNeeded()
        guard !Task.isCancelled else { return }

        let callStartedAt = Date()
        let callMetadata: [String: String] = [
            "force": force ? "1" : "0",
            "cachedSessionCount": String(sessionStore.sessions.count),
            "cachedWorkspaceCount": String(workspaceStore.workspaces.count),
        ]

        if let inFlight = sessionListRefreshTask {
            recordRefreshEvent(
                "session_list.coalesced",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            await inFlight.value
            guard !Task.isCancelled else { return }
            guard retryAfterJoinedFailure, sessionStore.lastSyncFailed else { return }
            // A peer may have installed a replacement while we were suspended.
            // Join it; do not overwrite (its defer would clear our follow-up).
            if let replacement = sessionListRefreshTask {
                await replacement.value
                return
            }
        }

        guard !Task.isCancelled, let apiClient else { return }
        guard shouldRefreshSessionList(force: force) else {
            logger.debug("Skipping session list refresh (recent successful sync)")
            recordRefreshEvent(
                "session_list.skip",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            return
        }

        recordRefreshEvent("session_list.start", metadata: callMetadata)
        let ownership = ListRefreshOwnership(
            apiClient: apiClient,
            generation: listRefreshGeneration
        )

        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            let requestStartedAt = Date()
            let cache = self._cacheForTesting ?? TimelineCache.shared
            var syncToken: SessionStoreSyncToken?
            defer {
                if let syncToken {
                    self.sessionStore.finishSyncIfOwned(syncToken)
                }
                self.sessionListRefreshTask = nil
            }

            // Ownership is the commit fence. Cancellation is cooperative after
            // installAPIClient cancels the in-flight list task.
            guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
            if self.sessionStore.sessions.isEmpty,
               let serverId = self.currentServerId,
               let cached = await cache.loadSessionList(serverId: serverId) {
                guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
                self.sessionStore.applyServerSnapshot(cached)
                self.syncAllWorkspaceSummariesFromLocalState()
                self.syncLiveActivityState()
            }

            guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
            syncToken = self.sessionStore.beginSync()
            do {
                // An authoritative empty catalog is still loaded. Retry only when
                // no catalog has ever succeeded, and stay on the shared single-flight path.
                if !self.workspaceStore.isLoaded {
                    await self.refreshWorkspaceCatalog(force: true, origin: origin)
                    guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
                }

                let workspaces = self.workspaceStore.workspaces
                let sessionSummaries = try await apiClient.listRecentWorkspaceSessionSummaries(
                    recentDays: Self.globalSessionRefreshRecentDays
                )
                guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
                self.sessionStore.applyRecentWorkspaceSummaryProjection(
                    workspaceIds: Set(workspaces.map(\.id)),
                    summaries: sessionSummaries,
                    requestStartedAt: requestStartedAt
                )
                self.syncAllWorkspaceSummariesFromLocalState()
                guard let syncToken,
                      self.sessionStore.markSyncSucceeded(ifOwned: syncToken) else { return }
                self.syncLiveActivityState()
                let cachedSessions = self.sessionStore.listProjectionSessions
                if let serverId = self.currentServerId {
                    await cache.saveSessionList(cachedSessions, serverId: serverId)
                }

                self.recordRefreshEvent(
                    "session_list.end",
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "success",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "sessionCount": String(sessionSummaries.count),
                        "workspaceCount": String(workspaces.count),
                        "source": "sessions_recent",
                    ]
                )
            } catch {
                guard !Task.isCancelled,
                      self.ownsListRefresh(ownership),
                      let syncToken,
                      self.sessionStore.markSyncFailed(ifOwned: syncToken) else { return }
                let errorMetadata = Self.refreshErrorMetadata(error)
                let errorKind = errorMetadata["errorKind"] ?? "other"
                logger.error("Failed to refresh sessions (\(errorKind, privacy: .public))")

                self.recordRefreshEvent(
                    "session_list.end",
                    level: .warning,
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "failure",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "sessionCount": String(self.sessionStore.sessions.count),
                        "workspaceCount": String(self.workspaceStore.workspaces.count),
                    ].merging(errorMetadata) { current, _ in current }
                )
                self.noteExternalListFailureForAppEventRepair(origin: origin)
            }
        }

        sessionListRefreshTask = task
        await task.value
    }

    /// Refresh workspaces + skills catalog with single-flight coalescing.
    /// See `refreshSessionList` for `retryAfterJoinedFailure`.
    func refreshWorkspaceCatalog(
        force: Bool = false,
        retryAfterJoinedFailure: Bool = false,
        origin: ServerListRefreshOrigin = .external
    ) async {
        guard !Task.isCancelled else { return }

        let callStartedAt = Date()
        let callMetadata: [String: String] = [
            "force": force ? "1" : "0",
            "cachedWorkspaceCount": String(workspaceStore.workspaces.count),
            "cachedSessionCount": String(sessionStore.sessions.count),
            "isLoaded": workspaceStore.isLoaded ? "1" : "0",
        ]

        if let inFlight = workspaceCatalogRefreshTask {
            recordRefreshEvent(
                "workspace_catalog.coalesced",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            await inFlight.value
            guard !Task.isCancelled else { return }
            guard retryAfterJoinedFailure, workspaceStore.lastSyncFailed else { return }
            if let replacement = workspaceCatalogRefreshTask {
                await replacement.value
                return
            }
        }

        guard !Task.isCancelled, let apiClient else { return }
        guard shouldRefreshWorkspaceCatalog(force: force) else {
            logger.debug("Skipping workspace catalog refresh (recent successful sync)")
            recordRefreshEvent(
                "workspace_catalog.skip",
                metadata: callMetadata.merging([
                    "durationMs": String(Self.elapsedMs(since: callStartedAt)),
                ]) { _, new in new }
            )
            return
        }

        recordRefreshEvent("workspace_catalog.start", metadata: callMetadata)
        let ownership = ListRefreshOwnership(
            apiClient: apiClient,
            generation: listRefreshGeneration
        )

        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            let requestStartedAt = Date()
            defer { self.workspaceCatalogRefreshTask = nil }

            guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }
            let outcome = await self.workspaceStore.load(api: apiClient) {
                !Task.isCancelled && self.ownsListRefresh(ownership)
            }
            guard !Task.isCancelled, self.ownsListRefresh(ownership) else { return }

            switch outcome {
            case .superseded:
                return

            case .success:
                self.recordRefreshEvent(
                    "workspace_catalog.end",
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "success",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "workspaceCount": String(self.workspaceStore.workspaces.count),
                        "sessionCount": String(self.sessionStore.sessions.count),
                        "skillCount": String(self.workspaceStore.skills.count),
                    ]
                )

            case .failure(let failure):
                self.recordRefreshEvent(
                    "workspace_catalog.end",
                    level: .warning,
                    metadata: [
                        "force": force ? "1" : "0",
                        "result": "failure",
                        "durationMs": String(Self.elapsedMs(since: requestStartedAt)),
                        "workspaceCount": String(self.workspaceStore.workspaces.count),
                        "sessionCount": String(self.sessionStore.sessions.count),
                        "skillCount": String(self.workspaceStore.skills.count),
                    ].merging(failure.telemetryMetadata) { current, _ in current }
                )
                self.noteExternalListFailureForAppEventRepair(origin: origin)
            }
        }

        workspaceCatalogRefreshTask = task
        await task.value
    }

    /// Refresh both global lists. Each branch has its own single-flight task,
    /// so overlapping callers don't trigger duplicate network fan-out.
    func refreshWorkspaceAndSessionLists(
        force: Bool = false,
        retryAfterJoinedFailure: Bool = false,
        origin: ServerListRefreshOrigin = .external
    ) async {
        await refreshWorkspaceCatalog(
            force: force,
            retryAfterJoinedFailure: retryAfterJoinedFailure,
            origin: origin
        )
        guard !Task.isCancelled else { return }
        await refreshSessionList(
            force: force,
            retryAfterJoinedFailure: retryAfterJoinedFailure,
            origin: origin
        )
    }

    /// Reconcile the REST projections after an app-event handshake.
    ///
    /// A healthy WebSocket is not a REST snapshot. Repair when the server asks
    /// for a snapshot or either list projection still reports a failure.
    /// Returns whether both list projections are healthy after repair when a
    /// snapshot was required; otherwise whether the stream may stay up.
    @discardableResult
    func reconcileListSnapshotsAfterAppEventConnection(snapshotRequired: Bool) async -> Bool {
        guard snapshotRequired
                || workspaceStore.lastSyncFailed
                || sessionStore.lastSyncFailed
                || appEventListPendingExternalFailure else {
            return true
        }

        if let inFlight = appEventListRepairTask {
            let joinedConnectedAt = appEventStreamConnectedAt
            await inFlight.value
            guard !Task.isCancelled,
                  appEventStreamTransportState == .connected,
                  appEventStreamConnectedAt == joinedConnectedAt else {
                return false
            }
            if snapshotRequired {
                return !workspaceStore.lastSyncFailed && !sessionStore.lastSyncFailed
            }
            return true
        }

        let connectedAt = appEventStreamConnectedAt
        // Install the owner slot before the first await so a late external
        // failure during this pass can set the pending follow-up marker.
        appEventListRepairGeneration &+= 1
        let repairEpoch = appEventListRepairGeneration
        appEventListRepairTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Owner cleanup and pending consumption happen in one MainActor
            // transition. No await may sit between the final level check and
            // clearing the owner slot. Epoch guards a cancelled owner from
            // clearing a newer repair installed after stream teardown.
            defer {
                if self.appEventListRepairGeneration == repairEpoch {
                    self.appEventListPendingExternalFailure = false
                    self.appEventListRepairTask = nil
                }
            }

            await self.refreshWorkspaceAndSessionLists(
                force: true,
                retryAfterJoinedFailure: true,
                origin: .appEventReconciliation
            )
            guard !Task.isCancelled,
                  self.appEventStreamTransportState == .connected,
                  self.appEventStreamConnectedAt == connectedAt else {
                return
            }

            if self.appEventListPendingExternalFailure,
               !self.appEventListRepairFollowUpUsed {
                // Consume the one-follow-up budget before awaiting. Failures
                // from this pass are repair-owned and cannot reschedule.
                self.appEventListPendingExternalFailure = false
                self.appEventListRepairFollowUpUsed = true
                await self.refreshWorkspaceAndSessionLists(
                    force: true,
                    retryAfterJoinedFailure: true,
                    origin: .appEventReconciliation
                )
            }
        }
        await appEventListRepairTask?.value

        guard !Task.isCancelled,
              appEventStreamTransportState == .connected,
              appEventStreamConnectedAt == connectedAt else {
            return false
        }
        if snapshotRequired {
            return !workspaceStore.lastSyncFailed && !sessionStore.lastSyncFailed
        }
        return true
    }

    /// Called when app returns to foreground.
    ///
    /// Refreshes session list, workspaces, and session metadata.
    /// Does NOT touch the timeline — `ChatSessionManager` owns trace loading,
    /// catch-up, and reconnect. Mixing both paths causes double-load races
    /// and visual flashes.
    func reconnectIfNeeded() async {
        guard !foregroundRecoveryInFlight else { return }
        foregroundRecoveryInFlight = true
        defer { foregroundRecoveryInFlight = false }

        // Iroh's local URLSession tasks and cached QUIC connection can survive suspension
        // long enough to look healthy after the server has timed them out. Reset only the
        // transport tasks; focused-session continuations stay attached for catch-up.
        let foregroundIrohRecovery = await resetIrohTransportForForegroundRecoveryIfNeeded()
        switch foregroundIrohRecovery {
        case .availabilityFailure:
            await reevaluateIrohPreferredTransportAtBoundary(excluding: [.iroh])
        case .terminalFailure:
            return
        case .notActive, .retained:
            break
        }
        if apiClient == nil {
            await reevaluateIrohPreferredTransportAtBoundary()
        }
        guard let apiClient else { return }

        // 0. If a chat session owns a prepared bound stream, keep that focused transport alive.
        // Home/workspace-list refreshes and pre-stream session focus stay HTTP-only.
        if focusedSessionId != nil, focusedSessionStreamEndpointKind == "split_session" {
            if case .reconnecting = wsClient?.status {
                wsClient?.cancelReconnectBackoff()
                streamConsumptionTask?.cancel()
                streamConsumptionTask = nil
            }
            if wsClient?.status == .disconnected || streamConsumptionTask == nil {
                connectStream()
            }
        }

        // 1. Make capability discovery part of foreground recovery so a cold
        // workspace/session list can start the global app-event stream without
        // first opening a focused chat stream.
        await refreshStreamCapabilitiesIfNeeded()

        // 2. Reopen the global app event stream when foreground recovery finds it stopped.
        if appEventStreamAvailable, !appEventStreamCoordinator.isRunning {
            startAppEventStreamIfAvailable()
        }

        // 3. Refresh global lists as needed (single-flight + freshness-gated).
        await refreshWorkspaceAndSessionLists(force: false)

        // 4. Refresh active session metadata (not timeline — ChatSessionManager owns that)
        guard let sessionId = focusedSessionId else { return }
        guard let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId,
              !workspaceId.isEmpty else {
            logger.error("Missing workspaceId for active session \(sessionId)")
            return
        }

        let streamAttached = sessionEventContinuations[sessionId] != nil
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
            // AskCard and sheet-backed extension dialogs already live in their
            // canonical pending stores and will restore when focus returns.

            do {
                let (session, _) = try await apiClient.getWorkspaceSession(workspaceId: workspaceId, sessionId: sessionId, traceView: .context)
                applyFetchedSessionState(session)
            } catch {
                logger.error("Failed to refresh session \(sessionId): \(error)")
            }
        } else {
            do {
                let (session, _) = try await apiClient.getWorkspaceSession(workspaceId: workspaceId, sessionId: sessionId, traceView: .context)
                applyFetchedSessionState(session)
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
