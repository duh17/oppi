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

    private enum SessionStreamInput {
        case events(AsyncStream<SessionStreamEvent>)
        case bareMessages(AsyncStream<ServerMessage>)
    }

    private enum FocusedStreamSetupDisposition {
        case bound(SessionStreamInput)
        case retryable
        case missingRoute
        case terminalUnavailable
    }

    private struct TraceHistorySnapshot {
        let session: Session
        let trace: [TraceEvent]
        let page: TracePageMetadata?
    }

    let sessionId: String

    /// Per-session timeline pipeline — each ChatSessionManager owns its own
    /// reducer, coalescer, and correlator so sessions maintain independent
    /// timeline state across NavigationStack back-navigation.
    let reducer = TimelineReducer(environment: .app())
    let coalescer = DeltaCoalescer(telemetry: .appMetrics)
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
    private var presentationReloadRetryTask: Task<Void, Never>?
    private var activeHistoryReplayID: UUID?
    private var stateSyncTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?
    private var latestTraceSignature: TraceSignature?

    private static let presentationReloadMaxAttempts = 3

    private var unexpectedStreamExitCount = 0
    private var wantsAutoReconnect = true
    private let telemetry = ChatSessionTelemetryTracker()

    private var snapshotFlushInFlight = false
    private var lastSnapshotFlushAt: Date?
    /// Navigation can arrive before the session summary is cached.
    /// Keep a workspace hint so history/stream setup does not fall back to an
    /// empty, missing-workspace timeline.
    private var workspaceIdHint: String?
    private let routeScopeHint: SessionRouteScope?

    /// Freshness metadata for chat timeline sync.
    private(set) var lastSuccessfulSyncAt: Date?
    private(set) var isSyncing = false
    private(set) var lastSyncFailed = false

    private(set) var tracePage: TracePageMetadata?
    private(set) var isLoadingOlderTracePage = false

    var hasOlderTracePage: Bool {
        reducer.canPrependTracePage && tracePage?.hasOlder == true && tracePage?.olderCursor != nil
    }

    /// Test seam: inject a scripted bare message stream to exercise lifecycle
    /// races without opening a real WebSocket. Production streams use
    /// `SessionStreamEvent` so metadata travels in-band.
    var _streamSessionForTesting: ((String) -> AsyncStream<ServerMessage>?)?

    /// Test seam: inject a scripted event stream with in-band metadata.
    var _streamEventsForTesting: ((String) -> AsyncStream<SessionStreamEvent>?)?

    /// Test seam: override history loading to validate reconnect behavior
    /// without performing REST requests.
    var _loadHistoryForTesting: ((_ cachedEventCount: Int?, _ cachedLastEventId: String?) async -> (eventCount: Int, lastEventId: String?)?)?

    /// Test seam: override event catch-up loading
    /// (`/workspaces/:workspaceId/sessions/:id/events?since=`).
    var _loadCatchUpForTesting: ((_ since: Int, _ currentSeq: Int) async -> APIClient.SessionEventsResponse?)?

    /// Test seam: attach inbound sequence metadata to `_streamSessionForTesting` events.
    var _consumeInboundMetaForTesting: (() -> WebSocketClient.InboundMeta?)?

    /// Test seam: override trace fetch for lifecycle snapshot flush.
    var _fetchTraceSnapshotForTesting: (() async -> [TraceEvent]?)?

    /// Test seam: override session trace fetch used by loadHistory.
    /// Lets tests exercise real history-apply logic without network.
    var _fetchSessionTraceForTesting: ((_ routeScope: SessionRouteScope, _ sessionId: String) async throws -> (Session, [TraceEvent]))?

    /// Test seam: override trace save destination for lifecycle snapshot flush.
    var _saveTraceSnapshotForTesting: (([TraceEvent]) async -> Void)?

#if DEBUG
    // periphery:ignore - shortens deterministic retry tests without changing
    // the bounded production policy.
    var _presentationReloadRetryDelayForTesting: Duration?
    var _focusedStreamSetupRetryDelayForTesting: Duration?
#endif

    init(
        sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        self.sessionId = sessionId
        let normalizedWorkspaceIdHint = workspaceIdHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkspaceIdHint = normalizedWorkspaceIdHint?.isEmpty == false
            ? normalizedWorkspaceIdHint
            : nil
        self.workspaceIdHint = resolvedWorkspaceIdHint
        self.routeScopeHint = routeScope
            ?? resolvedWorkspaceIdHint.map(SessionRouteScope.workspace)

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
    private static let tracePagePreviewBytes = 4096

    private static func firstMessageFallbackTraceEvent(for session: Session) -> TraceEvent? {
        guard let firstMessage = session.firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstMessage.isEmpty else {
            return nil
        }

        return TraceEvent(
            id: "session-\(session.id)-first-message-fallback",
            type: .user,
            timestamp: ISO8601DateFormatter().string(from: session.createdAt),
            text: firstMessage
        )
    }

    private static func timelineTrace(
        from trace: [TraceEvent],
        session: Session,
        allowFirstMessageFallback: Bool
    ) -> [TraceEvent] {
        if !trace.isEmpty || !allowFirstMessageFallback {
            return trace
        }

        guard let fallback = firstMessageFallbackTraceEvent(for: session) else {
            return trace
        }

        return [fallback]
    }

    private static func traceSignature(for trace: [TraceEvent]) -> TraceSignature {
        TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)
    }

    private static func seqDefaultsKey(sessionId: String) -> String {
        "chat.lastSeenSeq.\(sessionId)"
    }

    static func shouldFallbackToFullTrace(_ error: any Error) -> Bool {
        guard case APIError.server(let status, _) = error else { return false }
        return status == 404 || status == 405 || status == 409
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

        if let workspaceId = workspaceIdHint,
           !workspaceId.isEmpty {
            return workspaceId
        }

        return nil
    }

    private func resolveRouteScope(from sessionStore: SessionStore) -> SessionRouteScope? {
        if routeScopeHint == .control
            || sessionStore.session(id: sessionId)?.control != nil {
            return .control
        }
        if case .workspace(let workspaceId) = routeScopeHint,
           !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .workspace(workspaceId)
        }
        return resolveWorkspaceId(from: sessionStore).map(SessionRouteScope.workspace)
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
    ) async -> SessionStreamInput? {
        if let eventStreamForTesting = _streamEventsForTesting?(sessionId) {
            connection._setActiveSessionIdForTesting(sessionId)
            return .events(eventStreamForTesting)
        }

        if let streamForTesting = _streamSessionForTesting?(sessionId) {
            connection._setActiveSessionIdForTesting(sessionId)
            return .bareMessages(streamForTesting)
        }

        guard let routeScope = resolveRouteScope(from: sessionStore),
              let stream = await connection.streamSession(sessionId, routeScope: routeScope) else {
            return nil
        }
        return .events(stream)
    }

    private static let focusedStreamSetupMaxAttempts = 8

    private func bindFocusedSessionStream(
        generation: Int,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> SessionStreamInput? {
        var attempt = 0
        while true {
            if generation != connectionGeneration {
                clearFocusedStreamRecovery(on: connection)
                transitionTo(.disconnected(reason: .generationChanged))
                return nil
            }
            guard !Task.isCancelled else {
                clearFocusedStreamRecovery(on: connection)
                transitionTo(.disconnected(reason: .cancelled))
                return nil
            }

            switch await focusedStreamSetupDisposition(
                connection: connection,
                sessionStore: sessionStore
            ) {
            case .bound(let stream):
                clearFocusedStreamRecovery(on: connection)
                return stream
            case .missingRoute:
                failFocusedStreamSetup(
                    connection: connection,
                    message: "Missing session route context"
                )
                return nil
            case .terminalUnavailable:
                failFocusedStreamSetup(
                    connection: connection,
                    message: "Session stream unavailable"
                )
                return nil
            case .retryable:
                connection.setFocusedSessionStreamRecovering(true, sessionId: sessionId)
                if connection.externalSessionOpenClaimBlocks(sessionId) {
                    if await waitWhileExternalSessionOpenClaimBlocks(connection: connection) {
                        continue
                    }
                    clearFocusedStreamRecovery(on: connection)
                    transitionTo(.disconnected(reason: .cancelled))
                    return nil
                }
                attempt += 1
                if attempt >= Self.focusedStreamSetupMaxAttempts {
                    // Temporary unavailability exhausted its bind budget.
                    // Keep recovering and use the existing auto-reconnect loop
                    // instead of a fatal timeline row.
                    transitionTo(.disconnected(reason: .streamEnded))
                    scheduleAutoReconnect(
                        after: focusedStreamSetupRetryDelay(for: attempt),
                        generation: generation
                    )
                    return nil
                }
                if await waitForFocusedStreamSetupRetry(attempt: attempt) {
                    continue
                }
                clearFocusedStreamRecovery(on: connection)
                transitionTo(.disconnected(reason: .cancelled))
                return nil
            }
        }
    }

    private func focusedStreamSetupDisposition(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> FocusedStreamSetupDisposition {
        if let stream = await openSessionStream(connection: connection, sessionStore: sessionStore) {
            return .bound(stream)
        }
        if resolveRouteScope(from: sessionStore) == nil {
            return .missingRoute
        }
        if connection.isFocusedStreamBindTerminal() {
            return .terminalUnavailable
        }
        return .retryable
    }

    private func failFocusedStreamSetup(connection: ServerConnection, message: String) {
        clearFocusedStreamRecovery(on: connection)
        transitionTo(.disconnected(reason: .fatalError))
        if !suppressTimelineMutationWhilePaused() {
            reducer.process(.error(sessionId: sessionId, message: message))
        }
    }

    private func clearFocusedStreamRecovery(on connection: ServerConnection) {
        connection.setFocusedSessionStreamRecovering(false, sessionId: sessionId)
    }

    private func waitWhileExternalSessionOpenClaimBlocks(connection: ServerConnection) async -> Bool {
        while connection.externalSessionOpenClaimBlocks(sessionId) {
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func focusedStreamSetupRetryDelay(for attempt: Int) -> Duration {
#if DEBUG
        if let override = _focusedStreamSetupRetryDelayForTesting {
            return override
        }
#endif
        return Self.reconnectDelay(for: attempt).duration
    }

    private func waitForFocusedStreamSetupRetry(attempt: Int) async -> Bool {
        let delay = focusedStreamSetupRetryDelay(for: attempt)
        if delay <= .zero {
            await Task.yield()
            return !Task.isCancelled
        }
        do {
            try await Task.sleep(for: delay)
            return true
        } catch {
            return false
        }
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
            cancelPresentationReloadRetry()
            connectionGeneration &+= 1
        } else {
            hasAppeared = true
        }
    }

    func reconnect() {
        cancelAutoReconnect()
        cancelPresentationReloadRetry()
        connectionGeneration &+= 1
    }

    /// Rebuild the timeline after a paused presentation buffer exceeded its
    /// bound. The trace is authoritative because intermediate delta events were
    /// intentionally discarded instead of being published in the background.
    func reloadTimelineAfterPresentationOverflow(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) {
        cancelPresentationReloadRetry()
        scheduleHistoryReload(
            generation: connectionGeneration,
            connection: connection,
            sessionStore: sessionStore,
            cachedSignature: nil,
            presentationReloadAttempt: 1
        )
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

        // A notification / deep-link open owns the focused session until its own
        // view binds the stream. A ChatView still mounted for another session
        // must not reclaim the active session, focus, or the shared transport —
        // its timeline stays as-is instead of being reset behind the tap.
        guard !connection.externalSessionOpenClaimBlocks(sessionId) else {
            log.warning("Connect deferred for \(self.sessionId, privacy: .public): another session was opened externally")
            transitionTo(.disconnected(reason: .cancelled))
            scheduleConnectAfterExternalOpen(generation: generation, connection: connection)
            return
        }

        transitionTo(.idle)
        if let resolvedWorkspaceId = connection.sessionReentryWorkspaceId(
            for: sessionId,
            workspaceIdHint: workspaceIdHint
        ) {
            workspaceIdHint = resolvedWorkspaceId
        }
        connection.focusSession(sessionId)
        connection.fatalSetupError = false
        cancelAutoReconnect()
        cancelStateSync()
        reducer.reset()
        coalescer.sessionId = sessionId
        toolCallCorrelator.reset()

        sessionStore.activeSessionId = sessionId
        ChatTimelinePerf.activeSessionId = sessionId
        telemetry.cancelTTFT()
        telemetry.startSessionSwitch()
        telemetry.startSessionLoad()
        markSyncStarted()

        let persistedLastSeenSeq = Self.loadLastSeenSeq(sessionId: sessionId)
        connection.sessionStreamCoordinator.seedLastSeenSeq(
            sessionId: sessionId,
            value: persistedLastSeenSeq
        )

        // Measure stale-cache window: from session entry until first confirmed fresh content.
        telemetry.updateTransportPath(connection.transportPath)
        telemetry.beginFreshContentLagMeasurement(hadCache: false)

        latestTraceSignature = await loadCachedTimeline(
            connection: connection,
            sessionStore: sessionStore
        )

        // Stopped sessions: load fresh history but do NOT open a WebSocket.
        // Opening the WS would auto-resume the pi process on the server.
        // The user must explicitly tap "Resume" to restart the session.
        let sessionStatus = sessionStore.sessions.first(where: { $0.id == sessionId })?.status
        if sessionStatus == .stopped {
            transitionTo(.stopped(historyLoaded: false))
            log.warning("Session \(self.sessionId) is stopped — loading history only unless the server reports it active")
            scheduleHistoryReload(
                generation: generation,
                connection: connection,
                sessionStore: sessionStore,
                cachedSignature: latestTraceSignature
            )
            await historyReloadTask?.value
            guard generation == connectionGeneration else {
                transitionTo(.disconnected(reason: .generationChanged))
                return
            }
            guard !Task.isCancelled else {
                transitionTo(.disconnected(reason: .cancelled))
                return
            }

            let refreshedStatus = sessionStore.sessions.first(where: { $0.id == sessionId })?.status
            if refreshedStatus == .stopped {
                transitionTo(.stopped(historyLoaded: true))
                return
            }

            log.warning("Session \(self.sessionId) refreshed as \(String(describing: refreshedStatus), privacy: .public) — opening live stream")
        }

        // Keep HTTP history as a fallback when the bound socket cannot open.
        // Cache gives instant display; this gives ground truth even while the
        // focused stream is still waiting to bind.
        scheduleHistoryReload(
            generation: generation,
            connection: connection,
            sessionStore: sessionStore,
            cachedSignature: latestTraceSignature
        )

        guard let stream = await bindFocusedSessionStream(
            generation: generation,
            connection: connection,
            sessionStore: sessionStore
        ) else {
            return
        }

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
        switch stream {
        case .events(let eventStream):
            for await event in eventStream {
                await handleStreamEvent(
                    event,
                    connection: connection,
                    sessionStore: sessionStore,
                    generation: generation,
                    hasReceivedConnected: &hasReceivedConnected
                )
                if case .disconnected = entryState { break }
            }

        case .bareMessages(let messageStream):
            for await message in messageStream {
                await handleStreamEvent(
                    SessionStreamEvent(
                        sessionId: sessionId,
                        message: message,
                        meta: _consumeInboundMetaForTesting?()
                    ),
                    connection: connection,
                    sessionStore: sessionStore,
                    generation: generation,
                    hasReceivedConnected: &hasReceivedConnected
                )
                if case .disconnected = entryState { break }
            }
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
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> TraceSignature? {
        transitionTo(.loadingCache)

        let cacheLoadStartMs = ChatSessionTelemetry.nowMs()
        let cacheServerId = connection.currentServerId ?? sessionStore.activeServerId
        let cached: CachedTrace?
        if let cacheServerId {
            cached = await TimelineCache.shared.loadTrace(sessionId, serverId: cacheServerId)
        } else {
            cached = await TimelineCache.shared.loadTrace(sessionId)
        }
        let cacheLoadDurationMs = max(0, ChatSessionTelemetry.nowMs() - cacheLoadStartMs)

        let signature: TraceSignature?
        if let cached {
            tracePage = cached.page
            signature = TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId)
        } else {
            tracePage = nil
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
            // A cache load is a bounded reducer-only snapshot apply, so it is
            // still allowed while presentation is paused; live events remain
            // behind the coalescer gate.
            if reducer.items.isEmpty {
                let reducerLoadStartMs = ChatSessionTelemetry.nowMs()
                reducer.loadSession(cached.events)
                if sessionStore.session(id: sessionId)?.status.isRunning == false {
                    reducer.finalizeTerminalArtifactsAsInterrupted()
                }
                let reducerLoadDurationMs = max(0, ChatSessionTelemetry.nowMs() - reducerLoadStartMs)

                ChatSessionTelemetry.recordReducerLoad(
                    durationMs: reducerLoadDurationMs,
                    sessionId: sessionId,
                    source: "cache",
                    eventCount: cached.eventCount,
                    itemCount: reducer.items.count
                )

                let footprint = AppDiagnosticsService.currentFootprintMB()
                ClientLog.info("Memory", "Session loaded (cache)", metadata: [
                    "footprintMB": footprint.map(String.init) ?? "n/a",
                    "traceEvents": String(cached.events.count),
                    "timelineItems": String(reducer.items.count),
                    "sessionId": sessionId,
                ])

                log.info("Loaded \(cached.eventCount) cached events for \(self.sessionId)")

                // Record fresh content lag now — user sees cached content.
                // Background history refresh may run later but the user is no
                // longer staring at an empty screen.
                telemetry.recordFreshContentLagIfNeeded(
                    reason: "cache_hit",
                    sessionId: sessionId,
                    workspaceId: resolveWorkspaceId(from: sessionStore)
                )
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
    private func handleStreamEvent(
        _ event: SessionStreamEvent,
        connection: ServerConnection,
        sessionStore: SessionStore,
        generation: Int,
        hasReceivedConnected: inout Bool
    ) async {
        guard event.sessionId == sessionId else {
            log.warning("Ignoring stream event for wrong session: \(event.sessionId, privacy: .public) while handling \(self.sessionId, privacy: .public)")
            return
        }

        let message = event.message
        let inboundMeta = event.meta
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

                // Fill a durable-event gap before treating the first visible stream as current
                // when there is no cached timeline to reconcile from. Cache-backed re-entry uses
                // the fresh trace reload path; empty-cache relaunches need the server ring for
                // events emitted while the app had no bound-session subscriber.
                if let currentSeq = inboundMeta?.currentSeq {
                    let canFetchCatchUp = _loadCatchUpForTesting != nil || connection.apiClient != nil
                    let trackedSeq = connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
                    let hasCachedTimeline = (latestTraceSignature?.eventCount ?? 0) > 0
                    if canFetchCatchUp, !hasCachedTimeline, currentSeq != trackedSeq {
                        let outcome = await performCatchUpIfNeeded(
                            currentSeq: currentSeq,
                            generation: generation,
                            connection: connection,
                            sessionStore: sessionStore
                        )
                        log.warning("First connect seq=\(currentSeq) catchUp=\(String(describing: outcome), privacy: .public) for \(self.sessionId)")
                    } else {
                        connection.sessionStreamCoordinator.seedLastSeenSeq(
                            sessionId: sessionId,
                            value: currentSeq
                        )
                        persistLastSeenSeq(currentSeq)
                        log.warning("First connect: seeded seq=\(currentSeq) for \(self.sessionId)")
                    }
                }

                // Request freshest server session state only once the stream is connected.
                // This avoids speculative pre-connect sends that can stall/fail during startup.
                scheduleStateSync(generation: generation, connection: connection)

                hasReceivedConnected = true
                unexpectedStreamExitCount = 0
                transitionTo(.streaming)

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
                        log.warning("WS reconnected — no gap for \(self.sessionId)")
                    case .applied:
                        log.warning("WS reconnected — catch-up applied for \(self.sessionId)")
                    case .fullReloadScheduled:
                        log.error("WS reconnected — full history reload scheduled for \(self.sessionId)")
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
                let accepted = connection.sessionStreamCoordinator.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: seq
                )
                guard accepted else { return }

                telemetry.recordFreshContentLagIfNeeded(reason: "stream_seq", sessionId: sessionId)
                let updatedSeq = connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
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
        if connection.isFocusedSession(sessionId) {
            connection.handleActiveSessionUI(message, sessionId: sessionId, storeResult: storeResult)
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
            shouldAutoReconnect = hasReceivedConnected
                && generation == connectionGeneration
                && wantsAutoReconnect
                // Only the still-focused session may reclaim the shared transport.
                && connection.isFocusedSession(sessionId)
                && !connection.fatalSetupError
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
            if !suppressTimelineMutationWhilePaused() {
                reducer.appendSystemEvent("Connection dropped — reconnecting…")
            }
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
            guard let routeScope = self.resolveRouteScope(from: sessionStore) else {
                log.warning("Reconcile skipped for \(self.sessionId): missing route scope")
                return
            }

            do {
                let (session, _) = try await api.getSession(scope: routeScope, sessionId: sessionId)
                connection.applyFetchedSessionState(session)
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
        let page: TracePageMetadata?
        if let fetchHook = _fetchTraceSnapshotForTesting {
            trace = await fetchHook()
            page = tracePage
        } else if let api = connection.apiClient {
            guard let routeScope = resolveRouteScope(from: connection.sessionStore) else {
                log.debug("Snapshot flush skipped for \(self.sessionId): missing route scope")
                return
            }

            do {
                let snapshot = try await fetchTraceHistorySnapshot(
                    api: api,
                    routeScope: routeScope
                )
                trace = snapshot.trace
                page = snapshot.page
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
        } else if let cacheServerId = connection.currentServerId ?? connection.sessionStore.activeServerId {
            await TimelineCache.shared.saveTrace(sessionId, serverId: cacheServerId, events: trace, page: page)
        } else {
            await TimelineCache.shared.saveTrace(sessionId, events: trace, page: page)
        }

        tracePage = page
        latestTraceSignature = TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)
        lastSnapshotFlushAt = Date()
    }

    func cleanup() {
        wantsAutoReconnect = false
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelAutoReconnect()
        cancelPresentationReloadRetry()
        cancelHistoryReload()
        coalescer.flushNow()
        transitionTo(.disconnected(reason: .cancelled))
        cancelStateSync()
    }

    // MARK: - Per-Session Timeline Routing

    /// Route a server message to the per-session timeline pipeline.
    ///
    /// This handles all coalescer/reducer mutations for the active session.
    /// Each ChatSessionManager owns its own coalescer + reducer, so sessions
    /// maintain independent timelines across NavigationStack navigation.
    private func routeToTimeline(
        _ message: ServerMessage,
        connection: ServerConnection,
        storeResult: ServerConnection.StoreUpdateResult = .notHandled
    ) {
        for event in ServerMessageEffects.timelineEvents(for: message, sessionId: sessionId) {
            coalescer.receive(event)
        }

        switch message {
        case .agentStart, .agentEnd, .agentSettled, .textDelta, .thinkingDelta:
            break

        case .audioStream(let stream):
            connection.audioPlayer.handleAudioStream(stream, sessionId: sessionId)

        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            coalescer.receive(toolCallCorrelator.start(
                sessionId: sessionId, tool: tool, args: args,
                toolCallId: toolCallId, callSegments: callSegments
            ))

        case .toolUpdate(let tool, let args, let toolCallId, let callSegments):
            coalescer.receive(toolCallCorrelator.update(
                sessionId: sessionId, tool: tool, args: args,
                toolCallId: toolCallId, callSegments: callSegments
            ))

        case .toolOutput(let output, let isError, let toolCallId, let mode, let truncated, let totalBytes, let details):
            coalescer.receive(toolCallCorrelator.output(
                sessionId: sessionId, output: output, isError: isError,
                toolCallId: toolCallId, mode: mode,
                truncated: truncated, totalBytes: totalBytes,
                details: details
            ))

        case .toolEnd(let tool, let toolCallId, let details, let isError, let resultSegments):
            if tool == "voice_reply_mode" {
                AppPreferences.Voice.applySessionReplyModeDetails(details, sessionId: sessionId)
            }
            coalescer.receive(toolCallCorrelator.end(
                sessionId: sessionId, toolCallId: toolCallId,
                details: details, isError: isError,
                resultSegments: resultSegments
            ))

        case .messageEnd(let role, let content, _):
            if role == "user", !content.isEmpty,
               !suppressTimelineMutationWhilePaused(),
               !reducer.hasUserMessage(matching: content) {
                reducer.appendUserMessage(content)
            }

        case .error(_, _, let fatal):
            // Sandbox VM errors (e.g. QEMU unavailable, VM start failure) propagate
            // through this standard path — the server sends them as .error messages
            // with fatal=true, which displays the message in the timeline and
            // suppresses auto-reconnect below.
            if fatal {
                connection.fatalSetupError = true
            }

        case .sessionEnded, .cacheMiss, .compactionStart, .compactionEnd, .retryStart, .retryEnd:
            break

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

        case .queueItemStarted(_, let item, _):
            guard !suppressTimelineMutationWhilePaused() else { break }
            let displayText = UserMessageAttachmentPresentation.makeTimelineText(
                text: item.message,
                uploadedAttachments: item.attachments ?? []
            )
            reducer.appendUserMessage(displayText, images: item.optimisticImages ?? [])

        case .stopRequested(_, let reason):
            guard !suppressTimelineMutationWhilePaused() else { break }
            reducer.appendSystemEvent(reason ?? "Stopping…")

        case .stopConfirmed(_, let reason):
            guard !suppressTimelineMutationWhilePaused() else { break }
            coalescer.flushNow()
            reducer.finalizeTerminalArtifactsAsInterrupted()
            reducer.appendSystemEvent(reason ?? "Stop confirmed")

        case .state, .sessionSummary:
            // Only finalize when leaving a running state. Re-broadcast ready/idle
            // snapshots (state or session_summary) must not flip in-progress tools
            // to Interrupted. Missed agent_settled still recovers on the transition.
            if storeResult.didTransitionOutOfRunning {
                guard !suppressTimelineMutationWhilePaused() else { break }
                coalescer.flushNow()
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }

        case .stopFailed(_, let reason):
            guard !suppressTimelineMutationWhilePaused() else { break }
            reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))

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

        let decision = connection.sessionStreamCoordinator.catchUpDecision(
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
                if let routeScope = resolveRouteScope(from: sessionStore) {
                    response = try? await api.getSessionEvents(
                        scope: routeScope,
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

            markSyncSucceeded()

            if !response.catchUpComplete {
                log.warning("Ring miss for \(self.sessionId) since seq \(since) — scheduling history reload")
                connection.sessionStreamCoordinator.seedLastSeenSeq(
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
                let accepted = connection.sessionStreamCoordinator.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: event.seq
                )
                guard accepted else { continue }

                let eventStoreResult = connection.applySharedStoreUpdate(for: event.message, sessionId: sessionId)
                routeToTimeline(event.message, connection: connection, storeResult: eventStoreResult)
                if connection.isFocusedSession(sessionId) {
                    connection.handleActiveSessionUI(event.message, sessionId: sessionId, storeResult: eventStoreResult)
                }
                appliedCatchUp = true
            }

            sessionStore.upsert(response.session)

            let trackedAfterEvents = connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
            if response.currentSeq > trackedAfterEvents {
                connection.sessionStreamCoordinator.applyCatchUpProgress(
                    sessionId: sessionId,
                    seq: response.currentSeq
                )
                appliedCatchUp = true
            }

            let persistedSeq = connection.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId)
            persistLastSeenSeq(persistedSeq)

            recordCatchupMs(appliedCatchUp ? "applied" : "no_gap")
            return appliedCatchUp ? .applied : .noGap
        }
    }

    private func suppressTimelineMutationWhilePaused() -> Bool {
        guard coalescer.isPresentationPaused else { return false }
        coalescer.markPresentationNeedsTraceReload()
        return true
    }

    // MARK: - History Loading

    private func fetchTraceHistorySnapshot(
        api: APIClient,
        routeScope: SessionRouteScope
    ) async throws -> TraceHistorySnapshot {
        do {
            let response = try await api.getSessionTracePage(
                scope: routeScope,
                sessionId: sessionId,
                previewBytes: Self.tracePagePreviewBytes
            )
            return TraceHistorySnapshot(
                session: response.session,
                trace: response.trace,
                page: response.page
            )
        } catch {
            guard Self.shouldFallbackToFullTrace(error) else { throw error }
            let fallback = try await api.getSession(
                scope: routeScope,
                sessionId: sessionId,
                traceView: .full
            )
            return TraceHistorySnapshot(
                session: fallback.session,
                trace: fallback.trace,
                page: nil
            )
        }
    }

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
        cachedLastEventId: String?,
        replayID: UUID?,
        allowFirstMessageFallback: Bool = true
    ) async -> TraceSignature? {
        guard let routeScope = resolveRouteScope(from: sessionStore) else {
            markSyncFailed()
            log.warning("Trace fetch skipped for \(self.sessionId): missing workspaceId")
            return nil
        }
        let workspaceId = routeScope.workspaceId
        let presentationReloadMarker = coalescer.presentationTraceReloadMarker

        let traceFetchStartedMs = ChatSessionTelemetry.nowMs()

        do {
            let session: Session
            let trace: [TraceEvent]
            let page: TracePageMetadata?
            if let fetchHook = _fetchSessionTraceForTesting {
                (session, trace) = try await fetchHook(routeScope, sessionId)
                page = nil
            } else {
                let snapshot = try await fetchTraceHistorySnapshot(
                    api: api,
                    routeScope: routeScope
                )
                session = snapshot.session
                trace = snapshot.trace
                page = snapshot.page
            }

            ChatSessionTelemetry.recordTraceFetch(
                durationMs: max(0, ChatSessionTelemetry.nowMs() - traceFetchStartedMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                status: "ok",
                traceEventCount: trace.count
            )

            guard !Task.isCancelled else { return nil }
            sessionStore.upsert(session)
            // History is an authoritative reducer-only apply. Unlike live
            // events, it may run while presentation is paused so a connect or
            // re-entry cannot leave the visible timeline blank. The coalescer
            // still prevents high-frequency live publication in that state.
            tracePage = page
            markSyncSucceeded()

            let timelineTrace = Self.timelineTrace(
                from: trace,
                session: session,
                allowFirstMessageFallback: allowFirstMessageFallback
            )
            let freshSignature = Self.traceSignature(for: timelineTrace)
            let usedFirstMessageFallback = trace.isEmpty && !timelineTrace.isEmpty
            var freshnessReason = "history_empty"

            if timelineTrace.isEmpty, !allowFirstMessageFallback {
                let usedReplay = replayID.map { reducer.isReplayBuffering(id: $0) } ?? false
                if usedReplay, let replayID {
                    reducer.applyTraceWithLiveReplay([], replayID: replayID)
                } else {
                    reducer.loadSession([], preserveOrphans: false)
                }
                needsInitialScroll = true
                freshnessReason = "history_applied_empty"
            }

            if !timelineTrace.isEmpty {
                // Skip rebuild if the timeline projection hasn't changed since
                // the cached/fallback version. Session summary/status never
                // affects timeline reconciliation; persisted Pi lifecycle does.
                if let cachedCount = cachedEventCount,
                   cachedCount == freshSignature.eventCount,
                   cachedLastEventId == freshSignature.lastEventId,
                   reducer.traceEventsForCache() == timelineTrace {
                    log.info("Trace unchanged for \(self.sessionId) — skipping rebuild")
                    if let replayID {
                        reducer.discardHistoryReplayBuffer(id: replayID)
                    }
                    freshnessReason = "history_unchanged"
                } else {
                    // Apply the fresh trace. If live events arrived via WS during
                    // the fetch, the replay buffer preserves them and re-applies
                    // on top of the rebuilt timeline in a single @MainActor turn.
                    let usedReplay = replayID.map { reducer.isReplayBuffering(id: $0) } ?? false
                    let reducerStartMs = ChatSessionTelemetry.nowMs()
                    if usedReplay, let replayID {
                        reducer.applyTraceWithLiveReplay(
                            timelineTrace,
                            replayID: replayID
                        )
                    } else {
                        // Fresh trace is authoritative — don't preserve orphans.
                        // Orphan detection creates "ghost" user messages at the
                        // bottom (no matching assistant response) when the trace
                        // lags behind locally-appended items.
                        reducer.loadSession(
                            timelineTrace,
                            preserveOrphans: false
                        )
                    }
                    let reducerDurationMs = max(0, ChatSessionTelemetry.nowMs() - reducerStartMs)

                    ChatSessionTelemetry.recordReducerLoad(
                        durationMs: reducerDurationMs,
                        sessionId: self.sessionId,
                        source: usedFirstMessageFallback ? "history_first_message_fallback" : (usedReplay ? "history+replay" : "history"),
                        eventCount: timelineTrace.count,
                        itemCount: reducer.items.count
                    )

                    needsInitialScroll = true
                    telemetry.recordSessionLoadIfNeeded(
                        path: usedFirstMessageFallback ? "first_message_fallback" : (usedReplay ? "full_reload" : "cache_miss"),
                        itemCount: reducer.items.count,
                        sessionId: sessionId,
                        workspaceId: workspaceId
                    )
                    let footprint = AppDiagnosticsService.currentFootprintMB()
                    log.warning("Loaded \(trace.count) fresh trace events for \(self.sessionId) [footprint=\(footprint ?? -1)MB, items=\(self.reducer.items.count), replay=\(usedReplay), firstMessageFallback=\(usedFirstMessageFallback)]")
                    ClientLog.info("Memory", "Session loaded", metadata: [
                        "footprintMB": footprint.map(String.init) ?? "n/a",
                        "traceEvents": String(trace.count),
                        "timelineEvents": String(timelineTrace.count),
                        "timelineItems": String(self.reducer.items.count),
                        "sessionId": self.sessionId,
                        "replay": usedReplay ? "1" : "0",
                        "firstMessageFallback": usedFirstMessageFallback ? "1" : "0",
                    ])
                    freshnessReason = if usedFirstMessageFallback {
                        "history_first_message_fallback"
                    } else {
                        usedReplay ? "history_replayed" : "history_applied"
                    }
                }
            }

            if timelineTrace.isEmpty, let replayID {
                reducer.discardHistoryReplayBuffer(id: replayID)
            }
            if !session.status.isRunning {
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }

            telemetry.recordFreshContentLagIfNeeded(reason: freshnessReason, sessionId: sessionId, workspaceId: workspaceId)

            // Always update cache with fresh data
            let cacheServerId = sessionStore.activeServerId
            Task.detached {
                if let cacheServerId {
                    await TimelineCache.shared.saveTrace(self.sessionId, serverId: cacheServerId, events: trace, page: page)
                } else {
                    await TimelineCache.shared.saveTrace(self.sessionId, events: trace, page: page)
                }
            }

            // Overflow/paused-mutation recovery stays armed until this apply.
            coalescer.acknowledgePresentationTraceReload(ifMarker: presentationReloadMarker)
            return freshSignature
        } catch {
            ChatSessionTelemetry.recordTraceFetch(
                durationMs: max(0, ChatSessionTelemetry.nowMs() - traceFetchStartedMs),
                sessionId: sessionId,
                workspaceId: workspaceId,
                status: "error",
                errorKind: ChatSessionTelemetry.metricErrorKind(for: error)
            )
            guard !Task.isCancelled else { return nil }
            if let replayID {
                reducer.discardHistoryReplayBuffer(id: replayID)
            }
            markSyncFailed()
            log.warning("Trace fetch failed for \(self.sessionId): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func loadOlderTracePage(connection: ServerConnection, sessionStore: SessionStore) async -> Bool {
        guard !isLoadingOlderTracePage else { return false }
        guard reducer.canPrependTracePage else { return false }
        guard let cursor = tracePage?.olderCursor, tracePage?.hasOlder == true else { return false }
        guard let api = connection.apiClient else { return false }
        guard let routeScope = resolveRouteScope(from: sessionStore) else {
            log.warning("Older trace page skipped for \(self.sessionId): missing workspaceId")
            return false
        }

        isLoadingOlderTracePage = true
        defer { isLoadingOlderTracePage = false }

        do {
            let response = try await api.getSessionTracePage(
                scope: routeScope,
                sessionId: sessionId,
                cursor: cursor,
                previewBytes: Self.tracePagePreviewBytes
            )
            return applyPrependedTracePage(response, connection: connection, sessionStore: sessionStore)
        } catch {
            markSyncFailed()
            log.warning("Older trace page failed for \(self.sessionId): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func loadTracePageAround(
        entryId: String,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Bool {
        guard !reducer.items.contains(where: { $0.id == entryId }) else { return true }
        guard !isLoadingOlderTracePage else { return false }
        guard reducer.canPrependTracePage else { return false }
        guard let api = connection.apiClient else { return false }
        guard let routeScope = resolveRouteScope(from: sessionStore) else {
            log.warning("Trace page around skipped for \(self.sessionId): missing workspaceId")
            return false
        }

        isLoadingOlderTracePage = true
        defer { isLoadingOlderTracePage = false }

        do {
            let response = try await api.getSessionTracePage(
                scope: routeScope,
                sessionId: sessionId,
                aroundEntryId: entryId,
                previewBytes: Self.tracePagePreviewBytes
            )
            guard applyPrependedTracePage(response, connection: connection, sessionStore: sessionStore) else {
                return reducer.items.contains(where: { $0.id == entryId })
            }
            return reducer.items.contains(where: { $0.id == entryId })
        } catch {
            markSyncFailed()
            log.warning("Trace page around failed for \(self.sessionId): \(error.localizedDescription)")
            return false
        }
    }

    private func applyPrependedTracePage(
        _ response: APIClient.SessionTracePageResponse,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        // Paged trace history has the same authoritative, reducer-only safety
        // as the initial cache/history apply. Keep deep-link outline targets
        // loadable while the scene is paused without publishing live events.
        if response.page.staleCursor {
            tracePage = nil
            scheduleHistoryReload(
                generation: connectionGeneration,
                connection: connection,
                sessionStore: sessionStore,
                cachedSignature: nil
            )
            return false
        }

        sessionStore.upsert(response.session)
        let didPrepend = reducer.prependTracePage(response.trace)
        guard didPrepend else { return false }
        if !response.session.status.isRunning {
            reducer.finalizeTerminalArtifactsAsInterrupted()
        }
        tracePage = response.page
        markSyncSucceeded()

        let cacheEvents = reducer.traceEventsForCache()
        let cacheServerId = connection.currentServerId ?? sessionStore.activeServerId
        Task.detached {
            if let cacheServerId {
                await TimelineCache.shared.saveTrace(self.sessionId, serverId: cacheServerId, events: cacheEvents, page: response.page)
            } else {
                await TimelineCache.shared.saveTrace(self.sessionId, events: cacheEvents, page: response.page)
            }
        }
        return didPrepend
    }

    private func scheduleHistoryReload(
        generation: Int,
        connection: ServerConnection,
        sessionStore: SessionStore,
        cachedSignature: TraceSignature?,
        presentationReloadAttempt: Int? = nil
    ) {
        if presentationReloadAttempt == nil {
            cancelPresentationReloadRetry()
        }
        cancelHistoryReload()
        markSyncStarted()

        let cachedEventCount = cachedSignature?.eventCount
        let cachedLastEventId = cachedSignature?.lastEventId
        let replayID = UUID()
        let presentationReloadMarker = coalescer.presentationTraceReloadMarker
        activeHistoryReplayID = replayID
        reducer.beginHistoryReplayBuffer(id: replayID)

        historyReloadTask = Task { @MainActor [weak self, weak connection] in
            guard let self else { return }
            guard generation == self.connectionGeneration else { return }

            var didSucceed = false
            if let loadHook = self._loadHistoryForTesting {
                let signature = await loadHook(cachedEventCount, cachedLastEventId)
                guard !Task.isCancelled else { return }
                guard generation == self.connectionGeneration else { return }
                self.reducer.discardHistoryReplayBuffer(id: replayID)
                if self.activeHistoryReplayID == replayID {
                    self.activeHistoryReplayID = nil
                }
                if let signature {
                    self.latestTraceSignature = TraceSignature(
                        eventCount: signature.eventCount,
                        lastEventId: signature.lastEventId
                    )
                    // Overflow/paused-mutation recovery stays armed until a
                    // successful load. Failed hooks must not clear the flag.
                    self.coalescer.acknowledgePresentationTraceReload(ifMarker: presentationReloadMarker)
                    self.markSyncSucceeded()
                    didSucceed = true
                } else {
                    self.markSyncFailed()
                }
            } else if let api = connection?.apiClient {
                if let freshSignature = await self.loadHistory(
                    api: api,
                    sessionStore: sessionStore,
                    cachedEventCount: cachedEventCount,
                    cachedLastEventId: cachedLastEventId,
                    replayID: replayID
                ) {
                    guard generation == self.connectionGeneration else { return }
                    guard self.activeHistoryReplayID == replayID else { return }
                    self.latestTraceSignature = freshSignature
                    self.activeHistoryReplayID = nil
                    didSucceed = true
                } else if self.activeHistoryReplayID == replayID {
                    self.activeHistoryReplayID = nil
                }
            } else {
                self.reducer.discardHistoryReplayBuffer(id: replayID)
                if self.activeHistoryReplayID == replayID {
                    self.activeHistoryReplayID = nil
                }
                self.markSyncFailed()
            }

            guard !Task.isCancelled,
                  generation == self.connectionGeneration else { return }
            if !didSucceed,
               let presentationReloadAttempt,
               !self.coalescer.isPresentationPaused {
                self.schedulePresentationReloadRetryIfNeeded(
                    afterAttempt: presentationReloadAttempt,
                    generation: generation,
                    connection: connection,
                    sessionStore: sessionStore
                )
            }
        }
    }

    /// Force an immediate full trace reload from the server.
    ///
    /// Used after tree navigation, where the session leaf/context changes but
    /// the session ID remains the same. Returns `true` when fresh history was
    /// loaded and applied; `false` when the reload failed.
    @discardableResult
    func forceHistoryReload(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Bool {
        cancelPresentationReloadRetry()
        cancelHistoryReload()

        if let loadHook = _loadHistoryForTesting {
            let presentationReloadMarker = coalescer.presentationTraceReloadMarker
            markSyncStarted()
            guard let signature = await loadHook(nil, nil) else {
                markSyncFailed()
                return false
            }

            latestTraceSignature = TraceSignature(
                eventCount: signature.eventCount,
                lastEventId: signature.lastEventId
            )
            coalescer.acknowledgePresentationTraceReload(ifMarker: presentationReloadMarker)
            markSyncSucceeded()
            return true
        }

        guard let api = connection.apiClient else {
            markSyncFailed()
            return false
        }

        markSyncStarted()
        let replayID = UUID()
        activeHistoryReplayID = replayID
        reducer.beginHistoryReplayBuffer(id: replayID)

        guard let freshSignature = await loadHistory(
            api: api,
            sessionStore: sessionStore,
            cachedEventCount: nil,
            cachedLastEventId: nil,
            replayID: replayID,
            allowFirstMessageFallback: false
        ) else {
            if activeHistoryReplayID == replayID {
                activeHistoryReplayID = nil
            }
            return false
        }

        latestTraceSignature = freshSignature
        if activeHistoryReplayID == replayID {
            activeHistoryReplayID = nil
        }
        return true
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

    private func schedulePresentationReloadRetryIfNeeded(
        afterAttempt attempt: Int,
        generation: Int,
        connection: ServerConnection?,
        sessionStore: SessionStore
    ) {
        guard attempt < Self.presentationReloadMaxAttempts,
              generation == connectionGeneration,
              coalescer.needsPresentationTraceReload,
              !coalescer.isPresentationPaused,
              let connection else {
            return
        }

        let nextAttempt = attempt + 1
        let delay = presentationReloadRetryDelay(for: attempt)
        cancelPresentationReloadRetry()
        presentationReloadRetryTask = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  let connection,
                  generation == self.connectionGeneration,
                  self.coalescer.needsPresentationTraceReload,
                  !self.coalescer.isPresentationPaused else {
                return
            }

            self.presentationReloadRetryTask = nil
            self.scheduleHistoryReload(
                generation: generation,
                connection: connection,
                sessionStore: sessionStore,
                cachedSignature: nil,
                presentationReloadAttempt: nextAttempt
            )
        }
    }

    private func presentationReloadRetryDelay(for attempt: Int) -> Duration {
#if DEBUG
        if let override = _presentationReloadRetryDelayForTesting {
            return override
        }
#endif
        switch attempt {
        case 1: return .milliseconds(250)
        case 2: return .milliseconds(750)
        default: return .seconds(2)
        }
    }

    private func cancelPresentationReloadRetry() {
        presentationReloadRetryTask?.cancel()
        presentationReloadRetryTask = nil
    }

    /// The external-open claim is bounded. Re-arm the connect loop once it
    /// settles so a session the user navigates back to still binds its stream
    /// instead of staying silently unsubscribed.
    private func scheduleConnectAfterExternalOpen(generation: Int, connection: ServerConnection) {
        cancelAutoReconnect()
        let claimedSessionId = sessionId
        autoReconnectTask = Task { @MainActor [weak self, weak connection] in
            while true {
                guard let connection else { return }
                guard connection.externalSessionOpenClaimBlocks(claimedSessionId) else { break }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  wantsAutoReconnect,
                  generation == connectionGeneration else {
                return
            }
            reconnect()
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
        if let activeHistoryReplayID {
            reducer.discardHistoryReplayBuffer(id: activeHistoryReplayID)
            self.activeHistoryReplayID = nil
        }
    }

    private func disconnectIfCurrent(_ generation: Int, connection: ServerConnection) {
        guard generation == connectionGeneration else { return }
        // Only disconnect if WE are still the active session.
        // Without this check, when session B takes over the WS,
        // session A's cleanup would kill session B's connection,
        // causing a connect/disconnect ping-pong loop.
        guard connection.isFocusedSession(sessionId)
              || connection.focusedSessionId == nil else { return }
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
