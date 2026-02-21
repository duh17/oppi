import Foundation
import os.log

private let log = Logger(subsystem: AppIdentifiers.subsystem, category: "ChatSession")

/// Owns connection lifecycle, history loading, and state reconciliation for a chat session.
///
/// Extracted from ChatView to keep the view focused on composition.
/// Uses structured concurrency — the caller drives the connection loop
/// via `connect()`, which runs until cancelled or disconnected.
@MainActor @Observable
final class ChatSessionManager {
    private struct TraceSignature: Equatable {
        let eventCount: Int
        let lastEventId: String?
    }

    private enum CatchUpOutcome {
        case noGap
        case applied
        case fullReloadScheduled
    }

    let sessionId: String

    /// Bumped to restart the `.task(id:)` connection loop.
    private(set) var connectionGeneration = 0

    /// True once `onAppear` has fired at least once.
    private(set) var hasAppeared = false

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

    /// Set from restored scroll state — one-shot, consumed after first use.
    /// When non-nil, the chat scrolls to this item instead of the bottom.
    var restorationScrollItemId: String?

    private var reconcileTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var stateSyncTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?
    private var latestTraceSignature: TraceSignature?

    private var unexpectedStreamExitCount = 0
    private var wantsAutoReconnect = true
    private var lastSeenSeq: Int

    private var snapshotFlushInFlight = false
    private var lastSnapshotFlushAt: Date?

    /// Freshness metadata for chat timeline sync.
    private(set) var lastSuccessfulSyncAt: Date?
    private(set) var isSyncing = false
    private(set) var lastSyncFailed = false

    /// Test seam: inject a scripted stream to exercise lifecycle races
    /// without opening a real WebSocket.
    var _streamSessionForTesting: ((String) -> AsyncStream<ServerMessage>?)?

    /// Test seam: override history loading to validate reconnect behavior
    /// without performing REST requests.
    var _loadHistoryForTesting: ((_ cachedEventCount: Int?, _ cachedLastEventId: String?) async -> (eventCount: Int, lastEventId: String?)?)?

    /// Test seam: override event catch-up loading
    /// (`/workspaces/:workspaceId/sessions/:id/events?since=`).
    var _loadCatchUpForTesting: ((_ since: Int, _ currentSeq: Int) async -> APIClient.SessionEventsResponse?)?

    /// Test seam: inject inbound sequence metadata per streamed message.
    var _consumeInboundMetaForTesting: (() -> WebSocketClient.InboundMeta?)?

    /// Test seam: override trace fetch for lifecycle snapshot flush.
    var _fetchTraceSnapshotForTesting: (() async -> [TraceEvent]?)?

    /// Test seam: override session trace fetch used by loadHistory.
    /// Lets tests exercise real history-apply logic without network.
    var _fetchSessionTraceForTesting: ((_ workspaceId: String, _ sessionId: String) async throws -> (Session, [TraceEvent]))?

    /// Test seam: override trace save destination for lifecycle snapshot flush.
    var _saveTraceSnapshotForTesting: (([TraceEvent]) async -> Void)?

    init(sessionId: String) {
        self.sessionId = sessionId
        self.lastSeenSeq = Self.loadLastSeenSeq(sessionId: sessionId)
    }

    private static func reconnectDelay(for attempt: Int) -> (duration: Duration, delayMs: Int) {
        switch attempt {
        case 1: (.milliseconds(250), 250)
        case 2: (.milliseconds(750), 750)
        case 3: (.seconds(2), 2_000)
        default: (.seconds(4), 4_000)
        }
    }

    private static let snapshotFlushMinInterval: TimeInterval = 10

    private static func seqDefaultsKey(sessionId: String) -> String {
        "chat.lastSeenSeq.\(sessionId)"
    }

    private static func loadLastSeenSeq(sessionId: String) -> Int {
        UserDefaults.standard.integer(forKey: seqDefaultsKey(sessionId: sessionId))
    }

    private func persistLastSeenSeq() {
        UserDefaults.standard.set(lastSeenSeq, forKey: Self.seqDefaultsKey(sessionId: sessionId))
    }

    private func updateLastSeenSeq(_ seq: Int) {
        guard seq > lastSeenSeq else { return }
        lastSeenSeq = seq
        persistLastSeenSeq()
    }

    private func resolveWorkspaceId(from sessionStore: SessionStore) -> String? {
        if let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId,
           !workspaceId.isEmpty {
            return workspaceId
        }

        if let workspaceId = sessionStore.activeSession?.workspaceId,
           !workspaceId.isEmpty {
            return workspaceId
        }

        return nil
    }

    private func openSessionStream(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) -> AsyncStream<ServerMessage>? {
        if let streamForTesting = _streamSessionForTesting?(sessionId) {
            connection._setActiveSessionIdForTesting(sessionId)
            return streamForTesting
        }

        guard let workspaceId = resolveWorkspaceId(from: sessionStore) else { return nil }
        return connection.streamSession(sessionId, workspaceId: workspaceId)
    }

    private func markSyncStarted() {
        isSyncing = true
    }

    private func markSyncSucceeded(at date: Date = Date()) {
        isSyncing = false
        lastSyncFailed = false
        lastSuccessfulSyncAt = date
    }

    private func markSyncFailed() {
        isSyncing = false
        lastSyncFailed = true
    }

    // MARK: - Lifecycle

    func markAppeared() {
        wantsAutoReconnect = true
        if hasAppeared {
            connectionGeneration &+= 1
        } else {
            hasAppeared = true
        }
    }

    func reconnect() {
        cancelAutoReconnect()
        connectionGeneration &+= 1
    }

    /// Main connection loop — runs until cancelled.
    ///
    /// Opens the WebSocket stream, loads cached history immediately for
    /// instant UI, then refreshes from server in background. Processes
    /// live events until the stream ends or the task is cancelled.
    ///
    /// **Stopped sessions**: If the session is stopped, loads cached + fresh
    /// history but does NOT open a WebSocket (which would auto-resume the
    /// pi process on the server). The user must explicitly resume via the
    /// "Resume" button in the footer.
    func connect(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore
    ) async {
        let generation = connectionGeneration
        let switchingSessions = sessionStore.activeSessionId != sessionId

        connection.disconnectSession()
        connection.fatalSetupError = false
        cancelAutoReconnect()
        cancelHistoryAndStateSync()
        if switchingSessions {
            reducer.reset()
        }

        sessionStore.activeSessionId = sessionId
        markSyncStarted()

        if ReleaseFeatures.liveActivitiesEnabled {
            let sessionName = sessionStore.sessions.first(where: { $0.id == sessionId })?.name ?? "Session"
            LiveActivityManager.shared.start(sessionId: sessionId, sessionName: sessionName)
        }

        // Show cached timeline immediately (before network).
        let cached = await TimelineCache.shared.loadTrace(sessionId)
        if let cached {
            latestTraceSignature = TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId)
        } else {
            latestTraceSignature = nil
        }

        if let cached, !cached.events.isEmpty {
            reducer.loadSession(cached.events)
            let footprint = SentryService.currentFootprintMB()
            ClientLog.info("Memory", "Session loaded (cache)", metadata: [
                "footprintMB": footprint.map(String.init) ?? "n/a",
                "traceEvents": String(cached.events.count),
                "timelineItems": String(reducer.items.count),
                "sessionId": sessionId,
            ])

            // Check for scroll position restoration (one-shot from RestorationState).
            // If the user was scrolled up when the app backgrounded, attempt to restore
            // an anchor; otherwise start at the bottom.
            let savedAnchor = connection.scrollAnchorItemId
            let wasNearBottom = connection.scrollWasNearBottom
            connection.scrollAnchorItemId = nil

            if let savedAnchor,
               !wasNearBottom,
               connection.sessionStore.activeSessionId == sessionId {
                restorationScrollItemId = savedAnchor
                log.info("Restoring scroll to \(savedAnchor) for \(self.sessionId)")
            } else {
                needsInitialScroll = wasNearBottom
            }
            log.info("Loaded \(cached.eventCount) cached events for \(self.sessionId)")
        }

        // Stopped sessions: load fresh history but do NOT open a WebSocket.
        // Opening the WS would auto-resume the pi process on the server.
        // The user must explicitly tap "Resume" to restart the session.
        let sessionStatus = sessionStore.sessions.first(where: { $0.id == sessionId })?.status
        if sessionStatus == .stopped {
            log.info("Session \(self.sessionId) is stopped — loading history only (no WS)")
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedSignature: latestTraceSignature
            )
            // Wait for history to finish, then mark sync done
            return
        }

        guard let stream = openSessionStream(connection: connection, sessionStore: sessionStore) else {
            markSyncFailed()
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context"))
            return
        }

        // Fetch fresh history in background — only rebuilds if changed.
        scheduleHistoryReload(
            generation: generation,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            cachedSignature: latestTraceSignature
        )

        guard !Task.isCancelled else {
            cancelHistoryReload()
            cancelStateSync()
            disconnectIfCurrent(generation, connection: connection)
            return
        }

        // Wire silence watchdog → full reconnect
        let sid = sessionId
        connection.onSilenceReconnect = { [weak self] in
            log.error("Silence watchdog triggered reconnect for \(sid)")
            ClientLog.error("ChatSession", "Silence watchdog triggered reconnect", metadata: ["sessionId": sid])
            self?.reconnect()
        }

        var hasReceivedConnected = false
        for await message in stream {
            if Task.isCancelled {
                break
            }

            markSyncSucceeded()
            let inboundMeta = _consumeInboundMetaForTesting?() ?? connection.wsClient?.consumeInboundMeta(sessionId: sessionId)

            // Detect reconnection: a second `.connected` message means the WS
            // dropped and recovered. Prefer seq-based catch-up and only
            // fallback to full history reload when catch-up cannot guarantee
            // continuity.
            if case .connected = message {
                let catchUpOutcome: CatchUpOutcome?
                if let currentSeq = inboundMeta?.currentSeq {
                    catchUpOutcome = await performCatchUpIfNeeded(
                        currentSeq: currentSeq,
                        generation: generation,
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore
                    )
                } else {
                    catchUpOutcome = nil
                }

                // Request freshest server session state only once the stream is connected.
                // This avoids speculative pre-connect sends that can stall/fail during startup.
                scheduleStateSync(generation: generation, connection: connection)

                if hasReceivedConnected {
                    if let catchUpOutcome {
                        switch catchUpOutcome {
                        case .fullReloadScheduled:
                            log.info("WS reconnected — scheduled full history reload for \(self.sessionId)")
                        case .noGap, .applied:
                            log.info("WS reconnected — catch-up complete for \(self.sessionId), skipping full history reload")
                        }
                    } else {
                        log.warning("WS reconnected without currentSeq for \(self.sessionId) — falling back to full history reload")
                        scheduleHistoryReload(
                            generation: generation,
                            connection: connection,
                            reducer: reducer,
                            sessionStore: sessionStore,
                            cachedSignature: latestTraceSignature
                        )
                    }
                }
                hasReceivedConnected = true
                unexpectedStreamExitCount = 0
            }

            if let seq = inboundMeta?.seq {
                if seq <= lastSeenSeq {
                    continue
                }
                updateLastSeenSeq(seq)
            }

            connection.handleServerMessage(message, sessionId: sessionId)
        }

        let wasCancelled = Task.isCancelled

        let shouldAutoReconnect = !wasCancelled
            && hasReceivedConnected
            && generation == connectionGeneration
            && wantsAutoReconnect
            && !connection.fatalSetupError
            && sessionStore.sessions.first(where: { $0.id == sessionId })?.status != .stopped

        if shouldAutoReconnect {
            unexpectedStreamExitCount += 1
            let reconnectPolicy = Self.reconnectDelay(for: unexpectedStreamExitCount)
            if unexpectedStreamExitCount > 1 {
                log.error(
                    "PIPE: repeated stream exit for \(self.sessionId, privacy: .public) (attempt \(self.unexpectedStreamExitCount, privacy: .public)) — reconnect in \(reconnectPolicy.delayMs, privacy: .public)ms"
                )
                ClientLog.error(
                    "ChatSession",
                    "Repeated stream exit; scheduling reconnect",
                    metadata: [
                        "sessionId": sessionId,
                        "attempt": String(unexpectedStreamExitCount),
                        "delayMs": String(reconnectPolicy.delayMs),
                    ]
                )
            }
            reducer.appendSystemEvent("Connection dropped — reconnecting…")
            scheduleAutoReconnect(after: reconnectPolicy.duration, generation: generation)
        } else {
            unexpectedStreamExitCount = 0
            cancelAutoReconnect()
        }

        connection.onSilenceReconnect = nil
        cancelHistoryReload()
        cancelStateSync()
        disconnectIfCurrent(generation, connection: connection)
    }

    /// Reconcile session state from REST after a stop attempt times out.
    func reconcileAfterStop(connection: ServerConnection, sessionStore: SessionStore) {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }

            guard let api = connection.apiClient else { return }
            guard let workspaceId = self.resolveWorkspaceId(from: sessionStore) else {
                log.warning("Reconcile skipped for \(self.sessionId): missing workspaceId")
                return
            }

            do {
                let (session, _) = try await api.getSession(workspaceId: workspaceId, id: sessionId)
                sessionStore.upsert(session)
            } catch {
                log.warning("Reconcile failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelReconciliation() {
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    /// Flushes a fresh trace snapshot into the local cache.
    ///
    /// This narrows the stale-window for offline viewing by persisting
    /// near-current timeline state when lifecycle boundaries occur
    /// (background/disappear). Server remains source-of-truth.
    func flushSnapshotIfNeeded(connection: ServerConnection, force: Bool = false) async {
        if snapshotFlushInFlight {
            return
        }

        if !force,
           let lastSnapshotFlushAt,
           Date().timeIntervalSince(lastSnapshotFlushAt) < Self.snapshotFlushMinInterval {
            return
        }

        snapshotFlushInFlight = true
        defer { snapshotFlushInFlight = false }

        let trace: [TraceEvent]?
        if let fetchHook = _fetchTraceSnapshotForTesting {
            trace = await fetchHook()
        } else if let api = connection.apiClient {
            guard let workspaceId = resolveWorkspaceId(from: connection.sessionStore) else {
                log.debug("Snapshot flush skipped for \(self.sessionId): missing workspaceId")
                return
            }

            do {
                let (_, fetchedTrace) = try await api.getSession(
                    workspaceId: workspaceId,
                    id: sessionId,
                    traceView: .full
                )
                trace = fetchedTrace
            } catch {
                log.debug("Snapshot flush skipped for \(self.sessionId): \(error.localizedDescription)")
                return
            }
        } else {
            return
        }

        guard let trace, !trace.isEmpty else {
            return
        }

        if let saveHook = _saveTraceSnapshotForTesting {
            await saveHook(trace)
        } else {
            await TimelineCache.shared.saveTrace(sessionId, events: trace)
        }

        latestTraceSignature = TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)
        lastSnapshotFlushAt = Date()
    }

    func cleanup() {
        wantsAutoReconnect = false
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelAutoReconnect()
        cancelHistoryReload()
        cancelStateSync()
    }

    private func performCatchUpIfNeeded(
        currentSeq: Int,
        generation: Int,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore
    ) async -> CatchUpOutcome {
        guard generation == connectionGeneration else { return .noGap }

        if currentSeq < lastSeenSeq {
            log.warning("Connected currentSeq \(currentSeq) behind lastSeenSeq \(self.lastSeenSeq) — forcing full history reload")
            lastSeenSeq = currentSeq
            persistLastSeenSeq()
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            return .fullReloadScheduled
        }

        guard currentSeq > lastSeenSeq else { return .noGap }

        let since = lastSeenSeq
        let response: APIClient.SessionEventsResponse?
        if let catchUpHook = _loadCatchUpForTesting {
            response = await catchUpHook(since, currentSeq)
        } else if let api = connection.apiClient {
            if let workspaceId = resolveWorkspaceId(from: sessionStore) {
                response = try? await api.getSessionEvents(
                    workspaceId: workspaceId,
                    id: sessionId,
                    since: since
                )
            } else {
                log.warning("Catch-up skipped for \(self.sessionId): missing workspaceId")
                response = nil
            }
        } else {
            response = nil
        }

        guard generation == connectionGeneration else { return .noGap }
        guard let response else {
            markSyncFailed()
            log.warning("Catch-up fetch failed for \(self.sessionId) since seq \(since)")
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            return .fullReloadScheduled
        }

        sessionStore.upsert(response.session)
        markSyncSucceeded()

        if !response.catchUpComplete {
            log.warning("Catch-up ring miss for \(self.sessionId) since seq \(since) — forcing full history reload")
            lastSeenSeq = response.currentSeq
            persistLastSeenSeq()
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            return .fullReloadScheduled
        }

        var appliedCatchUp = false
        for event in response.events {
            guard event.seq > lastSeenSeq else { continue }
            connection.handleServerMessage(event.message, sessionId: sessionId)
            updateLastSeenSeq(event.seq)
            appliedCatchUp = true
        }

        if response.currentSeq > lastSeenSeq {
            updateLastSeenSeq(response.currentSeq)
            appliedCatchUp = true
        }

        return appliedCatchUp ? .applied : .noGap
    }

    // MARK: - History Loading

    /// Load session history from the JSONL trace.
    ///
    /// This is the only history path. The trace includes tool calls,
    /// thinking blocks, and structured output. The REST messages endpoint
    /// only has flat user/assistant text — no tools, no thinking — which
    /// produces a degraded view. Even a partial trace (from missing JSONLs)
    /// is better than REST because it preserves structure for the turns it has.
    ///
    /// When cached data was already loaded, compares `(eventCount, lastEventId)`
    /// to skip redundant `loadSession()` rebuilds.
    @discardableResult
    private func loadHistory(
        api: APIClient,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        cachedEventCount: Int?,
        cachedLastEventId: String?
    ) async -> TraceSignature? {
        guard let workspaceId = resolveWorkspaceId(from: sessionStore) else {
            markSyncFailed()
            log.warning("Trace fetch skipped for \(self.sessionId): missing workspaceId")
            return nil
        }

        do {
            let session: Session
            let trace: [TraceEvent]
            if let fetchHook = _fetchSessionTraceForTesting {
                (session, trace) = try await fetchHook(workspaceId, sessionId)
            } else {
                (session, trace) = try await api.getSession(
                    workspaceId: workspaceId,
                    id: sessionId,
                    traceView: .full
                )
            }

            guard !Task.isCancelled else { return nil }
            sessionStore.upsert(session)
            markSyncSucceeded()

            let freshSignature = TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)

            if !trace.isEmpty {
                // Skip rebuild if trace hasn't changed since cached version
                if let cachedCount = cachedEventCount,
                   cachedCount == freshSignature.eventCount,
                   cachedLastEventId == freshSignature.lastEventId {
                    log.info("Trace unchanged for \(self.sessionId) — skipping rebuild")
                } else {
                    // Avoid clobbering in-flight streaming rows (thinking/tool calls)
                    // with a stale trace snapshot while the session is still running.
                    let shouldDeferRebuild =
                        (session.status == .busy || session.status == .stopping)
                        && !reducer.items.isEmpty

                    if shouldDeferRebuild {
                        log.info("Trace refresh deferred for \(self.sessionId) while session is \(session.status.rawValue)")
                    } else {
                        reducer.loadSession(trace)
                        needsInitialScroll = true
                        let footprint = SentryService.currentFootprintMB()
                        log.info("Loaded \(trace.count) fresh trace events for \(self.sessionId) [footprint=\(footprint ?? -1)MB, items=\(reducer.items.count)]")
                        ClientLog.info("Memory", "Session loaded", metadata: [
                            "footprintMB": footprint.map(String.init) ?? "n/a",
                            "traceEvents": String(trace.count),
                            "timelineItems": String(reducer.items.count),
                            "sessionId": self.sessionId,
                        ])
                    }
                }
            }

            // Always update cache with fresh data
            Task.detached {
                await TimelineCache.shared.saveTrace(self.sessionId, events: trace)
            }

            return freshSignature
        } catch {
            guard !Task.isCancelled else { return nil }
            markSyncFailed()
            log.warning("Trace fetch failed for \(self.sessionId): \(error.localizedDescription)")
            return nil
        }
    }

    private func scheduleHistoryReload(
        generation: Int,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        cachedSignature: TraceSignature?
    ) {
        cancelHistoryReload()
        markSyncStarted()

        let cachedEventCount = cachedSignature?.eventCount
        let cachedLastEventId = cachedSignature?.lastEventId

        historyReloadTask = Task { @MainActor [weak self, weak connection] in
            guard let self else { return }
            guard generation == self.connectionGeneration else { return }

            if let loadHook = self._loadHistoryForTesting {
                let signature = await loadHook(cachedEventCount, cachedLastEventId)
                guard !Task.isCancelled else { return }
                guard generation == self.connectionGeneration else { return }
                if let signature {
                    self.latestTraceSignature = TraceSignature(
                        eventCount: signature.eventCount,
                        lastEventId: signature.lastEventId
                    )
                }
                return
            }

            guard let api = connection?.apiClient else { return }
            if let freshSignature = await self.loadHistory(
                api: api,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedEventCount: cachedEventCount,
                cachedLastEventId: cachedLastEventId
            ) {
                guard generation == self.connectionGeneration else { return }
                self.latestTraceSignature = freshSignature
            }
        }
    }

    private func scheduleStateSync(generation: Int, connection: ServerConnection) {
        cancelStateSync()

        stateSyncTask = Task { @MainActor [weak self, weak connection] in
            guard let self, let connection else { return }
            guard generation == self.connectionGeneration else { return }
            try? await connection.requestState()
        }
    }

    private func scheduleAutoReconnect(after delay: Duration, generation: Int) {
        cancelAutoReconnect()
        autoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.connectionGeneration else { return }
            self.reconnect()
        }
    }

    private func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
    }

    private func cancelHistoryAndStateSync() {
        cancelHistoryReload()
        cancelStateSync()
    }

    private func cancelStateSync() {
        stateSyncTask?.cancel()
        stateSyncTask = nil
    }

    private func cancelHistoryReload() {
        historyReloadTask?.cancel()
        historyReloadTask = nil
    }

    private func disconnectIfCurrent(_ generation: Int, connection: ServerConnection) {
        guard generation == connectionGeneration else { return }
        // Only disconnect if WE are still the active session.
        // Without this check, when session B takes over the WS,
        // session A's cleanup would kill session B's connection,
        // causing a connect/disconnect ping-pong loop.
        guard connection.activeSessionId == sessionId
              || connection.activeSessionId == nil else { return }
        connection.disconnectSession()
    }
}
