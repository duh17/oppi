import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WorkspaceStore")

/// Per-server sync state for freshness tracking.
struct ServerSyncState: Sendable {
    var lastSuccessfulSyncAt: Date?
    var isSyncing: Bool = false
    var lastSyncFailed: Bool = false

    var freshnessState: FreshnessState {
        freshnessState()
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

    mutating func markSyncStarted() {
        isSyncing = true
    }

    mutating func markSyncSucceeded(at date: Date = Date()) {
        isSyncing = false
        lastSyncFailed = false
        lastSuccessfulSyncAt = date
    }

    mutating func markSyncFailed() {
        isSyncing = false
        lastSyncFailed = true
    }
}

/// Observable store for workspaces and the available skill pool.
///
/// Supports both single-server (legacy) and multi-server usage:
/// - Single-server: `load(api:)` + `workspaces`/`skills`
/// - Multi-server: `loadAll(servers:)` + `workspacesByServer`/`skillsByServer`
@MainActor @Observable
final class WorkspaceStore {
    // ── Single-server (backward compat) ──

    var workspaces: [Workspace] = []
    var skills: [SkillInfo] = []
    var isLoaded = false

    /// Freshness metadata for single-server refreshes.
    var lastSuccessfulSyncAt: Date?
    var isSyncing = false
    var lastSyncFailed = false

    // ── Multi-server ──

    /// Workspaces keyed by server ID (fingerprint).
    var workspacesByServer: [String: [Workspace]] = [:]

    /// Skills keyed by server ID (fingerprint).
    var skillsByServer: [String: [SkillInfo]] = [:]

    /// Per-server sync freshness tracking.
    var serverFreshness: [String: ServerSyncState] = [:]

    /// Ordered server IDs reflecting display order. Set by `loadAll`.
    /// Visible for testing; prefer `loadAll` for production use.
    var serverOrder: [String] = []

    /// All workspaces flattened from all servers, ordered by server sort order.
    var allWorkspaces: [Workspace] {
        serverOrder.flatMap { workspacesByServer[$0] ?? [] }
    }

    /// All skills flattened from all servers (deduplicated by name).
    var allSkills: [SkillInfo] {
        var seen = Set<String>()
        return serverOrder.flatMap { skillsByServer[$0] ?? [] }
            .filter { seen.insert($0.name).inserted }
    }

    /// Whether ALL servers have been loaded at least once.
    var isAllLoaded: Bool {
        guard !serverOrder.isEmpty else { return false }
        return serverOrder.allSatisfy { serverFreshness[$0]?.lastSuccessfulSyncAt != nil }
    }

    /// Whether ANY server is currently syncing.
    var isAnySyncing: Bool {
        serverFreshness.values.contains { $0.isSyncing }
    }

    /// Test seam: inject isolated cache instance.
    var _cacheForTesting: TimelineCache?

    // ── Single-server freshness (backward compat) ──

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

    // ── Multi-server freshness ──

    /// Get freshness state for a specific server.
    func freshnessState(forServer serverId: String, now: Date = Date(), staleAfter: TimeInterval = 300) -> FreshnessState {
        guard let state = serverFreshness[serverId] else { return .offline }
        return state.freshnessState(now: now, staleAfter: staleAfter)
    }

    /// Get freshness label for a specific server.
    func freshnessLabel(forServer serverId: String, now: Date = Date()) -> String {
        guard let state = serverFreshness[serverId] else { return "Updated never" }
        return state.freshnessLabel(now: now)
    }

    // ── Mutations ──

    /// Insert or update a workspace.
    func upsert(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    /// Insert or update a workspace for a specific server.
    func upsert(_ workspace: Workspace, serverId: String) {
        var list = workspacesByServer[serverId] ?? []
        if let idx = list.firstIndex(where: { $0.id == workspace.id }) {
            list[idx] = workspace
        } else {
            list.append(workspace)
        }
        workspacesByServer[serverId] = list
    }

    /// Remove a workspace by ID.
    func remove(id: String) {
        workspaces.removeAll { $0.id == id }
    }

    /// Remove a workspace by ID from a specific server.
    func remove(id: String, serverId: String) {
        workspacesByServer[serverId]?.removeAll { $0.id == id }
    }

    /// Remove all data for a server (on unpair).
    func removeServer(_ serverId: String) {
        workspacesByServer.removeValue(forKey: serverId)
        skillsByServer.removeValue(forKey: serverId)
        serverFreshness.removeValue(forKey: serverId)
        serverOrder.removeAll { $0 == serverId }
    }

    // ── Single-server load (backward compat) ──

    /// Load workspaces and skills from a single server.
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

    // ── Multi-server load ──

    /// Load workspaces and skills from ALL paired servers in parallel.
    ///
    /// Each server's data is cached and fetched independently.
    /// Failures are per-server — one server going down doesn't affect others.
    func loadAll(servers: [PairedServer]) async {
        let cache = _cacheForTesting ?? TimelineCache.shared
        serverOrder = servers.map(\.id)

        // Initialize freshness for new servers
        for server in servers where serverFreshness[server.id] == nil {
            serverFreshness[server.id] = ServerSyncState()
        }

        // Show cached data immediately for servers not yet loaded
        await withTaskGroup(of: (String, [Workspace]?, [SkillInfo]?).self) { group in
            for server in servers where workspacesByServer[server.id] == nil {
                let serverId = server.id
                group.addTask {
                    let ws = await cache.loadWorkspaces(serverId: serverId)
                    let sk = await cache.loadSkills(serverId: serverId)
                    return (serverId, ws, sk)
                }
            }
            for await (serverId, ws, sk) in group {
                if let ws { workspacesByServer[serverId] = ws }
                if let sk { skillsByServer[serverId] = sk }
            }
        }

        // Mark all servers as syncing
        for server in servers {
            serverFreshness[server.id]?.markSyncStarted()
        }

        // Fetch from all servers in parallel
        await withTaskGroup(of: (String, Result<([Workspace], [SkillInfo]), Error>).self) { group in
            for server in servers {
                guard let baseURL = server.baseURL else { continue }
                let serverId = server.id
                let token = server.token

                group.addTask {
                    let api = APIClient(baseURL: baseURL, token: token)
                    do {
                        async let ws = api.listWorkspaces()
                        async let sk = api.listSkills()
                        let result = try await (ws, sk)
                        return (serverId, .success(result))
                    } catch {
                        return (serverId, .failure(error))
                    }
                }
            }

            for await (serverId, result) in group {
                switch result {
                case .success(let (ws, sk)):
                    workspacesByServer[serverId] = ws
                    skillsByServer[serverId] = sk
                    serverFreshness[serverId]?.markSyncSucceeded()
                    logger.info("Loaded \(ws.count) workspaces, \(sk.count) skills from server \(serverId.prefix(16), privacy: .public)")

                    // Update per-server cache
                    let capturedServerId = serverId
                    Task.detached {
                        await cache.saveWorkspaces(ws, serverId: capturedServerId)
                        await cache.saveSkills(sk, serverId: capturedServerId)
                    }

                case .failure(let error):
                    serverFreshness[serverId]?.markSyncFailed()
                    logger.error("Failed to load from server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Sync flat lists for backward compat
        workspaces = allWorkspaces
        skills = allSkills
        isLoaded = true
    }
}
