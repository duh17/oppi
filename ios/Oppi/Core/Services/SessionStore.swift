import Foundation

/// Observable store for session list and active session state.
///
/// Internally partitioned by server ID — each server's sessions are stored
/// separately, preventing data contamination across servers. The `sessions`
/// computed property delegates to the active server's partition, keeping the
/// external API unchanged.
///
/// Scoped to prevent re-renders from unrelated state changes.
/// Permission timer ticks don't touch this store.
@MainActor @Observable
final class SessionStore {
    // ── Per-server backing storage ──

    /// Sessions keyed by server ID. All mutations go through the active partition.
    private var serverSessions: [String: [Session]] = [:]

    /// Which server's sessions are currently active. Set by ConnectionCoordinator
    /// when switching servers.
    private(set) var activeServerId: String?

    /// The session the user is currently viewing/chatting with.
    var activeSessionId: String?

    // ── Per-server turn-ended dates (stable sort key) ──

    /// Tracks when each session last completed a turn (agentEnd).
    /// Used for stable list sorting — unlike `lastActivity` which updates on
    /// every lifecycle event, this only changes when an agent finishes a turn,
    /// preventing the active session list from constantly reordering during
    /// parallel multi-agent tool calling.
    private var serverTurnEndedDates: [String: [String: Date]] = [:]

    // ── Per-server freshness tracking ──

    private var serverLastSyncAt: [String: Date] = [:]
    private var serverIsSyncing: [String: Bool] = [:]
    private var serverSyncFailed: [String: Bool] = [:]

    // ── Public API: delegates to active server ──

    /// Sessions for the currently active server.
    var sessions: [Session] {
        get { serverSessions[activeServerId ?? ""] ?? [] }
        set { serverSessions[activeServerId ?? ""] = newValue }
    }

    /// Current active session (convenience).
    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    func workspaceId(for sessionId: String) -> String? {
        session(id: sessionId)?.workspaceId
    }

    // ── Cross-server queries ──

    // periphery:ignore - used by SessionStoreTests via @testable import
    /// Sessions for a specific server (regardless of which is active).
    func sessions(forServer serverId: String) -> [Session] {
        serverSessions[serverId] ?? []
    }

    // periphery:ignore - used by SessionStoreTests via @testable import
    /// All sessions across all servers, ordered by last activity.
    var allSessions: [Session] {
        serverSessions.values.flatMap { $0 }.sorted { $0.lastActivity > $1.lastActivity }
    }

    // periphery:ignore - used by SessionStoreTests via @testable import
    /// Look up a session by ID across ALL servers.
    /// Returns the session and its server ID, or nil.
    func findSession(id: String) -> (session: Session, serverId: String)? {
        for (serverId, sessions) in serverSessions {
            if let session = sessions.first(where: { $0.id == id }) {
                return (session, serverId)
            }
        }
        return nil
    }

    // ── Server switching ──

    /// Switch the active server partition. Called by ConnectionCoordinator.
    func switchServer(to serverId: String) {
        guard serverId != activeServerId else { return }
        activeServerId = serverId
        // Initialize partition if needed
        if serverSessions[serverId] == nil {
            serverSessions[serverId] = []
        }
    }

    // periphery:ignore - used by SessionStoreTests via @testable import
    /// Remove all data for a server (on unpair).
    func removeServer(_ serverId: String) {
        serverSessions.removeValue(forKey: serverId)
        serverTurnEndedDates.removeValue(forKey: serverId)
        serverLastSyncAt.removeValue(forKey: serverId)
        serverIsSyncing.removeValue(forKey: serverId)
        serverSyncFailed.removeValue(forKey: serverId)
        if activeServerId == serverId {
            activeServerId = nil
        }
    }

    // ── Turn-ended tracking (stable sort key) ──

    /// Record that a session completed a turn (agentEnd).
    /// Only this event updates the sort key — agentStart, stop events, etc. do not.
    func recordTurnEnded(sessionId: String, at date: Date = Date()) {
        let key = activeServerId ?? ""
        var dates = serverTurnEndedDates[key] ?? [:]
        dates[sessionId] = date
        serverTurnEndedDates[key] = dates
    }

    /// The date the session last completed a turn, or nil if no turn has ended yet.
    /// Views should fall back to `session.createdAt` when nil.
    func turnEndedDate(for sessionId: String) -> Date? {
        let key = activeServerId ?? ""
        return serverTurnEndedDates[key]?[sessionId]
    }

    // ── Freshness (delegates to active server) ──

    private var freshnessKey: String { activeServerId ?? "" }

    var lastSuccessfulSyncAt: Date? {
        get { serverLastSyncAt[freshnessKey] }
        set { serverLastSyncAt[freshnessKey] = newValue }
    }

    var isSyncing: Bool {
        get { serverIsSyncing[freshnessKey] ?? false }
        set { serverIsSyncing[freshnessKey] = newValue }
    }

    var lastSyncFailed: Bool {
        get { serverSyncFailed[freshnessKey] ?? false }
        set { serverSyncFailed[freshnessKey] = newValue }
    }

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

    // periphery:ignore - store freshness API surface; not yet consumed by UI
    func freshnessState(now: Date = Date(), staleAfter: TimeInterval = 300) -> FreshnessState {
        FreshnessState.derive(
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            isSyncing: isSyncing,
            lastSyncFailed: lastSyncFailed,
            staleAfter: staleAfter,
            now: now
        )
    }

    // periphery:ignore - store freshness API surface; not yet consumed by UI
    func freshnessLabel(now: Date = Date()) -> String {
        FreshnessState.updatedLabel(lastSuccessfulSyncAt: lastSuccessfulSyncAt, now: now)
    }

    // ── Mutations (operate on active server partition) ──

    /// Insert or update a session from server data.
    ///
    /// Returns true only when the backing array was actually mutated.
    @discardableResult
    func upsert(_ session: Session) -> Bool {
        var list = sessions
        if let idx = list.firstIndex(where: { $0.id == session.id }) {
            guard list[idx] != session else { return false }
            list[idx] = session
        } else {
            list.insert(session, at: 0)
        }
        sessions = list
        return true
    }

    /// Remove a session.
    func remove(id: String) {
        var list = sessions
        list.removeAll { $0.id == id }
        sessions = list
        let key = activeServerId ?? ""
        serverTurnEndedDates[key]?.removeValue(forKey: id)
        if activeSessionId == id {
            activeSessionId = nil
        }
    }

    // periphery:ignore - used by StoreTests via @testable import
    /// Sort sessions by last activity (most recent first).
    func sort() {
        var list = sessions
        list.sort { $0.lastActivity > $1.lastActivity }
        sessions = list
    }

    /// Apply a full server snapshot while preserving likely in-flight locals.
    ///
    /// This avoids stale list responses (started before a local create) from
    /// making newly-created sessions disappear when the user re-enters lists.
    func applyServerSnapshot(_ snapshot: [Session], preserveRecentWindow: TimeInterval = 180) {
        let now = Date()
        let serverIds = Set(snapshot.map(\.id))
        let current = sessions

        let preservedLocals = current.filter { local in
            guard !serverIds.contains(local.id) else { return false }
            if local.status != .stopped { return true }
            return now.timeIntervalSince(local.createdAt) <= preserveRecentWindow
        }

        var merged = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        for local in preservedLocals {
            merged[local.id] = local
        }

        sessions = merged.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}
