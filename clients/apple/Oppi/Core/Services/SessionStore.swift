import Foundation

/// Observable store for session list and active session state.
///
/// Internally partitioned by server ID — each server's sessions are stored
/// separately, preventing data contamination across servers. The `sessions`
/// computed property delegates to the active server's partition, keeping the
/// external API unchanged.
///
/// Scoped to prevent re-renders from unrelated state changes.
@MainActor @Observable
final class SessionStore {
    // ── Per-server backing storage ──

    /// Sessions keyed by server ID. All mutations go through the active partition.
    private var serverSessions: [String: [Session]] = [:]

    /// Cold workspace/session-list projection keyed by server ID.
    ///
    /// Views that render session lists should read this projection instead of
    /// the full session backing store. That keeps list invalidation tied to
    /// list-relevant session updates, and gives hot timeline state a place to
    /// evolve without accidentally waking every workspace row.
    private var serverListProjectionSessions: [String: [Session]] = [:]

    /// Attention counts supplied by cold session-list HTTP snapshots.
    ///
    /// This is intentionally separate from `AskRequestStore`: workspace-home
    /// previews only need badges, while focused chat/detail views need the full
    /// request payloads from the live or attention snapshot paths.
    private var serverListAttentionCounts: [String: [String: SessionSummaryAttentionCounts]] = [:]

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

    /// Sessions deleted locally or confirmed deleted by the server.
    ///
    /// Keep a short-lived tombstone so older in-flight snapshots or summary
    /// events cannot resurrect a just-deleted row in the workspace list.
    private var serverDeletedSessionTombstones: [String: [String: Date]] = [:]
    private static let deletedSessionTombstoneTTL: TimeInterval = 600

    // ── Per-server freshness tracking ──

    private var serverLastSyncAt: [String: Date] = [:]
    private var serverIsSyncing: [String: Bool] = [:]
    private var serverSyncFailed: [String: Bool] = [:]

    // ── Public API: delegates to active server ──

    private var activeServerKey: String { activeServerId ?? "" }

    /// Sessions for the currently active server.
    var sessions: [Session] {
        get { serverSessions[activeServerKey] ?? [] }
        set { replaceActiveSessions(newValue) }
    }

    /// Cold list projection for the currently active server.
    ///
    /// Workspace lists, quick-session active rows, and workspace badges should
    /// consume this instead of `sessions` so future full-session hot fields can
    /// change without causing list recomputation.
    var listProjectionSessions: [Session] {
        serverListProjectionSessions[activeServerKey] ?? []
    }

    func listProjectionSessions(workspaceId: String) -> [Session] {
        listProjectionSessions.filter { $0.workspaceId == workspaceId }
    }

    func listAttentionCounts(for sessionId: String) -> SessionSummaryAttentionCounts {
        serverListAttentionCounts[activeServerKey]?[sessionId] ?? .none
    }

    func listPendingAskCount(for sessionId: String) -> Int {
        listAttentionCounts(for: sessionId).pendingAskCount
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
        if serverListProjectionSessions[serverId] == nil {
            serverListProjectionSessions[serverId] = []
        }
    }

    // periphery:ignore - used by SessionStoreTests via @testable import
    /// Remove all data for a server (on unpair).
    func removeServer(_ serverId: String) {
        serverSessions.removeValue(forKey: serverId)
        serverListProjectionSessions.removeValue(forKey: serverId)
        serverListAttentionCounts.removeValue(forKey: serverId)
        serverTurnEndedDates.removeValue(forKey: serverId)
        serverDeletedSessionTombstones.removeValue(forKey: serverId)
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
        let key = activeServerKey
        var dates = serverTurnEndedDates[key] ?? [:]
        dates[sessionId] = date
        serverTurnEndedDates[key] = dates
    }

    /// The date the session last completed a turn, or nil if no turn has ended yet.
    /// Views should fall back to `session.createdAt` when nil.
    func turnEndedDate(for sessionId: String) -> Date? {
        let key = activeServerKey
        return serverTurnEndedDates[key]?[sessionId]
    }

    // ── Freshness (delegates to active server) ──

    private var freshnessKey: String { activeServerKey }

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
        upsertMerged(session)
    }

    /// Cache a session for direct navigation without broadening the cold list projection.
    ///
    /// Archive rows need enough full-session context for `ChatView` resolution, but
    /// opening an old row must not make it appear in the hot workspace list.
    @discardableResult
    func cacheSessionForNavigation(_ session: Session) -> Bool {
        var list = sessions
        guard merge(session, into: &list) else { return false }
        serverSessions[activeServerKey] = list

        if var projection = serverListProjectionSessions[activeServerKey],
           projection.contains(where: { $0.id == session.id }) {
            _ = merge(session, into: &projection)
            serverListProjectionSessions[activeServerKey] = projection
        }

        return true
    }

    /// Insert or update several sessions as a single store mutation.
    ///
    /// Use for REST list refreshes so cold list projections are invalidated once
    /// per response instead of once per returned session.
    @discardableResult
    func upsertMany(_ incoming: [Session]) -> Bool {
        guard !incoming.isEmpty else { return false }

        var list = sessions
        var didMutate = false
        for session in incoming {
            didMutate = merge(session, into: &list) || didMutate
        }

        guard didMutate else { return false }
        setActiveSessionsPreservingListProjection(list)
        return true
    }

    /// Apply the cold-lane session list projection from the stream.
    ///
    /// This follows the same merge/no-op semantics as full `Session` upserts,
    /// but keeps protocol intent explicit: workspace list updates should come
    /// from summaries, not timeline-frequency live events.
    @discardableResult
    func applySummary(_ summary: SessionSummary) -> Bool {
        let didMutateSession = upsertMerged(summary.session)
        let didMutateAttention = applyListAttentionCounts(from: [summary])
        return didMutateSession || didMutateAttention
    }

    /// Insert or update several session summaries as a single store mutation.
    @discardableResult
    func upsertManySummaries(_ summaries: [SessionSummary]) -> Bool {
        let didMutateSessions = upsertMany(summaries.map(\.session))
        let didMutateAttention = applyListAttentionCounts(from: summaries)
        return didMutateSessions || didMutateAttention
    }

    /// Apply the authoritative recent workspace snapshot used by workspace detail.
    ///
    /// Anything missing from this hot recent lane should fall out of the active
    /// workspace partition unless it is a likely optimistic local row or an
    /// ancestor needed for visible tree structure. `requestStartedAt` protects
    /// optimistic local creates from older in-flight refreshes.
    @discardableResult
    func applyWorkspaceRecentSnapshot(
        workspaceId: String,
        summaries incomingSummaries: [SessionSummary],
        requestStartedAt: Date = Date(),
        preserveRecentWindow: TimeInterval = 180
    ) -> Bool {
        let current = sessions
        let incomingForWorkspace = incomingSummaries.map(\.session).compactMap { session -> Session? in
            guard !isDeletedSessionTombstoned(session.id) else { return nil }
            guard session.workspaceId == nil || session.workspaceId == workspaceId else { return nil }
            var normalized = session
            if normalized.workspaceId == nil {
                normalized.workspaceId = workspaceId
            }
            return normalized
        }

        var incomingById: [String: Session] = [:]
        var incomingOrder: [String] = []
        for session in incomingForWorkspace {
            if incomingById[session.id] == nil {
                incomingOrder.append(session.id)
            }
            incomingById[session.id] = session
        }

        let incomingIds = Set(incomingById.keys)
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let ancestorIds = ancestorIdsForVisibleRows(incomingForWorkspace, currentById: currentById)
        var nextById: [String: Session] = [:]

        for existing in current where existing.workspaceId != workspaceId {
            nextById[existing.id] = existing
        }

        for existing in current where existing.workspaceId == workspaceId {
            if incomingIds.contains(existing.id) {
                continue
            }

            if shouldPreserveMissingWorkspaceRecentRow(
                existing,
                requestStartedAt: requestStartedAt,
                preserveRecentWindow: preserveRecentWindow,
                ancestorIds: ancestorIds
            ) {
                nextById[existing.id] = existing
            }
        }

        for incomingId in incomingOrder {
            guard let incomingSession = incomingById[incomingId] else { continue }
            if let existing = currentById[incomingSession.id] {
                nextById[incomingSession.id] = mergePreservingContext(
                    existing: existing,
                    incoming: incomingSession
                )
            } else {
                nextById[incomingSession.id] = incomingSession
            }
        }

        let next = nextById.values.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.id < rhs.id
        }
        let didMutateAttention = applyListAttentionCounts(
            from: incomingSummaries,
            replacingWorkspaceId: workspaceId
        )
        guard next != current else { return didMutateAttention }

        let nextIds = Set(next.map(\.id))
        let removedIds = Set(current.map(\.id)).subtracting(nextIds)
        let key = activeServerKey
        for removedId in removedIds {
            serverTurnEndedDates[key]?.removeValue(forKey: removedId)
        }
        if let activeSessionId, removedIds.contains(activeSessionId) {
            self.activeSessionId = nil
        }

        setActiveSessionsPreservingListProjection(next)
        return true
    }

    @discardableResult
    private func applyListAttentionCounts(
        from summaries: [SessionSummary],
        replacingWorkspaceId workspaceId: String? = nil
    ) -> Bool {
        let key = activeServerKey
        var counts = serverListAttentionCounts[key] ?? [:]
        let original = counts

        if let workspaceId {
            for session in listProjectionSessions where session.workspaceId == workspaceId {
                counts.removeValue(forKey: session.id)
            }
        }

        for summary in summaries {
            guard !isDeletedSessionTombstoned(summary.id) else { continue }
            let nextCounts = summary.attentionCounts
            if nextCounts.hasAttention {
                counts[summary.id] = nextCounts
            } else {
                counts.removeValue(forKey: summary.id)
            }
        }

        guard counts != original else { return false }
        if counts.isEmpty {
            serverListAttentionCounts.removeValue(forKey: key)
        } else {
            serverListAttentionCounts[key] = counts
        }
        return true
    }

    private func upsertMerged(_ session: Session) -> Bool {
        var list = sessions
        guard merge(session, into: &list) else { return false }
        setActiveSessionsPreservingListProjection(list)
        return true
    }

    private func merge(_ session: Session, into list: inout [Session]) -> Bool {
        guard !isDeletedSessionTombstoned(session.id) else { return false }

        if let idx = list.firstIndex(where: { $0.id == session.id }) {
            let merged = mergePreservingContext(existing: list[idx], incoming: session)
            guard list[idx] != merged else { return false }
            list[idx] = merged
        } else {
            list.insert(session, at: 0)
        }
        return true
    }

    private func markDeletedSessionTombstone(_ sessionId: String, at date: Date = Date()) {
        pruneDeletedSessionTombstones(now: date)
        let key = activeServerKey
        var tombstones = serverDeletedSessionTombstones[key] ?? [:]
        tombstones[sessionId] = date
        serverDeletedSessionTombstones[key] = tombstones
    }

    private func isDeletedSessionTombstoned(_ sessionId: String, now: Date = Date()) -> Bool {
        let key = activeServerKey
        guard let deletedAt = serverDeletedSessionTombstones[key]?[sessionId] else {
            return false
        }
        if now.timeIntervalSince(deletedAt) <= Self.deletedSessionTombstoneTTL {
            return true
        }

        serverDeletedSessionTombstones[key]?[sessionId] = nil
        return false
    }

    private func pruneDeletedSessionTombstones(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.deletedSessionTombstoneTTL)
        let key = activeServerKey
        guard var tombstones = serverDeletedSessionTombstones[key] else { return }
        tombstones = tombstones.filter { _, deletedAt in
            deletedAt >= cutoff
        }
        if tombstones.isEmpty {
            serverDeletedSessionTombstones.removeValue(forKey: key)
        } else {
            serverDeletedSessionTombstones[key] = tombstones
        }
    }

    private func replaceActiveSessions(_ list: [Session]) {
        let key = activeServerKey
        serverSessions[key] = list
        serverListProjectionSessions[key] = list
        pruneListAttentionCounts(key: key, keepingSessionIds: Set(list.map(\.id)))
    }

    private func setActiveSessionsPreservingListProjection(_ list: [Session]) {
        let key = activeServerKey
        serverSessions[key] = list
        if listProjectionChanged(key: key, newSessions: list) {
            serverListProjectionSessions[key] = list
        }
        pruneListAttentionCounts(key: key, keepingSessionIds: Set(list.map(\.id)))
    }

    private func pruneListAttentionCounts(key: String, keepingSessionIds ids: Set<String>) {
        guard let current = serverListAttentionCounts[key] else { return }
        let next = current.filter { ids.contains($0.key) }
        guard next != current else { return }
        if next.isEmpty {
            serverListAttentionCounts.removeValue(forKey: key)
        } else {
            serverListAttentionCounts[key] = next
        }
    }

    private func listProjectionChanged(key: String, newSessions: [Session]) -> Bool {
        let current = serverListProjectionSessions[key] ?? []
        guard current.count == newSessions.count else { return true }
        let currentSummaries = current.map { SessionSummary(from: $0) }
        let newSummaries = newSessions.map { SessionSummary(from: $0) }
        return currentSummaries != newSummaries
    }

    private func shouldPreserveMissingWorkspaceRecentRow(
        _ session: Session,
        requestStartedAt: Date,
        preserveRecentWindow: TimeInterval,
        ancestorIds: Set<String>
    ) -> Bool {
        if ancestorIds.contains(session.id) { return true }

        if isRecentOptimisticLocal(
            session,
            requestStartedAt: requestStartedAt,
            preserveRecentWindow: preserveRecentWindow
        ) {
            return true
        }

        // Workspace recent snapshots are the hot navigation lane. Anything not
        // returned for that lane should fall out of the hot store so old
        // stopped history does not keep bloating workspace list rebuilds.
        return false
    }

    private func isRecentOptimisticLocal(
        _ session: Session,
        requestStartedAt: Date,
        preserveRecentWindow: TimeInterval
    ) -> Bool {
        if session.createdAt >= requestStartedAt { return true }
        return requestStartedAt.timeIntervalSince(session.createdAt) <= preserveRecentWindow
    }

    private func ancestorIdsForVisibleRows(
        _ visibleRows: [Session],
        currentById: [String: Session]
    ) -> Set<String> {
        var ancestors: Set<String> = []
        var pending = visibleRows.compactMap(\.parentSessionId)

        while let parentId = pending.popLast() {
            guard !ancestors.contains(parentId) else { continue }
            guard let parent = currentById[parentId] else { continue }
            ancestors.insert(parentId)
            if let grandparentId = parent.parentSessionId {
                pending.append(grandparentId)
            }
        }

        return ancestors
    }

    private func mergePreservingContext(existing: Session, incoming: Session) -> Session {
        var merged = incoming

        if let existingTokens = existing.contextTokens, existingTokens > 0 {
            if merged.contextTokens == nil || merged.contextTokens == 0 {
                merged.contextTokens = existingTokens
            }
        } else if merged.contextTokens == nil {
            merged.contextTokens = existing.contextTokens
        }

        if merged.contextWindow == nil {
            merged.contextWindow = existing.contextWindow
        }

        if merged.workspaceId == nil || merged.workspaceId?.isEmpty == true {
            merged.workspaceId = existing.workspaceId
        }
        if merged.workspaceName == nil || merged.workspaceName?.isEmpty == true {
            merged.workspaceName = existing.workspaceName
        }
        if merged.model == nil || merged.model?.isEmpty == true {
            merged.model = existing.model
        }

        if merged.currentTurnStartedAt == nil,
           existing.currentTurnStartedAt != nil,
           isWorkingStatus(merged.status) {
            merged.currentTurnStartedAt = existing.currentTurnStartedAt
        }

        return merged
    }

    private func isWorkingStatus(_ status: SessionStatus) -> Bool {
        switch status {
        case .starting, .busy, .stopping:
            return true
        case .ready, .stopped, .error:
            return false
        }
    }

    /// Remove a session.
    func remove(id: String) {
        markDeletedSessionTombstone(id)

        var list = sessions
        list.removeAll { $0.id == id }
        sessions = list
        let key = activeServerKey
        serverListAttentionCounts[key]?.removeValue(forKey: id)
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
        let filteredSnapshot = snapshot.filter { !isDeletedSessionTombstoned($0.id, now: now) }
        let serverIds = Set(filteredSnapshot.map(\.id))
        let current = sessions

        let preservedLocals = current.filter { local in
            guard !serverIds.contains(local.id) else { return false }
            if local.status != .stopped { return true }
            return now.timeIntervalSince(local.createdAt) <= preserveRecentWindow
        }

        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var merged: [String: Session] = [:]
        for remote in filteredSnapshot {
            if let existing = currentById[remote.id] {
                merged[remote.id] = mergePreservingContext(existing: existing, incoming: remote)
            } else {
                merged[remote.id] = remote
            }
        }
        for local in preservedLocals {
            merged[local.id] = local
        }

        sessions = merged.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}
