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
    struct TraceSignature: Equatable {
        let eventCount: Int
        let lastEventId: String?
    }

    enum DisconnectReason: Equatable {
        case cancelled
        case generationChanged
        case fatalError
        case streamEnded
    }

    enum SessionEntryState: Equatable {
        case idle
        case loadingCache
        case awaitingConnected(workspaceId: String)
        case streaming
        case stopped(historyLoaded: Bool)
        case disconnected(reason: DisconnectReason)
    }

    private enum CatchUpOutcome {
        case noGap
        case applied
        case fullReloadScheduled
    }

    let sessionId: String

    /// Per-session timeline pipeline — each ChatSessionManager owns its own
    /// reducer, coalescer, and correlator so parent/child sessions maintain
    /// independent timeline state across NavigationStack back-navigation.
    let reducer = TimelineReducer()
    let coalescer = DeltaCoalescer()
    let toolCallCorrelator = ToolCallCorrelator()

    /// Bumped to restart the `.task(id:)` connection loop.
    private(set) var connectionGeneration = 0

    /// True once `onAppear` has fired at least once.
    private(set) var hasAppeared = false

    private(set) var entryState: SessionEntryState = .idle

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

    private var reconcileTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var stateSyncTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?
    private var latestTraceSignature: TraceSignature?

    private var unexpectedStreamExitCount = 0
    private var wantsAutoReconnect = true
    private let telemetry = ChatSessionTelemetryTracker()

    private var hasConnectedBefore = false
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

        // Wire per-session coalescer → reducer pipeline.
        coalescer.onFlush = { [weak self] events in
            guard let self else { return }
            self.reducer.processBatch(events)
        }
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

    private func persistLastSeenSeq(_ seq: Int) {
        UserDefaults.standard.set(seq, forKey: Self.seqDefaultsKey(sessionId: sessionId))
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

    private func workspaceIdForState(from sessionStore: SessionStore) -> String {
        resolveWorkspaceId(from: sessionStore) ?? ""
    }

    private func transitionTo(_ newState: SessionEntryState) {
        let oldState = entryState
        guard oldState != newState else { return }

        log.debug("State transition for \(self.sessionId, privacy: .public): \(oldState.logDescription, privacy: .public) -> \(newState.logDescription, privacy: .public)")
        entryState = newState
    }

    private func openSessionStream(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> AsyncStream<ServerMessage>? {
        if let streamForTesting = _streamSessionForTesting?(sessionId) {
            connection._setActiveSessionIdForTesting(sessionId)
            return streamForTesting
        }

        guard let workspaceId = resolveWorkspaceId(from: sessionStore) else { return nil }
        return await connection.streamSession(sessionId, workspaceId: workspaceId)
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
        sessionStore: SessionStore
    ) async {
        let generation = connectionGeneration

        transitionTo(.idle)
        connection.focusSession(sessionId)
        connection.fatalSetupError = false
        connection.onPermissionResolved = { [weak self] id, outcome, tool, summary in
            self?.reducer.resolvePermission(id: id, outcome: outcome, tool: tool, summary: summary)
        }
        cancelAutoReconnect()
        cancelStateSync()
        reducer.reset()
        // Set session affinity after reset. ChatTimelineView gates rendering
        // on reducer.activeSessionId == view.sessionId — prevents a flash of
        // stale parent items during parent→child navigation. The previous
        // session's activeSessionId naturally blocks the new view's first
        // body evaluation; this line lifts the gate for subsequent renders.
        reducer.activeSessionId = sessionId
        coalescer.sessionId = sessionId
        toolCallCorrelator.reset()

        sessionStore.activeSessionId = sessionId
        ChatTimelinePerf.activeSessionId = sessionId
        telemetry.cancelTTFT()
        telemetry.startSessionLoad()
        markSyncStarted()

        let persistedLastSeenSeq = Self.loadLastSeenSeq(sessionId: sessionId)
        await connection.sessionStreamCoordinator.seedLastSeenSeq(
            sessionId: sessionId,
            value: persistedLastSeenSeq
        )

        // Measure stale-cache window: from session entry until first confirmed fresh content.
        telemetry.updateTransportPath(connection.transportPath)
        telemetry.beginFreshContentLagMeasurement(hadCache: false)

        let isReentry = hasConnectedBefore
        hasConnectedBefore = true

        latestTraceSignature = await loadCachedTimeline(
            sessionStore: sessionStore,
            isReentry: isReentry
        )

        // Stopped sessions: load fresh history but do NOT open a WebSocket.
        // Opening the WS would auto-resume the pi process on the server.
        // The user must explicitly tap "Resume" to restart the session.
        let sessionStatus = sessionStore.sessions.first(where: { $0.id == sessionId })?.status
        if sessionStatus == .stopped {
            transitionTo(.stopped(historyLoaded: false))
            log.info("Session \(self.sessionId) is stopped — loading history only (no WS)")
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                sessionStore: sessionStore,
                cachedSignature: latestTraceSignature
            )
            await historyReloadTask?.value
            transitionTo(.stopped(historyLoaded: true))
            return
        }

        let wsOpenStartMs = ChatSessionTelemetry.nowMs()
        guard let stream = await openSessionStream(connection: connection, sessionStore: sessionStore) else {
            markSyncFailed()
            transitionTo(.disconnected(reason: .fatalError))
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context"))
            return
        }

        // Always fetch fresh trace in background — independent of WS/catch-up.
        // Cache gives instant display; this gives ground truth.
        scheduleHistoryReload(
            generation: generation,
            connection: connection,
            sessionStore: sessionStore,
            cachedSignature: latestTraceSignature
        )

        transitionTo(.awaitingConnected(workspaceId: workspaceIdForState(from: sessionStore)))

        guard !Task.isCancelled else {
            transitionTo(.disconnected(reason: .cancelled))
            cancelStateSync()
            disconnectIfCurrent(generation, connection: connection)
            return
        }

        // Wire silence watchdog → full reconnect
        let sid = sessionId
        connection.silenceWatchdog.onReconnect = { [weak self] in
            log.error("Silence watchdog triggered reconnect for \(sid)")
            ClientLog.error("ChatSession", "Silence watchdog triggered reconnect", metadata: ["sessionId": sid])
            self?.reconnect()
        }

        var hasReceivedConnected = false
        for await message in stream {
            let inboundMeta = _consumeInboundMetaForTesting?() ?? connection.wsClient?.consumeInboundMeta(sessionId: sessionId)
            await handleStreamMessage(
                message,
                inboundMeta: inboundMeta,
                connection: connection,
                sessionStore: sessionStore,
                generation: generation,
                wsOpenStartMs: wsOpenStartMs,
                isReentry: isReentry,
                hasReceivedConnected: &hasReceivedConnected
            )
            if case .disconnected = entryState { break }
        }

        handleStreamEnded(
            hasReceivedConnected: hasReceivedConnected,
            generation: generation,
            connection: connection,
            sessionStore: sessionStore
        )
    }

    // MARK: - Connection Helpers

    /// Load and apply cached timeline data for instant display before network.
    ///
    /// Returns the cached trace signature if data was loaded, nil otherwise.
    /// Always loads cache when available — even on re-entry. Showing slightly
    /// stale cached content is strictly better than an empty timeline while
    /// the background trace fetch runs. The fresh trace replaces the cache
    /// data when it arrives (via `loadSession(preserveOrphans: false)`).
    private func loadCachedTimeline(
        sessionStore: SessionStore,
        isReentry: Bool
    ) async -> TraceSignature? {
        transitionTo(.loadingCache)

        let cacheLoadStartMs = ChatSessionTelemetry.nowMs()
        let cached = await TimelineCache.shared.loadTrace(sessionId)
        let cacheLoadDurationMs = max(0, ChatSessionTelemetry.nowMs() - cacheLoadStartMs)

        let signature: TraceSignature?
        if let cached {
            signature = TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId)
        } else {
            signature = nil
        }

        ChatSessionTelemetry.recordCacheLoad(
            durationMs: cacheLoadDurationMs,
            sessionId: sessionId,
            hit: cached != nil,
            eventCount: cached?.eventCount ?? 0
        )

        if let cached, !cached.events.isEmpty {
            telemetry.markCacheLoaded()

            // Skip cache load when the reducer already has items (same-session
            // re-entry). The live items are strictly more recent than the cache.
            // Loading a stale cache would trigger a full rebuild whose orphan
            // detection preserves user messages but drops their corresponding
            // assistant responses — producing a wall of user-only messages at
            // the bottom. The scheduled fresh trace load will reconcile properly.
            if reducer.items.isEmpty {
                let reducerLoadStartMs = ChatSessionTelemetry.nowMs()
                reducer.loadSession(cached.events)
                let reducerLoadDurationMs = max(0, ChatSessionTelemetry.nowMs() - reducerLoadStartMs)

                ChatSessionTelemetry.recordReducerLoad(
                    durationMs: reducerLoadDurationMs,
                    sessionId: sessionId,
                    source: "cache",
                    eventCount: cached.eventCount,
                    itemCount: reducer.items.count
                )

                let footprint = SentryService.currentFootprintMB()
                ClientLog.info("Memory", "Session loaded (cache)", metadata: [
                    "footprintMB": footprint.map(String.init) ?? "n/a",
                    "traceEvents": String(cached.events.count),
                    "timelineItems": String(reducer.items.count),
                    "sessionId": sessionId,
                ])

                log.info("Loaded \(cached.eventCount) cached events for \(self.sessionId)")
            } else {
                log.info("Skipped cache load — reducer has \(self.reducer.items.count) live items for \(self.sessionId)")
            }

            needsInitialScroll = true
            telemetry.recordSessionLoadIfNeeded(
                path: "cache_hit",
                itemCount: reducer.items.count,
                sessionId: sessionId,
                workspaceId: resolveWorkspaceId(from: sessionStore)
            )
        }

        return signature
    }

    /// Process a single message from the WebSocket stream.
    ///
    /// Transitions to `.disconnected` on generation change or cancellation;
    /// the caller breaks the stream loop when it detects that state.
    private func handleStreamMessage(
        _ message: ServerMessage,
        inboundMeta: WebSocketClient.InboundMeta?,
        connection: ServerConnection,
        sessionStore: SessionStore,
        generation: Int,
        wsOpenStartMs: Int64,
        isReentry: Bool,
        hasReceivedConnected: inout Bool
    ) async {
        if generation != connectionGeneration {
            transitionTo(.disconnected(reason: .generationChanged))
            return
        }

        if Task.isCancelled {
            transitionTo(.disconnected(reason: .cancelled))
            return
        }

        markSyncSucceeded()
        telemetry.updateTransportPath(connection.transportPath)

        switch entryState {
        case .awaitingConnected:
            if case .connected = message {
                let transportTag = connection.transportPath.rawValue

                if let receivedAtMs = inboundMeta?.receivedAtMs {
                    let dispatchLagMs = max(0, ChatSessionTelemetry.nowMs() - receivedAtMs)
                    ChatSessionTelemetry.recordConnectedDispatchLag(
                        lagMs: dispatchLagMs,
                        sessionId: sessionId,
                        transport: transportTag
                    )

                    if dispatchLagMs >= 1_000 {
                        ClientLog.error(
                            "WebSocket",
                            "Connected message dispatch lag",
                            metadata: [
                                "sessionId": sessionId,
                                "transport": transportTag,
                                "lagMs": String(dispatchLagMs),
                            ]
                        )
                    }
                }

                // Record time from WS open to first .connected message.
                if !hasReceivedConnected {
                    let wsConnectDurationMs = max(0, ChatSessionTelemetry.nowMs() - wsOpenStartMs)
                    ChatSessionTelemetry.recordWsConnect(
                        durationMs: wsConnectDurationMs,
                        sessionId: sessionId,
                        transport: transportTag
                    )
                }

                // Seed seq tracking from the server's current position.
                // History reload runs independently — no catch-up interaction.
                if let currentSeq = inboundMeta?.currentSeq {
                    await connection.sessionStreamCoordinator.seedLastSeenSeq(
                        sessionId: sessionId,
                        value: currentSeq
                    )
                    persistLastSeenSeq(currentSeq)
                    log.info("First connect: seeded seq=\(currentSeq) for \(self.sessionId)")
                }

                // Request freshest server session state only once the stream is connected.
                // This avoids speculative pre-connect sends that can stall/fail during startup.
                scheduleStateSync(generation: generation, connection: connection)

                hasReceivedConnected = true
                unexpectedStreamExitCount = 0
                transitionTo(.streaming)

                // Start replay buffering if the session is busy and we have a
                // pending trace rebuild (from cache or re-entry). This captures
                // live WS events so they survive the loadHistory() rebuild.
                let sessionIsBusy = sessionStore.sessions.first(where: { $0.id == self.sessionId })?.status == .busy
                    || sessionStore.sessions.first(where: { $0.id == self.sessionId })?.status == .stopping
                if sessionIsBusy, telemetry.loadedFromCacheAtConnect || isReentry {
                    reducer.startReplayBuffer()
                }
            }

        case .streaming:
            // Detect reconnection: a second `.connected` message means the WS
            // dropped and recovered. Use ring catch-up to fill the gap;
            // fall back to full history reload on ring miss.
            if case .connected = message {
                if let currentSeq = inboundMeta?.currentSeq {
                    let outcome = await performCatchUpIfNeeded(
                        currentSeq: currentSeq,
                        generation: generation,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                    switch outcome {
                    case .noGap:
                        log.info("WS reconnected — no gap for \(self.sessionId)")
                    case .applied:
                        log.info("WS reconnected — catch-up applied for \(self.sessionId)")
                    case .fullReloadScheduled:
                        log.info("WS reconnected — full history reload scheduled for \(self.sessionId)")
                    }
                    telemetry.recordFreshContentLagIfNeeded(reason: "reconnect_\(outcome)", sessionId: sessionId)
                } else {
                    log.warning("WS reconnected without currentSeq for \(self.sessionId) — falling back to full history reload")
                    scheduleHistoryReload(
                        generation: generation,
                        connection: connection,
                        sessionStore: sessionStore,
                        cachedSignature: latestTraceSignature
                    )
                }
                scheduleStateSync(generation: generation, connection: connection)
                hasReceivedConnected = true
                unexpectedStreamExitCount = 0
            }

            if let seq = inboundMeta?.seq {
                let accepted = await connection.sessionStreamCoordinator.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: seq
                )
                guard accepted else { return }

                telemetry.recordFreshContentLagIfNeeded(reason: "stream_seq", sessionId: sessionId)
                let updatedSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
                persistLastSeenSeq(updatedSeq)
            }

            if case .turnAck(let command, _, let stage, _, _) = message,
               stage == .dispatched,
               command == "prompt" || command == "steer" || command == "follow_up" {
                telemetry.startTTFT(modelTags: ChatSessionTelemetryTracker.modelTags(from: sessionStore, sessionId: sessionId))
            }

            if case .agentEnd = message {
                telemetry.cancelTTFT()
            }

            telemetry.completeTTFTIfNeeded(signal: message, sessionId: sessionId)

        case .idle, .loadingCache, .stopped, .disconnected:
            log.warning("Received message in invalid state: \(self.entryState.logDescription, privacy: .public)")
        }

        let storeResult = connection.applySharedStoreUpdate(for: message, sessionId: sessionId)
        routeToTimeline(message, connection: connection, storeResult: storeResult)
        if connection.activeSessionId == sessionId {
            connection.handleActiveSessionUI(message, sessionId: sessionId)
        }
    }

    /// Handle post-stream cleanup: state transition, auto-reconnect, and teardown.
    private func handleStreamEnded(
        hasReceivedConnected: Bool,
        generation: Int,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) {
        if Task.isCancelled {
            transitionTo(.disconnected(reason: .cancelled))
        } else {
            switch entryState {
            case .disconnected(reason: .cancelled), .disconnected(reason: .generationChanged):
                break
            default:
                transitionTo(.disconnected(reason: .streamEnded))
            }
        }

        let shouldAutoReconnect: Bool
        switch entryState {
        case .disconnected(reason: .streamEnded):
            // Don't reconnect if another session has taken over the active slot.
            // During parent→child→parent navigation, the parent's connect() breaks
            // the child's stream. Without this check, the child schedules an
            // auto-reconnect that races with the parent's connect(), creating a
            // ping-pong where both sessions fight over reducer.activeSessionId.
            let anotherSessionTookOver = sessionStore.activeSessionId != sessionId
                && sessionStore.activeSessionId != nil
            shouldAutoReconnect = hasReceivedConnected
                && generation == connectionGeneration
                && wantsAutoReconnect
                && !connection.fatalSetupError
                && !anotherSessionTookOver
                && sessionStore.sessions.first(where: { $0.id == sessionId })?.status != .stopped
        default:
            shouldAutoReconnect = false
        }

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

        // Emit jank rate for this session before cleanup.
        ChatTimelinePerf.emitJankRate(sessionId: sessionId, phase: "session_end")

        connection.silenceWatchdog.onReconnect = nil
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
        coalescer.flushNow()
        transitionTo(.disconnected(reason: .cancelled))
        cancelStateSync()
    }

    // MARK: - Per-Session Timeline Routing

    /// Route a server message to the per-session timeline pipeline.
    ///
    /// This handles all coalescer/reducer mutations that were previously in
    /// `ServerConnection.handleServerMessage`. Each ChatSessionManager owns
    /// its own coalescer + reducer, so parent/child sessions maintain
    /// independent timelines across NavigationStack navigation.
    private func routeToTimeline(_ message: ServerMessage, connection: ServerConnection, storeResult: ServerConnection.StoreUpdateResult = .notHandled) {
        switch message {
        case .agentStart:
            coalescer.receive(.agentStart(sessionId: sessionId))

        case .agentEnd:
            coalescer.receive(.agentEnd(sessionId: sessionId))

        case .textDelta(let delta):
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))

        case .thinkingDelta(let delta):
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))

        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            coalescer.receive(toolCallCorrelator.start(
                sessionId: sessionId, tool: tool, args: args,
                toolCallId: toolCallId, callSegments: callSegments
            ))

        case .toolOutput(let output, let isError, let toolCallId, let mode, let truncated, let totalBytes):
            coalescer.receive(toolCallCorrelator.output(
                sessionId: sessionId, output: output, isError: isError,
                toolCallId: toolCallId, mode: mode,
                truncated: truncated, totalBytes: totalBytes
            ))

        case .toolEnd(_, let toolCallId, let details, let isError, let resultSegments):
            coalescer.receive(toolCallCorrelator.end(
                sessionId: sessionId, toolCallId: toolCallId,
                details: details, isError: isError,
                resultSegments: resultSegments
            ))

        case .messageEnd(let role, let content):
            if role == "assistant" {
                coalescer.receive(.messageEnd(sessionId: sessionId, content: content))
            } else if role == "user", !content.isEmpty {
                if !reducer.hasUserMessage(matching: content) {
                    reducer.appendUserMessage(content)
                }
            }

        case .error(let msg, let code, let fatal):
            // The missingFullSubscriptionErrorCode path stays on connection
            // (handled in handleActiveSessionUI). Only route non-recovery errors.
            let isMissingSubscription = code == ServerConnection.missingFullSubscriptionErrorCode
                || (code == nil && msg.contains("is not subscribed at level=full"))
            if !isMissingSubscription {
                coalescer.receive(.error(sessionId: sessionId, message: msg))
            }
            // Fatal setup errors — propagate to connection for auto-reconnect suppression.
            if fatal {
                connection.fatalSetupError = true
            }

        case .sessionEnded(let reason):
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))

        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))

        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            coalescer.receive(.compactionEnd(
                sessionId: sessionId, aborted: aborted,
                willRetry: willRetry, summary: summary,
                tokensBefore: tokensBefore
            ))

        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(
                sessionId: sessionId, attempt: attempt,
                maxAttempts: maxAttempts, delayMs: delayMs,
                errorMessage: errorMessage
            ))

        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(
                sessionId: sessionId, success: success,
                attempt: attempt, finalError: finalError
            ))

        case .commandResult(let command, let requestId, let success, let data, let error):
            let consumed = connection.handleCommandResult(
                command: command, requestId: requestId,
                success: success, data: data, error: error,
                sessionId: sessionId
            )
            if !consumed {
                coalescer.receive(.commandResult(
                    sessionId: sessionId, command: command,
                    requestId: requestId, success: success,
                    data: data, error: error
                ))
            }

        case .permissionExpired(let id, _):
            if let request = storeResult.takenPermission {
                reducer.resolvePermission(
                    id: id, outcome: .expired,
                    tool: request.tool, summary: request.displaySummary
                )
            }
            coalescer.receive(.permissionExpired(id: id))

        case .permissionCancelled(let id):
            if let request = storeResult.takenPermission {
                reducer.resolvePermission(
                    id: id, outcome: .cancelled,
                    tool: request.tool, summary: request.displaySummary
                )
            }

        case .permissionRequest(let perm):
            coalescer.receive(.permissionRequest(perm))

        case .queueItemStarted(_, let item, _):
            reducer.appendUserMessage(item.message, images: item.images ?? [])

        case .stopRequested(_, let reason):
            reducer.appendSystemEvent(reason ?? "Stopping…")

        case .stopConfirmed(_, let reason):
            coalescer.receive(.agentEnd(sessionId: sessionId))
            reducer.appendSystemEvent(reason ?? "Stop confirmed")

        case .stopFailed(_, let reason):
            reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))

        case .state(let session):
            // Recovery hardening: if server state says the session is no longer
            // running but we never observed agentEnd/messageEnd, finalize artifacts.
            let previousStatus = connection.sessionStore.sessions.first(where: { $0.id == session.id })?.status
            if let previousStatus,
               previousStatus == .busy || previousStatus == .stopping,
               session.status == .ready || session.status == .stopped || session.status == .error {
                coalescer.receive(.agentEnd(sessionId: session.id))
            }

        default:
            break
        }
    }

    /// Ring buffer catch-up for WS reconnection only.
    ///
    /// Fills the gap in live events between the last seen seq and the
    /// server's current seq. Falls back to a full history reload when
    /// the ring can't serve the gap (ring miss, regression, fetch failure).
    ///
    /// This is NOT used on first connect — first connect seeds the seq
    /// directly and relies on the independent history reload for content.
    private func performCatchUpIfNeeded(
        currentSeq: Int,
        generation: Int,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> CatchUpOutcome {
        guard generation == connectionGeneration else { return .noGap }

        let catchupStartMs = ChatSessionTelemetry.nowMs()

        let recordCatchupMs = { (result: String) in
            let durationMs = max(0, ChatSessionTelemetry.nowMs() - catchupStartMs)
            ChatSessionTelemetry.recordCatchup(durationMs: durationMs, sessionId: self.sessionId, result: result)
        }

        let decision = await connection.sessionStreamCoordinator.catchUpDecision(
            sessionId: sessionId,
            currentSeq: currentSeq
        )

        switch decision {
        case .seqRegression(let resetTo):
            log.warning("Seq regression for \(self.sessionId): currentSeq=\(currentSeq) — scheduling history reload")
            persistLastSeenSeq(resetTo)
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            recordCatchupMs("seq_regression")
            return .fullReloadScheduled

        case .noGap:
            recordCatchupMs("no_gap")
            return .noGap

        case .fetchSince(let since):
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
                log.warning("Catch-up fetch failed for \(self.sessionId) — scheduling history reload")
                scheduleHistoryReload(
                    generation: generation,
                    connection: connection,
                    sessionStore: sessionStore,
                    cachedSignature: nil
                )
                recordCatchupMs("fetch_failed")
                return .fullReloadScheduled
            }

            sessionStore.upsert(response.session)
            markSyncSucceeded()

            if !response.catchUpComplete {
                log.warning("Ring miss for \(self.sessionId) since seq \(since) — scheduling history reload")
                await connection.sessionStreamCoordinator.seedLastSeenSeq(
                    sessionId: sessionId,
                    value: response.currentSeq
                )
                persistLastSeenSeq(response.currentSeq)
                scheduleHistoryReload(
                    generation: generation,
                    connection: connection,
                    sessionStore: sessionStore,
                    cachedSignature: nil
                )
                ChatSessionTelemetry.recordCatchupRingMiss(sessionId: sessionId, missed: true)
                recordCatchupMs("ring_miss")
                return .fullReloadScheduled
            }

            ChatSessionTelemetry.recordCatchupRingMiss(sessionId: sessionId, missed: false)

            var appliedCatchUp = false
            for event in response.events {
                let accepted = await connection.sessionStreamCoordinator.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: event.seq
                )
                guard accepted else { continue }

                let eventStoreResult = connection.applySharedStoreUpdate(for: event.message, sessionId: sessionId)
                routeToTimeline(event.message, connection: connection, storeResult: eventStoreResult)
                if connection.activeSessionId == sessionId {
                    connection.handleActiveSessionUI(event.message, sessionId: sessionId)
                }
                appliedCatchUp = true
            }

            let trackedAfterEvents = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
            if response.currentSeq > trackedAfterEvents {
                await connection.sessionStreamCoordinator.applyCatchUpProgress(
                    sessionId: sessionId,
                    seq: response.currentSeq
                )
                appliedCatchUp = true
            }

            let persistedSeq = await connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
            persistLastSeenSeq(persistedSeq)

            recordCatchupMs(appliedCatchUp ? "applied" : "no_gap")
            return appliedCatchUp ? .applied : .noGap
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
        sessionStore: SessionStore,
        cachedEventCount: Int?,
        cachedLastEventId: String?
    ) async -> TraceSignature? {
        guard let workspaceId = resolveWorkspaceId(from: sessionStore) else {
            markSyncFailed()
            log.warning("Trace fetch skipped for \(self.sessionId): missing workspaceId")
            return nil
        }

        let loadStartedMs = ChatSessionTelemetry.nowMs()

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
            var freshnessReason = "history_empty"

            if !trace.isEmpty {
                // Skip rebuild if trace hasn't changed since cached version
                if let cachedCount = cachedEventCount,
                   cachedCount == freshSignature.eventCount,
                   cachedLastEventId == freshSignature.lastEventId {
                    log.info("Trace unchanged for \(self.sessionId) — skipping rebuild")
                    freshnessReason = "history_unchanged"
                } else {
                    // Apply the fresh trace. If live events arrived via WS during
                    // the fetch, the replay buffer preserves them and re-applies
                    // on top of the rebuilt timeline in a single @MainActor turn.
                    let usedReplay = reducer.isReplayBuffering
                    let reducerStartMs = ChatSessionTelemetry.nowMs()
                    if usedReplay {
                        reducer.applyTraceWithLiveReplay(trace)
                    } else {
                        // Fresh trace is authoritative — don't preserve orphans.
                        // Orphan detection creates "ghost" user messages at the
                        // bottom (no matching assistant response) when the trace
                        // lags behind locally-appended items.
                        reducer.loadSession(trace, preserveOrphans: false)
                    }
                    let reducerDurationMs = max(0, ChatSessionTelemetry.nowMs() - reducerStartMs)

                    ChatSessionTelemetry.recordReducerLoad(
                        durationMs: reducerDurationMs,
                        sessionId: self.sessionId,
                        source: usedReplay ? "history+replay" : "history",
                        eventCount: trace.count,
                        itemCount: reducer.items.count
                    )

                    needsInitialScroll = true
                    telemetry.recordSessionLoadIfNeeded(
                        path: usedReplay ? "full_reload" : "cache_miss",
                        itemCount: reducer.items.count,
                        sessionId: sessionId,
                        workspaceId: workspaceId
                    )
                    let footprint = SentryService.currentFootprintMB()
                    log.info("Loaded \(trace.count) fresh trace events for \(self.sessionId) [footprint=\(footprint ?? -1)MB, items=\(self.reducer.items.count), replay=\(usedReplay)]")
                    ClientLog.info("Memory", "Session loaded", metadata: [
                        "footprintMB": footprint.map(String.init) ?? "n/a",
                        "traceEvents": String(trace.count),
                        "timelineItems": String(self.reducer.items.count),
                        "sessionId": self.sessionId,
                        "replay": usedReplay ? "1" : "0",
                    ])
                    freshnessReason = usedReplay ? "history_replayed" : "history_applied"
                }
            }

            telemetry.recordFreshContentLagIfNeeded(reason: freshnessReason, sessionId: sessionId, workspaceId: workspaceId)

            // Always update cache with fresh data
            Task.detached {
                await TimelineCache.shared.saveTrace(self.sessionId, events: trace)
            }

            let durationMs = max(0, ChatSessionTelemetry.nowMs() - loadStartedMs)
            ChatSessionTelemetry.recordFullReload(
                durationMs: durationMs,
                sessionId: sessionId,
                workspaceId: workspaceId,
                traceEventCount: trace.count
            )

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
        guard connection.activeSessionId == sessionId
              || connection.activeSessionId == nil else { return }
        connection.disconnectSession()
    }
}

private extension ChatSessionManager.DisconnectReason {
    var logDescription: String {
        switch self {
        case .cancelled: "cancelled"
        case .generationChanged: "generation_changed"
        case .fatalError: "fatal_error"
        case .streamEnded: "stream_ended"
        }
    }
}

private extension ChatSessionManager.SessionEntryState {
    var logDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .loadingCache:
            return "loading_cache"
        case .awaitingConnected(let workspaceId):
            return "awaiting_connected(workspace=\(workspaceId))"
        case .streaming:
            return "streaming"
        case .stopped(let historyLoaded):
            return "stopped(history_loaded=\(historyLoaded ? "1" : "0"))"
        case .disconnected(let reason):
            return "disconnected(\(reason.logDescription))"
        }
    }
}
