import UIKit

/// Loading the workspace's sessions: the refresh and its polling, older
/// history buckets, and the load telemetry.
extension WorkspaceDetailViewController {
    // MARK: Archive buckets

    private func isArchiveBucketGroupID(_ id: String) -> Bool {
        id.hasPrefix("day:") || id.hasPrefix("month:")
    }

    private func pruneArchiveState(validBucketIDs: Set<String>) {
        state.archiveStoppedSessionsByBucketID = state.archiveStoppedSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        state.archiveLocalSessionsByBucketID = state.archiveLocalSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        state.loadingArchiveBucketIDs = state.loadingArchiveBucketIDs.filter { validBucketIDs.contains($0) }
        state.expandedStoppedGroupIDs = state.expandedStoppedGroupIDs.filter {
            validBucketIDs.contains($0) || !isArchiveBucketGroupID($0)
        }
        state.collapsedStoppedGroupIDs = state.collapsedStoppedGroupIDs.filter {
            validBucketIDs.contains($0) || !isArchiveBucketGroupID($0)
        }
    }

    func ensureArchiveBucketLoaded(_ bucket: WorkspaceSessionArchiveBucket) async {
        if state.archiveStoppedSessionsByBucketID[bucket.id] != nil || state.archiveLocalSessionsByBucketID[bucket.id] != nil {
            return
        }
        guard !state.loadingArchiveBucketIDs.contains(bucket.id) else { return }
        guard let api = connection?.apiClient else { return }

        state.loadingArchiveBucketIDs.insert(bucket.id)
        defer { state.loadingArchiveBucketIDs.remove(bucket.id) }

        do {
            let response = try await api.getWorkspaceSessionListBucket(
                workspaceId: workspaceId,
                since: bucket.startAt,
                until: bucket.endAt,
                worktreeId: state.selectedWorktreeId
            )
            state.archiveStoppedSessionsByBucketID[bucket.id] = response.sessionSummaries
                .map(\.session)
                .filter { session in
                    session.status == .stopped &&
                        session.lastActivity >= bucket.startAt &&
                        session.lastActivity < bucket.endAt
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
            let range = (since: startedAt.addingTimeInterval(-Double(Self.hotStoppedRangeDays) * 86_400), until: startedAt)
            let response = try await api.getWorkspaceSessionList(
                workspace: currentWorkspace(connection),
                since: range.since,
                until: range.until,
                worktreeId: state.selectedWorktreeId
            )
            guard !Task.isCancelled, requestedGeneration == state.workspaceRefreshGeneration else { return }

            connection.sessionStore.applyWorkspaceRecentSnapshot(
                workspaceId: workspaceId,
                summaries: response.sessionSummaries,
                requestStartedAt: startedAt
            )
            state.archiveBuckets = response.archiveBuckets
            pruneArchiveState(validBucketIDs: Set(response.archiveBuckets.map(\.id)))
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

    private static let hotStoppedRangeDays = 3
    private static let loadErrorPrefix = "Failed to load workspace:"

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

    func beginWorkspaceLoadIfNeeded(path: String) {
        guard state.workspaceLoad == nil, let connection else { return }
        state.workspaceLoad = WorkspaceLoadMeasurement(
            startedAtMs: Date.nowMs(),
            path: path,
            hadImmediateContent: !workspaceSessions(connection).isEmpty || !state.localSessions.isEmpty
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
        ChatSessionTelemetry.recordTimingMetric(
            .workspaceLoadMs,
            durationMs: Date.nowMs() - workspaceLoad.startedAtMs,
            workspaceId: workspaceId,
            tags: ["path": workspaceLoad.path]
        )
        state.workspaceLoad = nil
    }
}
