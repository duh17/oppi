import Foundation
import os.log

private let log = Logger(subsystem: "dev.chenda.PiRemote", category: "ChatSession")

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

    let sessionId: String

    /// Bumped to restart the `.task(id:)` connection loop.
    private(set) var connectionGeneration = 0

    /// True once `onAppear` has fired at least once.
    private(set) var hasAppeared = false

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

    private var reconcileTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var stateSyncTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?
    private var latestTraceSignature: TraceSignature?

    private var unexpectedStreamExitCount = 0
    private var wantsAutoReconnect = true
    private var lastSeenSeq: Int

    /// Test seam: inject a scripted stream to exercise lifecycle races
    /// without opening a real WebSocket.
    var _streamSessionForTesting: ((String) -> AsyncStream<ServerMessage>?)?

    /// Test seam: override history loading to validate reconnect behavior
    /// without performing REST requests.
    var _loadHistoryForTesting: ((_ cachedEventCount: Int?, _ cachedLastEventId: String?) async -> (eventCount: Int, lastEventId: String?)?)?

    /// Test seam: override event catch-up loading (`/sessions/:id/events?since=`).
    var _loadCatchUpForTesting: ((_ since: Int, _ currentSeq: Int) async -> APIClient.SessionEventsResponse?)?

    /// Test seam: inject inbound sequence metadata per streamed message.
    var _consumeInboundMetaForTesting: (() -> WebSocketClient.InboundMeta?)?

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
        cancelHistoryReload()
        cancelStateSync()
        if switchingSessions {
            reducer.reset()
        }

        sessionStore.activeSessionId = sessionId

        let sessionName = sessionStore.sessions.first(where: { $0.id == sessionId })?.name ?? "Session"
        LiveActivityManager.shared.start(sessionId: sessionId, sessionName: sessionName)

        // Show cached timeline immediately (before network).
        let cached = await TimelineCache.shared.loadTrace(sessionId)
        if let cached {
            latestTraceSignature = TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId)
        } else {
            latestTraceSignature = nil
        }

        if let cached, !cached.events.isEmpty {
            reducer.loadSession(cached.events)
            needsInitialScroll = true
            log.info("Loaded \(cached.eventCount) cached events for \(self.sessionId)")
        }

        // Open WS stream first — server sends `connected` immediately.
        // Use workspace-scoped v2 path when the session has a workspaceId.
        let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId
        let stream: AsyncStream<ServerMessage>?
        if let streamForTesting = _streamSessionForTesting?(sessionId) {
            connection._setActiveSessionIdForTesting(sessionId)
            stream = streamForTesting
        } else {
            stream = connection.streamSession(sessionId, workspaceId: workspaceId)
        }

        guard let stream else {
            reducer.process(.error(sessionId: sessionId, message: "WebSocket unavailable"))
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
        log.error("PIPE: for-await loop starting for \(self.sessionId, privacy: .public)")
        ClientLog.info("ChatSession", "PIPE loop starting", metadata: ["sessionId": sessionId])
        for await message in stream {
            if Task.isCancelled {
                log.error("PIPE: task cancelled, breaking for-await loop")
                ClientLog.warning("ChatSession", "PIPE loop cancelled", metadata: ["sessionId": sessionId])
                break
            }

            let inboundMeta = _consumeInboundMetaForTesting?() ?? connection.wsClient?.consumeInboundMeta()

            // Detect reconnection: a second `.connected` message means the WS
            // dropped and recovered. Reload history to catch events lost during
            // the gap. Without this, agent responses sent while disconnected
            // never appear in the UI.
            if case .connected = message {
                if let currentSeq = inboundMeta?.currentSeq {
                    await performCatchUpIfNeeded(
                        currentSeq: currentSeq,
                        generation: generation,
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore
                    )
                }

                // Request freshest server session state only once the stream is connected.
                // This avoids speculative pre-connect sends that can stall/fail during startup.
                scheduleStateSync(generation: generation, connection: connection)

                if hasReceivedConnected {
                    log.info("WS reconnected — reloading history for \(self.sessionId)")
                    scheduleHistoryReload(
                        generation: generation,
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore,
                        cachedSignature: latestTraceSignature
                    )
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
        log.error("PIPE: stream loop EXITED for \(self.sessionId, privacy: .public) — cancelled=\(wasCancelled, privacy: .public)")
        ClientLog.error(
            "ChatSession",
            "PIPE stream loop exited",
            metadata: ["sessionId": sessionId, "cancelled": String(wasCancelled)]
        )

        let shouldAutoReconnect = !wasCancelled
            && hasReceivedConnected
            && generation == connectionGeneration
            && wantsAutoReconnect
            && !connection.fatalSetupError
            && sessionStore.sessions.first(where: { $0.id == sessionId })?.status != .stopped

        if shouldAutoReconnect {
            unexpectedStreamExitCount += 1
            let reconnectPolicy = Self.reconnectDelay(for: unexpectedStreamExitCount)
            log.error(
                "PIPE: unexpected stream exit for \(self.sessionId, privacy: .public) (attempt \(self.unexpectedStreamExitCount, privacy: .public)) — reconnect in \(reconnectPolicy.delayMs, privacy: .public)ms"
            )
            ClientLog.error(
                "ChatSession",
                "Unexpected stream exit; scheduling reconnect",
                metadata: [
                    "sessionId": sessionId,
                    "attempt": String(unexpectedStreamExitCount),
                    "delayMs": String(reconnectPolicy.delayMs),
                ]
            )
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
            do {
                let (session, _) = try await api.getSession(id: sessionId)
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
    ) async {
        guard generation == connectionGeneration else { return }

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
            return
        }

        guard currentSeq > lastSeenSeq else { return }

        let since = lastSeenSeq
        let response: APIClient.SessionEventsResponse?
        if let catchUpHook = _loadCatchUpForTesting {
            response = await catchUpHook(since, currentSeq)
        } else if let api = connection.apiClient {
            response = try? await api.getSessionEvents(id: sessionId, since: since)
        } else {
            response = nil
        }

        guard generation == connectionGeneration else { return }
        guard let response else {
            log.warning("Catch-up fetch failed for \(self.sessionId) since seq \(since)")
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            return
        }

        sessionStore.upsert(response.session)

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
            return
        }

        for event in response.events {
            guard event.seq > lastSeenSeq else { continue }
            connection.handleServerMessage(event.message, sessionId: sessionId)
            updateLastSeenSeq(event.seq)
        }

        if response.currentSeq > lastSeenSeq {
            updateLastSeenSeq(response.currentSeq)
        }
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
        do {
            let (session, trace) = try await api.getSession(id: sessionId)
            guard !Task.isCancelled else { return nil }
            sessionStore.upsert(session)

            let freshSignature = TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)

            if !trace.isEmpty {
                // Skip rebuild if trace hasn't changed since cached version
                if let cachedCount = cachedEventCount,
                   cachedCount == freshSignature.eventCount,
                   cachedLastEventId == freshSignature.lastEventId {
                    log.info("Trace unchanged for \(self.sessionId) — skipping rebuild")
                } else {
                    reducer.loadSession(trace)
                    needsInitialScroll = true
                    log.info("Loaded \(trace.count) fresh trace events for \(self.sessionId)")
                }
            }

            // Always update cache with fresh data
            Task.detached {
                await TimelineCache.shared.saveTrace(self.sessionId, events: trace)
            }

            return freshSignature
        } catch {
            guard !Task.isCancelled else { return nil }
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
        guard connection.wsClient?.connectedSessionId == sessionId
              || connection.wsClient?.connectedSessionId == nil else { return }
        connection.disconnectSession()
    }
}
