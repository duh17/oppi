import Foundation

/// Observable store for workspaces and the available skill pool.
@MainActor @Observable
final class WorkspaceStore {
    var workspaces: [Workspace] = []
    var skills: [SkillInfo] = []
    var isLoaded = false

    /// Freshness metadata for workspace/skill refreshes.
    var lastSuccessfulSyncAt: Date?
    var isSyncing = false
    var lastSyncFailed = false

    /// Test seam: inject isolated cache instance.
    var _cacheForTesting: TimelineCache?

    func markSyncStarted() {
        isSyncing = true
    }

    func markSyncSucceeded(at date: Date = Date()) {
        isSyncing = false
        lastSyncFailed = false
        lastSuccessfulSyncAt = date
    }

    func markSyncFailed() {
        isSyncing = false
        lastSyncFailed = true
    }

    func freshnessState(now: Date = Date(), staleAfter: TimeInterval = 300) -> FreshnessState {
        FreshnessState.derive(
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            isSyncing: isSyncing,
            lastSyncFailed: lastSyncFailed,
            staleAfter: staleAfter,
            now: now
        )
    }

    func freshnessLabel(now: Date = Date()) -> String {
        FreshnessState.updatedLabel(lastSuccessfulSyncAt: lastSuccessfulSyncAt, now: now)
    }

    /// Insert or update a workspace.
    func upsert(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    /// Remove a workspace by ID.
    func remove(id: String) {
        workspaces.removeAll { $0.id == id }
    }

    /// Load workspaces and skills from the server.
    ///
    /// Shows cached data immediately if stores are empty, then refreshes
    /// from the server in the same call. Cache is updated on success.
    func load(api: APIClient) async {
        let cache = _cacheForTesting ?? TimelineCache.shared

        // Show cached data immediately if this is first load
        if !isLoaded {
            async let cachedWs = cache.loadWorkspaces()
            async let cachedSk = cache.loadSkills()
            let (cws, csk) = await (cachedWs, cachedSk)
            if let cws { workspaces = cws }
            if let csk { skills = csk }
        }

        markSyncStarted()

        // Fetch fresh from server
        async let fetchWorkspaces = api.listWorkspaces()
        async let fetchSkills = api.listSkills()

        do {
            let (ws, sk) = try await (fetchWorkspaces, fetchSkills)
            workspaces = ws
            skills = sk
            isLoaded = true
            markSyncSucceeded()

            // Update cache in background
            Task.detached {
                await cache.saveWorkspaces(ws)
                await cache.saveSkills(sk)
            }
        } catch {
            markSyncFailed()
            // Keep stale/cached data on error; retry on next load
            if !isLoaded && !workspaces.isEmpty {
                isLoaded = true  // Mark loaded if we have cached data
            }
        }
    }
}
