import UIKit

/// Loading the workspace's sessions: the refresh and its polling, older
/// history buckets, and the load telemetry.
extension WorkspaceDetailViewController {
    // MARK: Archive buckets

    func ensureArchiveBucketLoaded(_ bucket: WorkspaceSessionArchiveBucket) async {
        if state.archiveStoppedSessionsByBucketID[bucket.id] != nil || state.archiveLocalSessionsByBucketID[bucket.id] != nil {
            return
        }
        guard !state.loadingArchiveBucketIDs.contains(bucket.id) else { return }
        guard let api = connection?.apiClient else { return }

        state.loadingArchiveBucketIDs.insert(bucket.id)
        defer { state.loadingArchiveBucketIDs.remove(bucket.id) }

        // A section never reaches into the recent list: the server's day can end after this
        // phone's midnight (another time zone, or a server that does not clamp sections).
        let until = min(bucket.endAt, state.recentRangeStart ?? bucket.endAt)
        do {
            let response = try await api.getWorkspaceSessionListBucket(
                workspaceId: workspaceId,
                since: bucket.startAt,
                until: until,
                worktreeId: state.selectedWorktreeId
            )
            // A refresh while this loaded can have moved the section's range; the rows would miss a day.
            guard state.archiveBuckets.contains(where: {
                $0.id == bucket.id && $0.startAt == bucket.startAt && $0.endAt == bucket.endAt
            }) else { return }
            state.archiveStoppedSessionsByBucketID[bucket.id] = response.sessionSummaries
                .map(\.session)
                .filter { session in
                    session.status == .stopped &&
                        session.lastActivity >= bucket.startAt &&
                        session.lastActivity < until
                }
            state.archiveLocalSessionsByBucketID[bucket.id] = response.importableSessions
        } catch {
            showError("Failed to load older sessions: \(error.localizedDescription)")
        }
    }

    private func updateArchiveBucketCounts(
        bucketId: String,
        removedManagedStoppedCount: Int = 0,
        removedImportableLocalCount: Int = 0
    ) {
        guard let index = state.archiveBuckets.firstIndex(where: { $0.id == bucketId }) else { return }
        var bucket = state.archiveBuckets[index]
        bucket.managedStoppedCount = max(0, bucket.managedStoppedCount - removedManagedStoppedCount)
        bucket.importableLocalCount = max(0, bucket.importableLocalCount - removedImportableLocalCount)
        bucket.itemCount = max(0, bucket.itemCount - removedManagedStoppedCount - removedImportableLocalCount)
        if bucket.itemCount == 0 {
            state.archiveBuckets.remove(at: index)
            state.archiveStoppedSessionsByBucketID.removeValue(forKey: bucketId)
            state.archiveLocalSessionsByBucketID.removeValue(forKey: bucketId)
            state.expandedStoppedGroupIDs.remove(bucketId)
            state.collapsedStoppedGroupIDs.remove(bucketId)
        } else {
            state.archiveBuckets[index] = bucket
        }
    }

    func removeArchiveSession(_ sessionId: String) {
        for (bucketId, sessions) in state.archiveStoppedSessionsByBucketID where sessions.contains(where: { $0.id == sessionId }) {
            state.archiveStoppedSessionsByBucketID[bucketId] = sessions.filter { $0.id != sessionId }
            updateArchiveBucketCounts(bucketId: bucketId, removedManagedStoppedCount: 1)
            break
        }
    }

    func removeArchiveLocalSession(_ path: String) {
        for (bucketId, sessions) in state.archiveLocalSessionsByBucketID where sessions.contains(where: { $0.path == path }) {
            state.archiveLocalSessionsByBucketID[bucketId] = sessions.filter { $0.path != path }
            updateArchiveBucketCounts(bucketId: bucketId, removedImportableLocalCount: 1)
            break
        }
    }

    // MARK: Refresh and polling

    func runWorkspaceRefreshPolling() async {
        var policy = SessionListRefreshPollingPolicy()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Int.random(in: 10...15)))
            guard !Task.isCancelled else { break }

            let polling = workspacePollingState()
            guard policy.shouldRefresh(hasActiveWork: polling.hasActiveWork, hasAttention: polling.hasAttention) else {
                continue
            }

            await refreshWorkspaceData()
        }
    }

    private func workspacePollingState() -> (hasActiveWork: Bool, hasAttention: Bool) {
        guard let connection else { return (false, false) }
        let sessions = workspaceSessions(connection)
        let sessionIds = Set(sessions.map(\.id))
        let hasActiveWork = sessions.contains { session in
            switch session.status {
            case .starting, .busy, .stopping:
                true
            case .ready, .stopped, .error:
                false
            }
        }
        let hasAskAttention = sessions.contains { connection.sessionListAskCount(for: $0.id) > 0 }
            || connection.askRequestStore.pending.values.contains { ask in
                ask.workspaceId == workspaceId ||
                    (ask.workspaceId == nil && sessionIds.contains(ask.sessionId))
            }
        return (hasActiveWork: hasActiveWork, hasAttention: hasAskAttention)
    }

    func refreshWorkspaceData() async {
        guard !state.isRefreshingWorkspaceData else { return }
        let requestedGeneration = state.workspaceRefreshGeneration
        state.isRefreshingWorkspaceData = true
        defer {
            if requestedGeneration == state.workspaceRefreshGeneration {
                state.isRefreshingWorkspaceData = false
            }
        }

        guard let connection, let api = connection.apiClient else { return }
        let hadVisibleData = !workspaceSessions(connection).isEmpty
            || !state.localSessions.isEmpty
            || !state.archiveBuckets.isEmpty

        do {
            let startedAt = Date()
            // Recent rows from this midnight on; older sections end at it.
            let rangeStart = SessionInboxStoppedDayPolicy.visibleRangeStart(now: startedAt, calendar: .current)
            let response = try await api.getWorkspaceSessionList(
                workspace: currentWorkspace(connection),
                since: rangeStart,
                until: startedAt,
                worktreeId: state.selectedWorktreeId
            )
            guard !Task.isCancelled, requestedGeneration == state.workspaceRefreshGeneration else { return }

            connection.sessionStore.applyWorkspaceRecentSnapshot(
                workspaceId: workspaceId,
                summaries: response.sessionSummaries,
                requestStartedAt: startedAt
            )
            state.recentRangeStart = rangeStart
            let staleOpenBuckets = state.replaceArchiveBuckets(response.archiveBuckets)
            for bucket in staleOpenBuckets {
                Task { await ensureArchiveBucketLoaded(bucket) }
            }
            state.localSessions = response.importableSessions
            connection.applyWorkspaceAttentionSnapshot(
                APIClient.WorkspaceAttentionResponse(
                    workspaceId: workspaceId,
                    serverNow: response.serverNow,
                    attention: response.attention
                )
            )
            clearError(onlyWithPrefix: Self.loadErrorPrefix)
        } catch {
            guard !Task.isCancelled, requestedGeneration == state.workspaceRefreshGeneration else { return }
            if WorkspaceDetailLoadErrorPolicy.shouldPresent(
                error: error,
                workspaceId: workspaceId,
                hadVisibleData: hadVisibleData,
                knownWorkspaceIds: Set(connection.workspaceStore.workspaces.map(\.id))
            ) {
                showError("\(Self.loadErrorPrefix) \(error.localizedDescription)")
            }
        }
    }

    private static let loadErrorPrefix = "Failed to load workspace:"

    /// Where the recent day groups start: the boundary the last refresh sent,
    /// so recent groups and older sections keep splitting at the same instant
    /// until the next refresh, even across midnight.
    func recentRangeStart(now: Date, calendar: Calendar) -> Date {
        state.recentRangeStart ?? SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar)
    }

    func refreshGitStatus() {
        // GitStatusStore is connection-scoped, so returning from a chat can leave
        // the workspace list showing the last pushed status until REST refreshes it.
        guard let connection, let api = connection.apiClient else { return }
        connection.gitStatusStore.loadInitial(
            workspaceId: workspaceId,
            worktreeId: state.selectedWorktreeId,
            apiClient: api,
            gitStatusEnabled: currentWorkspace(connection).gitStatusEnabled ?? true
        )
    }

    // MARK: Load telemetry

    func beginWorkspaceLoadIfNeeded(path: AppWorkspaceLoad.LoadPath) {
        guard state.workspaceLoad == nil, let connection else { return }
        state.workspaceLoad = WorkspaceLoadMeasurement(
            startedAtMs: Date.nowMs(),
            path: path,
            hadImmediateContent: !workspaceSessions(connection).isEmpty || !state.localSessions.isEmpty,
            backgroundEpoch: AppScenePhase.shared.backgroundEpoch
        )
    }

    func scheduleWorkspaceLoadCompletionCheck() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishWorkspaceLoadIfReady()
        }
    }

    private func finishWorkspaceLoadIfReady() {
        guard let workspaceLoad = state.workspaceLoad else { return }
        if !workspaceLoad.hadImmediateContent, state.isRefreshingWorkspaceData {
            return
        }
        defer { state.workspaceLoad = nil }
        guard workspaceLoad.backgroundEpoch == AppScenePhase.shared.backgroundEpoch else { return }
        Telemetry.record(
            AppWorkspaceLoad(
                durationMs: Double(max(0, Date.nowMs() - workspaceLoad.startedAtMs)),
                loadPath: workspaceLoad.path
            ),
            workspaceId: workspaceId
        )
    }
}

extension WorkspaceDetailViewController.ContentState {
    /// Takes the server's older-history sections. Rows loaded for a section stay only while its
    /// id still names the same `[startAt, endAt)`: the month holding the 30-day line gains a day
    /// at each server midnight, so rows loaded before it would miss that day. Returns the
    /// expanded sections whose rows were dropped, for the caller to load again.
    mutating func replaceArchiveBuckets(_ buckets: [WorkspaceSessionArchiveBucket]) -> [WorkspaceSessionArchiveBucket] {
        let previous = Dictionary(archiveBuckets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let validIDs = Set(buckets.map(\.id))
        let reusableIDs = Set(buckets.filter { bucket in
            previous[bucket.id].map { $0.startAt == bucket.startAt && $0.endAt == bucket.endAt } ?? false
        }.map(\.id))

        archiveBuckets = buckets
        archiveStoppedSessionsByBucketID = archiveStoppedSessionsByBucketID.filter { reusableIDs.contains($0.key) }
        archiveLocalSessionsByBucketID = archiveLocalSessionsByBucketID.filter { reusableIDs.contains($0.key) }
        loadingArchiveBucketIDs = loadingArchiveBucketIDs.filter { reusableIDs.contains($0) }
        expandedStoppedGroupIDs = expandedStoppedGroupIDs.filter { validIDs.contains($0) || !Self.isArchiveBucketGroupID($0) }
        collapsedStoppedGroupIDs = collapsedStoppedGroupIDs.filter { validIDs.contains($0) || !Self.isArchiveBucketGroupID($0) }

        return buckets.filter { expandedStoppedGroupIDs.contains($0.id) && !reusableIDs.contains($0.id) }
    }

    private static func isArchiveBucketGroupID(_ id: String) -> Bool {
        id.hasPrefix("day:") || id.hasPrefix("month:")
    }
}
