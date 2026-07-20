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
    var activeSessionId: String? {
        didSet {
            if let activeSessionId {
                markSessionRead(sessionId: activeSessionId)
            }
        }
    }

    /// Sessions deleted locally or confirmed deleted by the server.
    ///
    /// Keep a short-lived tombstone so older in-flight snapshots or summary
    /// events cannot resurrect a just-deleted row in the workspace list.
    private var serverDeletedSessionTombstones: [String: [String: Date]] = [:]
    private static let deletedSessionTombstoneTTL: TimeInterval = 600

    /// Completion timestamps for turns that finished while the user was not
    /// viewing the session. Session rows use this as the "done, unread" clock.
    private var serverUnreadCompletionDates: [String: [String: Date]] = [:]

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

    func routeScope(for sessionId: String) -> SessionRouteScope? {
        guard let session = session(id: sessionId) else { return nil }
        if session.control != nil { return .control }
        guard let workspaceId = session.workspaceId, !workspaceId.isEmpty else { return nil }
        return .workspace(workspaceId)
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
        serverDeletedSessionTombstones.removeValue(forKey: serverId)
        serverUnreadCompletionDates.removeValue(forKey: serverId)
        serverLastSyncAt.removeValue(forKey: serverId)
        serverIsSyncing.removeValue(forKey: serverId)
        serverSyncFailed.removeValue(forKey: serverId)
        if activeServerId == serverId {
            activeServerId = nil
        }
    }

    /// Record a completed turn that should be shown as unread in session rows.
    func recordUnreadCompletion(sessionId: String, at date: Date = Date()) {
        let key = activeServerKey
        var dates = serverUnreadCompletionDates[key] ?? [:]
        dates[sessionId] = date
        serverUnreadCompletionDates[key] = dates
    }

    func unreadCompletionDate(for sessionId: String) -> Date? {
        serverUnreadCompletionDates[activeServerKey]?[sessionId]
    }

    func markSessionRead(sessionId: String) {
        let key = activeServerKey
        guard var dates = serverUnreadCompletionDates[key], dates.removeValue(forKey: sessionId) != nil else {
            return
        }

        if dates.isEmpty {
            serverUnreadCompletionDates.removeValue(forKey: key)
        } else {
            serverUnreadCompletionDates[key] = dates
        }
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
        let didMutateSession = upsertMerged(summary.session, preserveNewerLifecycle: true)
        let didMutateAttention = applyListAttentionCounts(from: [summary])
        return didMutateSession || didMutateAttention
    }

    /// Insert or update several session summaries as a single store mutation.
    @discardableResult
    func upsertManySummaries(_ summaries: [SessionSummary]) -> Bool {
        var list = sessions
        var didMutateSessions = false
        for summary in summaries {
            didMutateSessions = merge(
                summary.session,
                into: &list,
                preserveNewerLifecycle: true
            ) || didMutateSessions
        }
        if didMutateSessions {
            setActiveSessionsPreservingListProjection(list)
        }
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
        applyRecentWorkspaceSummaries(
            workspaceIds: Set([workspaceId]),
            summaries: incomingSummaries,
            requestStartedAt: requestStartedAt,
            preserveRecentWindow: preserveRecentWindow
        )
    }

    /// Apply the authoritative recent workspace snapshot used by workspace detail.
    ///
    /// The detail refresh owns the focused workspace's hot backing partition, so
    /// missing rows can leave both the full store and list projection.
    @discardableResult
    func applyRecentWorkspaceSummaries(
        workspaceIds: Set<String>,
        summaries incomingSummaries: [SessionSummary],
        requestStartedAt: Date = Date(),
        preserveRecentWindow: TimeInterval = 180
    ) -> Bool {
        let targetWorkspaceIds = workspaceIds.filter { !$0.isEmpty }
        guard !targetWorkspaceIds.isEmpty else { return upsertManySummaries(incomingSummaries) }

        let current = sessions
        let incomingForWorkspaces = normalizedRecentWorkspaceSessions(
            targetWorkspaceIds: targetWorkspaceIds,
            summaries: incomingSummaries
        )
        let next = recentWorkspaceSnapshot(
            current: current,
            targetWorkspaceIds: targetWorkspaceIds,
            incomingForWorkspaces: incomingForWorkspaces,
            requestStartedAt: requestStartedAt,
            preserveRecentWindow: preserveRecentWindow,
            keepUntargetedRows: true
        )
        let didMutateAttention = applyListAttentionCounts(
            from: incomingSummaries,
            replacingWorkspaceIds: targetWorkspaceIds
        )
        guard next != current else { return didMutateAttention }

        let nextIds = Set(next.map(\.id))
        let removedIds = Set(current.map(\.id)).subtracting(nextIds)
        let key = activeServerKey
        for removedId in removedIds {
            serverUnreadCompletionDates[key]?.removeValue(forKey: removedId)
        }
        if let activeSessionId, removedIds.contains(activeSessionId) {
            self.activeSessionId = nil
        }

        setActiveSessionsPreservingListProjection(next)
        return true
    }

    /// Apply the authoritative recent workspace snapshot used by workspace home.
    ///
    /// Home refreshes own the cold list projection, not every cached session in
    /// the backing store. Missing rows leave workspace lists, while direct
    /// navigation/cache-only sessions stay available for the active chat.
    @discardableResult
    func applyRecentWorkspaceSummaryProjection(
        workspaceIds: Set<String>,
        summaries incomingSummaries: [SessionSummary],
        requestStartedAt: Date = Date(),
        preserveRecentWindow: TimeInterval = 180
    ) -> Bool {
        let targetWorkspaceIds = workspaceIds.filter { !$0.isEmpty }

        let incomingForWorkspaces = normalizedRecentWorkspaceSessions(
            targetWorkspaceIds: targetWorkspaceIds,
            summaries: incomingSummaries
        )
        let incomingControlSessions = incomingSummaries.map(\.session).filter {
            $0.control != nil && $0.workspaceId == nil && !isDeletedSessionTombstoned($0.id)
        }

        var backing = sessions
        var didMutateBacking = false
        for session in incomingForWorkspaces + incomingControlSessions {
            didMutateBacking = merge(
                session,
                into: &backing,
                preserveNewerLifecycle: true
            ) || didMutateBacking
        }
        if didMutateBacking {
            serverSessions[activeServerKey] = backing
        }

        let currentProjection = listProjectionSessions
        var nextProjection = recentWorkspaceSnapshot(
            current: currentProjection,
            targetWorkspaceIds: targetWorkspaceIds,
            incomingForWorkspaces: incomingForWorkspaces,
            requestStartedAt: requestStartedAt,
            preserveRecentWindow: preserveRecentWindow,
            keepUntargetedRows: false
        )
        for session in incomingControlSessions {
            _ = merge(session, into: &nextProjection, preserveNewerLifecycle: true)
        }
        nextProjection.sort {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id < $1.id
        }
        let didMutateAttention = applyListAttentionCounts(
            from: incomingSummaries,
            replacingWorkspaceIds: targetWorkspaceIds
        )

        if nextProjection != currentProjection {
            serverListProjectionSessions[activeServerKey] = nextProjection
        }

        let didPruneAttention = pruneListAttentionCounts(
            key: activeServerKey,
            keepingSessionIds: Set(nextProjection.map(\.id))
        )
        return didMutateBacking || didMutateAttention || didPruneAttention || nextProjection != currentProjection
    }

    private func normalizedRecentWorkspaceSessions(
        targetWorkspaceIds: Set<String>,
        summaries incomingSummaries: [SessionSummary]
    ) -> [Session] {
        let singleWorkspaceId = targetWorkspaceIds.count == 1 ? targetWorkspaceIds.first : nil
        return incomingSummaries.map(\.session).compactMap { session -> Session? in
            guard !isDeletedSessionTombstoned(session.id) else { return nil }
            var normalized = session
            if normalized.workspaceId == nil, let singleWorkspaceId {
                normalized.workspaceId = singleWorkspaceId
            }
            guard let workspaceId = normalized.workspaceId,
                  targetWorkspaceIds.contains(workspaceId) else { return nil }
            return normalized
        }
    }

    private func recentWorkspaceSnapshot(
        current: [Session],
        targetWorkspaceIds: Set<String>,
        incomingForWorkspaces: [Session],
        requestStartedAt: Date,
        preserveRecentWindow: TimeInterval,
        keepUntargetedRows: Bool
    ) -> [Session] {
        var incomingById: [String: Session] = [:]
        var incomingOrder: [String] = []
        for session in incomingForWorkspaces {
            if incomingById[session.id] == nil {
                incomingOrder.append(session.id)
            }
            incomingById[session.id] = session
        }

        let incomingIds = Set(incomingById.keys)
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var nextById: [String: Session] = [:]

        for existing in current {
            guard let workspaceId = existing.workspaceId,
                  targetWorkspaceIds.contains(workspaceId) else {
                if keepUntargetedRows {
                    nextById[existing.id] = existing
                }
                continue
            }

            if incomingIds.contains(existing.id) {
                continue
            }

            if shouldPreserveMissingWorkspaceRecentRow(
                existing,
                requestStartedAt: requestStartedAt,
                preserveRecentWindow: preserveRecentWindow
            ) {
                nextById[existing.id] = existing
            }
        }

        for incomingId in incomingOrder {
            guard let incomingSession = incomingById[incomingId] else { continue }
            if let existing = currentById[incomingSession.id] {
                var merged = mergePreservingContext(
                    existing: existing,
                    incoming: incomingSession
                )
                if existing.lastActivity > incomingSession.lastActivity {
                    merged.status = existing.status
                    merged.currentTurnStartedAt = existing.currentTurnStartedAt
                    merged.lastActivity = existing.lastActivity
                }
                nextById[incomingSession.id] = merged
            } else {
                nextById[incomingSession.id] = incomingSession
            }
        }

        return nextById.values.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.id < rhs.id
        }
    }

    @discardableResult
    private func applyListAttentionCounts(
        from summaries: [SessionSummary],
        replacingWorkspaceId workspaceId: String? = nil
    ) -> Bool {
        applyListAttentionCounts(
            from: summaries,
            replacingWorkspaceIds: workspaceId.map { Set([$0]) }
        )
    }

    private func applyListAttentionCounts(
        from summaries: [SessionSummary],
        replacingWorkspaceIds workspaceIds: Set<String>?
    ) -> Bool {
        let key = activeServerKey
        var counts = serverListAttentionCounts[key] ?? [:]
        let original = counts

        if let workspaceIds {
            for session in listProjectionSessions where session.workspaceId.map({ workspaceIds.contains($0) }) == true {
                counts.removeValue(forKey: session.id)
            }
        }

        for summary in summaries {
            guard !isDeletedSessionTombstoned(summary.id) else { continue }
            guard summary.hasPendingAskCount else { continue }
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

    private func upsertMerged(_ session: Session, preserveNewerLifecycle: Bool = false) -> Bool {
        var list = sessions
        guard merge(session, into: &list, preserveNewerLifecycle: preserveNewerLifecycle) else { return false }
        setActiveSessionsPreservingListProjection(list)
        return true
    }

    private func merge(
        _ session: Session,
        into list: inout [Session],
        preserveNewerLifecycle: Bool = false
    ) -> Bool {
        guard !isDeletedSessionTombstoned(session.id) else { return false }

        if let idx = list.firstIndex(where: { $0.id == session.id }) {
            var merged = mergePreservingContext(existing: list[idx], incoming: session)
            if preserveNewerLifecycle, list[idx].lastActivity > session.lastActivity {
                merged.status = list[idx].status
                merged.currentTurnStartedAt = list[idx].currentTurnStartedAt
                merged.lastActivity = list[idx].lastActivity
            }
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

    @discardableResult
    private func pruneListAttentionCounts(key: String, keepingSessionIds ids: Set<String>) -> Bool {
        guard let current = serverListAttentionCounts[key] else { return false }
        let next = current.filter { ids.contains($0.key) }
        guard next != current else { return false }
        if next.isEmpty {
            serverListAttentionCounts.removeValue(forKey: key)
        } else {
            serverListAttentionCounts[key] = next
        }
        return true
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
        preserveRecentWindow: TimeInterval
    ) -> Bool {
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
        if merged.control == nil {
            merged.control = existing.control
        }
        if let incomingLaunch = merged.launch {
            merged.launch = SessionLaunchMetadata(
                agentId: incomingLaunch.agentId ?? existing.launch?.agentId,
                agentIcon: incomingLaunch.agentIcon ?? existing.launch?.agentIcon
            )
        } else {
            merged.launch = existing.launch
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
        serverUnreadCompletionDates[key]?.removeValue(forKey: id)
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
