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
/// Canonical source of truth is per-server storage (`workspacesByServer`,
/// `skillsByServer`). The legacy `workspaces` / `skills` API is now just an
/// active-server view over that same storage, so single- and multi-server
/// flows share one data path.
@MainActor @Observable
final class WorkspaceStore {
    // MARK: - Active server context

    /// Which server's catalog is exposed through `workspaces` / `skills`.
    private(set) var activeServerId: String?

    /// Tracks whether each server catalog has been loaded at least once.
    private var serverLoaded: [String: Bool] = [:]

    private var activeKey: String { activeServerId ?? "" }

    // MARK: - Canonical per-server storage

    /// Workspaces keyed by server ID (fingerprint).
    var workspacesByServer: [String: [Workspace]] = [:]

    /// Skills keyed by server ID (fingerprint).
    var skillsByServer: [String: [SkillInfo]] = [:]

    /// Per-server sync freshness tracking.
    var serverFreshness: [String: ServerSyncState] = [:]

    /// Ordered server IDs reflecting display order.
    var serverOrder: [String] = []

    /// Test seam: inject isolated cache instance.
    var _cacheForTesting: TimelineCache?

    // MARK: - Active-server compatibility API

    /// Active server workspaces (legacy API).
    var workspaces: [Workspace] {
        get { workspacesByServer[activeKey] ?? [] }
        set { workspacesByServer[activeKey] = newValue }
    }

    /// Active server skills (legacy API).
    var skills: [SkillInfo] {
        get { skillsByServer[activeKey] ?? [] }
        set { skillsByServer[activeKey] = newValue }
    }

    /// Active server loaded state (legacy API).
    var isLoaded: Bool {
        get { serverLoaded[activeKey] ?? false }
        set { serverLoaded[activeKey] = newValue }
    }

    /// Active server freshness (legacy API).
    var lastSuccessfulSyncAt: Date? {
        get { serverFreshness[activeKey]?.lastSuccessfulSyncAt }
        set {
            mutateFreshness(for: activeKey) { state in
                state.lastSuccessfulSyncAt = newValue
            }
        }
    }

    /// Active server syncing flag (legacy API).
    var isSyncing: Bool {
        get { serverFreshness[activeKey]?.isSyncing ?? false }
        set {
            mutateFreshness(for: activeKey) { state in
                state.isSyncing = newValue
            }
        }
    }

    /// Active server last-failure flag (legacy API).
    var lastSyncFailed: Bool {
        get { serverFreshness[activeKey]?.lastSyncFailed ?? false }
        set {
            mutateFreshness(for: activeKey) { state in
                state.lastSyncFailed = newValue
            }
        }
    }

    // MARK: - Cross-server queries

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

    /// Whether ALL servers have successfully synced at least once.
    var isAllLoaded: Bool {
        guard !serverOrder.isEmpty else { return false }
        return serverOrder.allSatisfy { serverFreshness[$0]?.lastSuccessfulSyncAt != nil }
    }

    /// Whether ANY server is currently syncing.
    var isAnySyncing: Bool {
        serverFreshness.values.contains { $0.isSyncing }
    }

    // MARK: - Server context

    /// Switch active-server compatibility view to a different server.
    func switchServer(to serverId: String) {
        guard serverId != activeServerId else { return }
        activeServerId = serverId

        if workspacesByServer[serverId] == nil {
            workspacesByServer[serverId] = []
        }
        if skillsByServer[serverId] == nil {
            skillsByServer[serverId] = []
        }
        if serverFreshness[serverId] == nil {
            serverFreshness[serverId] = ServerSyncState()
        }
        if serverLoaded[serverId] == nil {
            serverLoaded[serverId] = false
        }
    }

    // MARK: - Freshness (active server compatibility)

    func markSyncStarted() {
        markSyncStarted(forServer: activeKey)
    }

    func markSyncSucceeded(at date: Date = Date()) {
        markSyncSucceeded(forServer: activeKey, at: date)
    }

    func markSyncFailed() {
        markSyncFailed(forServer: activeKey)
    }

    func freshnessState(now: Date = Date(), staleAfter: TimeInterval = 300) -> FreshnessState {
        freshnessState(forServer: activeKey, now: now, staleAfter: staleAfter)
    }

    func freshnessLabel(now: Date = Date()) -> String {
        freshnessLabel(forServer: activeKey, now: now)
    }

    // MARK: - Freshness (per-server)

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

    // MARK: - Mutations

    /// Insert or update a workspace in the active-server partition.
    func upsert(_ workspace: Workspace) {
        upsert(workspace, serverId: activeKey)
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

    /// Remove a workspace by ID from active-server partition.
    func remove(id: String) {
        remove(id: id, serverId: activeKey)
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
        serverLoaded.removeValue(forKey: serverId)
        serverOrder.removeAll { $0 == serverId }
        if activeServerId == serverId {
            activeServerId = nil
        }
    }

    // MARK: - Loading

    /// Load workspaces + skills for the active server (compatibility wrapper).
    ///
    /// Uses cache immediately when first loading this server, then refreshes
    /// from network. Single- and multi-server paths share `loadServer`.
    func load(api: APIClient) async {
        await loadServer(serverId: activeKey, api: api, allowLegacyFallback: true)
    }

    /// Load workspaces + skills for a specific server.
    func loadServer(serverId: String, api: APIClient, allowLegacyFallback: Bool = false) async {
        let cache = _cacheForTesting ?? TimelineCache.shared

        if !serverId.isEmpty && !serverOrder.contains(serverId) {
            serverOrder.append(serverId)
        }
        if serverLoaded[serverId] == nil {
            serverLoaded[serverId] = false
        }
        ensureFreshness(for: serverId)

        // Show cached data immediately on first load for this server.
        if serverLoaded[serverId] != true {
            let cached = await loadCachedCatalog(
                serverId: serverId,
                cache: cache,
                allowLegacyFallback: allowLegacyFallback
            )

            if let cws = cached.workspaces {
                workspacesByServer[serverId] = cws
            }
            if let csk = cached.skills {
                skillsByServer[serverId] = csk
            }

            let hasCachedData = (cached.workspaces?.isEmpty == false) || (cached.skills?.isEmpty == false)
            if hasCachedData {
                serverLoaded[serverId] = true
            }

            // Opportunistic cache migration: legacy → namespaced.
            if cached.usedLegacy, !serverId.isEmpty {
                let capturedServerId = serverId
                let cachedWorkspaces = cached.workspaces
                let cachedSkills = cached.skills
                Task.detached {
                    if let cachedWorkspaces {
                        await cache.saveWorkspaces(cachedWorkspaces, serverId: capturedServerId)
                    }
                    if let cachedSkills {
                        await cache.saveSkills(cachedSkills, serverId: capturedServerId)
                    }
                }
            }
        }

        markSyncStarted(forServer: serverId)

        async let fetchWorkspaces = api.listWorkspaces()
        async let fetchSkills = api.listSkills()

        do {
            let (ws, sk) = try await (fetchWorkspaces, fetchSkills)
            workspacesByServer[serverId] = ws
            skillsByServer[serverId] = sk
            serverLoaded[serverId] = true
            markSyncSucceeded(forServer: serverId)

            if serverId.isEmpty {
                logger.info("Loaded \(ws.count) workspaces, \(sk.count) skills")
            } else {
                logger.info("Loaded \(ws.count) workspaces, \(sk.count) skills from server \(serverId.prefix(16), privacy: .public)")
            }

            let capturedServerId = serverId
            Task.detached {
                if capturedServerId.isEmpty {
                    await cache.saveWorkspaces(ws)
                    await cache.saveSkills(sk)
                } else {
                    await cache.saveWorkspaces(ws, serverId: capturedServerId)
                    await cache.saveSkills(sk, serverId: capturedServerId)
                }
            }
        } catch {
            markSyncFailed(forServer: serverId)
            if serverId.isEmpty {
                logger.error("Failed to load workspaces/skills: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.error("Failed to load from server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            // Keep stale/cached data on error.
            if serverLoaded[serverId] != true {
                let hasCachedData = !(workspacesByServer[serverId] ?? []).isEmpty
                    || !(skillsByServer[serverId] ?? []).isEmpty
                if hasCachedData {
                    serverLoaded[serverId] = true
                }
            }
        }
    }

    /// Load workspaces and skills from ALL paired servers.
    ///
    /// Uses the same per-server path as single-server loads (`loadServer`).
    func loadAll(servers: [PairedServer]) async {
        serverOrder = servers.map(\.id)

        for server in servers {
            ensureFreshness(for: server.id)
            if serverLoaded[server.id] == nil {
                serverLoaded[server.id] = false
            }
        }

        let allowLegacyFallback = servers.count == 1
        for server in servers {
            guard let baseURL = server.baseURL else { continue }
            let api = APIClient(baseURL: baseURL, token: server.token)
            await loadServer(
                serverId: server.id,
                api: api,
                allowLegacyFallback: allowLegacyFallback
            )
        }
    }

    // MARK: - Private helpers

    private struct CachedCatalog {
        var workspaces: [Workspace]?
        var skills: [SkillInfo]?
        var usedLegacy = false
    }

    private func ensureFreshness(for serverId: String) {
        if serverFreshness[serverId] == nil {
            serverFreshness[serverId] = ServerSyncState()
        }
    }

    private func mutateFreshness(for serverId: String, _ mutate: (inout ServerSyncState) -> Void) {
        var state = serverFreshness[serverId] ?? ServerSyncState()
        mutate(&state)
        serverFreshness[serverId] = state
    }

    private func markSyncStarted(forServer serverId: String) {
        mutateFreshness(for: serverId) { $0.markSyncStarted() }
    }

    private func markSyncSucceeded(forServer serverId: String, at date: Date = Date()) {
        mutateFreshness(for: serverId) { $0.markSyncSucceeded(at: date) }
    }

    private func markSyncFailed(forServer serverId: String) {
        mutateFreshness(for: serverId) { $0.markSyncFailed() }
    }

    private func loadCachedCatalog(
        serverId: String,
        cache: TimelineCache,
        allowLegacyFallback: Bool
    ) async -> CachedCatalog {
        if serverId.isEmpty {
            async let ws = cache.loadWorkspaces()
            async let sk = cache.loadSkills()
            return await CachedCatalog(workspaces: ws, skills: sk)
        }

        async let namespacedWs = cache.loadWorkspaces(serverId: serverId)
        async let namespacedSk = cache.loadSkills(serverId: serverId)
        var catalog = await CachedCatalog(workspaces: namespacedWs, skills: namespacedSk)

        if allowLegacyFallback, catalog.workspaces == nil || catalog.skills == nil {
            async let legacyWs = cache.loadWorkspaces()
            async let legacySk = cache.loadSkills()
            let fallbackWs = await legacyWs
            let fallbackSk = await legacySk

            if catalog.workspaces == nil, let fallbackWs {
                catalog.workspaces = fallbackWs
                catalog.usedLegacy = true
            }
            if catalog.skills == nil, let fallbackSk {
                catalog.skills = fallbackSk
                catalog.usedLegacy = true
            }
        }

        return catalog
    }
}
