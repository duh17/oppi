import Foundation
import os.log

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi",
    category: "ChatSession"
)

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

    let sessionId: String

    let historyPort: any ChatSessionHistoryPort
    let focusedStreamPort: any ChatSessionFocusedStreamPort
    let effectsStatePort: any ChatSessionEffectsStatePort

    /// Per-session timeline pipeline — each ChatSessionManager owns its own
    /// reducer, coalescer, and correlator so sessions maintain independent
    /// timeline state across NavigationStack back-navigation.
    let reducer: TimelineReducer
    let coalescer: DeltaCoalescer
    let toolCallCorrelator = ToolCallCorrelator()

    /// Bumped to restart the `.task(id:)` connection loop.
    private(set) var connectionGeneration = 0

    /// iOS ChatView re-runs `connect()` via `.task(id: connectionGeneration)`.
    /// Mac has no equivalent view task, so the store re-invokes `connect()` here.
    @ObservationIgnored
    var onReconnect: (() -> Void)?

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
    private let streamingWaiters = StreamingWaiterBox()
    private var latestTraceSignature: TraceSignature?

    private static let presentationReloadMaxAttempts = 3

    private var unexpectedStreamExitCount = 0
    private var wantsAutoReconnect = true
    private let telemetry: ChatSessionRuntimeTelemetryTracker

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
    var _loadCatchUpForTesting: ((_ since: Int, _ currentSeq: Int) async -> ChatSessionCatchUpResponse?)?

    /// Test seam: attach inbound sequence metadata to `_streamSessionForTesting` events.
    var _consumeInboundMetaForTesting: (() -> InboundStreamMeta?)?

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
        routeScope: SessionRouteScope? = nil,
        historyPort: any ChatSessionHistoryPort,
        focusedStreamPort: any ChatSessionFocusedStreamPort,
        effectsStatePort: any ChatSessionEffectsStatePort,
        reducer: TimelineReducer,
        coalescer: DeltaCoalescer
    ) {
        self.sessionId = sessionId
        self.historyPort = historyPort
        self.focusedStreamPort = focusedStreamPort
        self.effectsStatePort = effectsStatePort
        self.reducer = reducer
        self.coalescer = coalescer
        self.telemetry = ChatSessionRuntimeTelemetryTracker(
            sessionId: sessionId,
            effects: effectsStatePort
        )
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
    static let focusedStreamBindTimeout: Duration = .seconds(8)

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

    private static func modelTags(for session: Session?) -> [String: String] {
        guard let rawModel = session?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawModel.isEmpty else {
            return ["provider": "unknown", "model": "unknown"]
        }

        let parts = rawModel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return ["provider": "unknown", "model": rawModel]
        }
        return [
            "provider": parts[0].isEmpty ? "unknown" : String(parts[0]),
            "model": parts[1].isEmpty ? "unknown" : String(parts[1]),
        ]
    }

    private static func queuedMessageTimelineText(
        text: String,
        uploadedAttachments: [ChatAttachmentRef]
    ) -> String {
        if UserMessageTextProjection.splitTrailingAttachedFilesBlock(from: text) != nil {
            return text
        }

        var seen = Set<String>()
        let fileLines = uploadedAttachments.compactMap { attachment -> String? in
            let workspacePath = attachment.workspacePath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayPath: String?
            if let workspacePath, !workspacePath.isEmpty {
                displayPath = workspacePath
            } else if !attachment.mimeType.hasPrefix("image/"), !name.isEmpty {
                displayPath = name
            } else {
                displayPath = nil
            }

            guard let path = displayPath, seen.insert(path).inserted else { return nil }
            let displayName = name.isEmpty
                ? (path as NSString).lastPathComponent
                : name
            return "- \(displayName): \(path)"
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileLines.isEmpty else { return trimmed }
        let block = (["Attached files:"] + fileLines).joined(separator: "\n")
        return trimmed.isEmpty ? block : "\(trimmed)\n\n\(block)"
    }

    private func resolveWorkspaceId() -> String? {
        if let workspaceId = effectsStatePort.session(id: sessionId)?.workspaceId,
           !workspaceId.isEmpty {
            return workspaceId
        }

        if let workspaceId = effectsStatePort.activeSession?.workspaceId,
           !workspaceId.isEmpty {
            return workspaceId
        }

        if let workspaceId = workspaceIdHint,
           !workspaceId.isEmpty {
            return workspaceId
        }

        return nil
    }

    private func resolveRouteScope() -> SessionRouteScope? {
        if routeScopeHint == .control
            || effectsStatePort.session(id: sessionId)?.control != nil {
            return .control
        }
        if case .workspace(let workspaceId) = routeScopeHint,
           !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .workspace(workspaceId)
        }
        return resolveWorkspaceId().map(SessionRouteScope.workspace)
    }

    private func workspaceIdForState() -> String {
        resolveWorkspaceId() ?? ""
    }

    private func transitionTo(_ newState: SessionEntryState) {
        let oldState = entryState
        guard oldState != newState else { return }

        log.debug("State transition for \(self.sessionId, privacy: .public): \(oldState.logDescription, privacy: .public) -> \(newState.logDescription, privacy: .public)")
        entryState = newState
        switch newState {
        case .streaming:
            resumeStreamingWaiters(with: .success(()))
        case .stopped:
            resumeStreamingWaiters(with: .failure(ChatSessionFocusedStreamBindError.timedOut))
        default:
            break
        }
    }

    private func resumeStreamingWaiters(with result: Result<Void, Error>) {
        let waiters = streamingWaiters.waiters
        streamingWaiters.waiters = [:]
        for (_, waiter) in waiters {
            waiter.resume(with: result)
        }
    }

    private func openSessionStream() async -> SessionStreamInput? {
        if let eventStreamForTesting = _streamEventsForTesting?(sessionId) {
            focusedStreamPort.setActiveSessionIdForTesting(sessionId)
            return .events(eventStreamForTesting)
        }

        if let streamForTesting = _streamSessionForTesting?(sessionId) {
            focusedStreamPort.setActiveSessionIdForTesting(sessionId)
            return .bareMessages(streamForTesting)
        }

        guard let routeScope = resolveRouteScope(),
              let stream = await focusedStreamPort.open(sessionId: sessionId, scope: routeScope) else {
            return nil
        }
        return .events(stream)
    }

    private static let focusedStreamSetupMaxAttempts = 8

    private func bindFocusedSessionStream(generation: Int) async -> SessionStreamInput? {
        var attempt = 0
        while true {
            if generation != connectionGeneration {
                clearFocusedStreamRecovery()
                transitionTo(.disconnected(reason: .generationChanged))
                return nil
            }
            guard !Task.isCancelled else {
                clearFocusedStreamRecovery()
                transitionTo(.disconnected(reason: .cancelled))
                return nil
            }

            switch await focusedStreamSetupDisposition() {
            case .bound(let stream):
                clearFocusedStreamRecovery()
                return stream
            case .missingRoute:
                failFocusedStreamSetup(message: "Missing session route context")
                return nil
            case .terminalUnavailable:
                failFocusedStreamSetup(message: "Session stream unavailable")
                return nil
            case .retryable:
                focusedStreamPort.setStreamRecovering(true, sessionId: sessionId)
                if focusedStreamPort.externalOpenClaimBlocks(sessionId: sessionId) {
                    if await waitWhileExternalSessionOpenClaimBlocks() {
                        continue
                    }
                    clearFocusedStreamRecovery()
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
                clearFocusedStreamRecovery()
                transitionTo(.disconnected(reason: .cancelled))
                return nil
            }
        }
    }

    private func focusedStreamSetupDisposition() async -> FocusedStreamSetupDisposition {
        if let stream = await openSessionStream() {
            return .bound(stream)
        }
        if resolveRouteScope() == nil {
            return .missingRoute
        }
        if focusedStreamPort.isBindTerminal {
            return .terminalUnavailable
        }
        return .retryable
    }

    private func failFocusedStreamSetup(message: String) {
        clearFocusedStreamRecovery()
        transitionTo(.disconnected(reason: .fatalError))
        if !suppressTimelineMutationWhilePaused() {
            reducer.process(.error(sessionId: sessionId, message: message))
        }
    }

    private func clearFocusedStreamRecovery() {
        focusedStreamPort.setStreamRecovering(false, sessionId: sessionId)
    }

    private func waitWhileExternalSessionOpenClaimBlocks() async -> Bool {
        while focusedStreamPort.externalOpenClaimBlocks(sessionId: sessionId) {
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
        onReconnect?()
    }

    /// Wait until the focused stream has bound (`.streaming`).
    ///
    /// Used by command senders that must not fall back to HTTP. Times out with
    /// `ChatSessionFocusedStreamBindError.timedOut` so the composer can show it.
    func waitUntilStreaming(timeout: Duration = .seconds(8)) async throws {
        if case .streaming = entryState { return }
        if case .stopped = entryState {
            throw ChatSessionFocusedStreamBindError.timedOut
        }

        let waiterId = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if case .streaming = entryState {
                continuation.resume()
                return
            }
            if case .stopped = entryState {
                continuation.resume(throwing: ChatSessionFocusedStreamBindError.timedOut)
                return
            }
            streamingWaiters.waiters[waiterId] = continuation
            if case .streaming = entryState {
                if let pending = streamingWaiters.waiters.removeValue(forKey: waiterId) {
                    pending.resume()
                }
                return
            }
            if case .stopped = entryState {
                if let pending = streamingWaiters.waiters.removeValue(forKey: waiterId) {
                    pending.resume(throwing: ChatSessionFocusedStreamBindError.timedOut)
                }
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                guard let pending = self.streamingWaiters.waiters.removeValue(forKey: waiterId) else {
                    return
                }
                pending.resume(throwing: ChatSessionFocusedStreamBindError.timedOut)
            }
        }
    }

    /// Rebuild the timeline after a paused presentation buffer exceeded its
    /// bound. The trace is authoritative because intermediate delta events were
    /// intentionally discarded instead of being published in the background.
    func reloadTimelineAfterPresentationOverflow() {
        cancelPresentationReloadRetry()
        scheduleHistoryReload(
            generation: connectionGeneration,
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
    func connect() async {
        let generation = connectionGeneration

        // A notification / deep-link open owns the focused session until its own
        // view binds the stream. A ChatView still mounted for another session
        // must not reclaim the active session, focus, or the shared transport —
        // its timeline stays as-is instead of being reset behind the tap.
        guard !focusedStreamPort.externalOpenClaimBlocks(sessionId: sessionId) else {
            log.warning("Connect deferred for \(self.sessionId, privacy: .public): another session was opened externally")
            transitionTo(.disconnected(reason: .cancelled))
            scheduleConnectAfterExternalOpen(generation: generation)
            return
        }

        transitionTo(.idle)
        if let resolvedWorkspaceId = effectsStatePort.resolveSessionReentryWorkspaceId(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint
        ) {
            workspaceIdHint = resolvedWorkspaceId
        }
        focusedStreamPort.focus(sessionId: sessionId)
        focusedStreamPort.fatalSetupError = false
        cancelAutoReconnect()
        cancelStateSync()
        reducer.reset()
        coalescer.sessionId = sessionId
        toolCallCorrelator.reset()

        effectsStatePort.setActiveSessionId(sessionId)
        effectsStatePort.setTimelineActiveSessionId(sessionId)
        telemetry.cancelTTFT()
        telemetry.startSessionSwitch()
        telemetry.startSessionLoad()
        markSyncStarted()

        let persistedLastSeenSeq = focusedStreamPort.loadPersistedSeq(sessionId: sessionId)
        focusedStreamPort.seedLastSeenSeq(
            sessionId: sessionId,
            value: persistedLastSeenSeq
        )
        focusedStreamPort.seedRuntimeEpoch(
            sessionId: sessionId,
            value: focusedStreamPort.loadPersistedEpoch(sessionId: sessionId)
        )

        // Measure stale-cache window: from session entry until first confirmed fresh content.
        telemetry.updateTransportPath(focusedStreamPort.transportPath)
        telemetry.beginFreshContentLagMeasurement(hadCache: false)

        latestTraceSignature = await loadCachedTimeline()

        // Stopped sessions: load fresh history but do NOT open a WebSocket.
        // Opening the WS would auto-resume the pi process on the server.
        // The user must explicitly tap "Resume" to restart the session.
        let sessionStatus = effectsStatePort.session(id: sessionId)?.status
        if FocusedSessionConnectionPolicy.initialAction(for: sessionStatus)
            == .refreshHistoryBeforeStreamDecision {
            transitionTo(.stopped(historyLoaded: false))
            log.warning("Session \(self.sessionId) is stopped — loading history only unless the server reports it active")
            scheduleHistoryReload(
                generation: generation,
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

            let refreshedStatus = effectsStatePort.session(id: sessionId)?.status
            if FocusedSessionConnectionPolicy.actionAfterHistoryRefresh(for: refreshedStatus)
                == .remainHistoryOnly {
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
            cachedSignature: latestTraceSignature
        )

        guard let stream = await bindFocusedSessionStream(generation: generation) else {
            return
        }

        transitionTo(.awaitingConnected(workspaceId: workspaceIdForState()))

        guard !Task.isCancelled else {
            transitionTo(.disconnected(reason: .cancelled))
            cancelStateSync()
            disconnectIfCurrent(generation)
            return
        }

        // Wire silence watchdog → full reconnect
        let sid = sessionId
        focusedStreamPort.setReconnectHandler { [weak self] in
            log.error("Silence watchdog triggered reconnect for \(sid)")
            self?.effectsStatePort.recordLog(
                .error,
                message: "Silence watchdog triggered reconnect",
                metadata: ["sessionId": sid]
            )
            self?.reconnect()
        }

        var hasReceivedConnected = false
        switch stream {
        case .events(let eventStream):
            for await event in eventStream {
                await handleStreamEvent(
                    event,
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
                    generation: generation,
                    hasReceivedConnected: &hasReceivedConnected
                )
                if case .disconnected = entryState { break }
            }
        }

        handleStreamEnded(
            hasReceivedConnected: hasReceivedConnected,
            generation: generation
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
    private func loadCachedTimeline() async -> TraceSignature? {
        transitionTo(.loadingCache)

        let cacheLoadStartMs = ChatSessionRuntimeTelemetryTracker.nowMs()
        let cached = await historyPort.loadCachedTrace(sessionId: sessionId)
        let cacheLoadDurationMs = max(
            0,
            ChatSessionRuntimeTelemetryTracker.nowMs() - cacheLoadStartMs
        )

        let signature: TraceSignature?
        if let cached {
            tracePage = cached.page
            signature = TraceSignature(eventCount: cached.eventCount, lastEventId: cached.lastEventId)
        } else {
            tracePage = nil
            signature = nil
        }

        effectsStatePort.recordTelemetry(
            .cacheLoad(
                durationMs: cacheLoadDurationMs,
                hit: cached != nil,
                eventCount: cached?.eventCount ?? 0
            ),
            sessionId: sessionId
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
                let reducerLoadStartMs = ChatSessionRuntimeTelemetryTracker.nowMs()
                reducer.loadSession(cached.events)
                if effectsStatePort.session(id: sessionId)?.status.isRunning == false {
                    reducer.finalizeTerminalArtifactsAsInterrupted()
                }
                let reducerLoadDurationMs = max(
                    0,
                    ChatSessionRuntimeTelemetryTracker.nowMs() - reducerLoadStartMs
                )

                effectsStatePort.recordTelemetry(
                    .reducerLoad(
                        durationMs: reducerLoadDurationMs,
                        source: "cache",
                        eventCount: cached.eventCount,
                        itemCount: reducer.items.count
                    ),
                    sessionId: sessionId
                )

                let footprint = effectsStatePort.currentMemoryFootprintMB()
                effectsStatePort.recordLog(
                    .info,
                    message: "Session loaded (cache)",
                    metadata: [
                        "footprintMB": footprint.map(String.init) ?? "n/a",
                        "traceEvents": String(cached.events.count),
                        "timelineItems": String(reducer.items.count),
                        "sessionId": sessionId,
                    ]
                )

                log.info("Loaded \(cached.eventCount) cached events for \(self.sessionId)")

                // Record fresh content lag now — user sees cached content.
                // Background history refresh may run later but the user is no
                // longer staring at an empty screen.
                telemetry.recordFreshContentLagIfNeeded(
                    reason: "cache_hit",
                    workspaceId: resolveWorkspaceId()
                )
            } else {
                log.info("Skipped cache load — reducer has \(self.reducer.items.count) live items for \(self.sessionId)")
            }

            needsInitialScroll = true
            telemetry.recordSessionLoadIfNeeded(
                path: "cache_hit",
                itemCount: reducer.items.count,
                workspaceId: resolveWorkspaceId()
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
        telemetry.updateTransportPath(focusedStreamPort.transportPath)

        switch entryState {
        case .awaitingConnected:
            if case .connected = message {
                let transportTag = focusedStreamPort.transportPath.rawValue

                if let receivedAtMs = inboundMeta?.receivedAtMs {
                    let dispatchLagMs = max(
                        0,
                        ChatSessionRuntimeTelemetryTracker.nowMs() - receivedAtMs
                    )
                    if dispatchLagMs >= 1_000 {
                        effectsStatePort.recordLog(
                            .error,
                            message: "Connected message dispatch lag",
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
                    let canFetchCatchUp = _loadCatchUpForTesting != nil || historyPort.canFetchCatchUp
                    if canFetchCatchUp {
                        let outcome = await performCatchUpIfNeeded(
                            currentSeq: currentSeq,
                            runtimeEpoch: inboundMeta?.runtimeEpoch,
                            generation: generation
                        )
                        log.warning("First connect seq=\(currentSeq) epoch=\(inboundMeta?.runtimeEpoch ?? "none", privacy: .public) catchUp=\(String(describing: outcome), privacy: .public) for \(self.sessionId)")
                    } else {
                        focusedStreamPort.seedLastSeenSeq(
                            sessionId: sessionId,
                            value: currentSeq
                        )
                        focusedStreamPort.persistSeq(currentSeq, sessionId: sessionId)
                        focusedStreamPort.persistEpoch(
                            inboundMeta?.runtimeEpoch,
                            sessionId: sessionId
                        )
                        log.warning("First connect: seeded seq=\(currentSeq) for \(self.sessionId)")
                    }
                }

                // Request freshest server session state only once the stream is connected.
                // This avoids speculative pre-connect sends that can stall/fail during startup.
                scheduleStateSync(generation: generation)

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
                        runtimeEpoch: inboundMeta?.runtimeEpoch,
                        generation: generation
                    )
                    switch outcome {
                    case .noGap:
                        log.warning("WS reconnected — no gap for \(self.sessionId)")
                    case .applied:
                        log.warning("WS reconnected — catch-up applied for \(self.sessionId)")
                    case .fullReloadScheduled:
                        log.error("WS reconnected — full history reload scheduled for \(self.sessionId)")
                    }
                    telemetry.recordFreshContentLagIfNeeded(reason: "reconnect_\(outcome)")
                } else {
                    log.warning("WS reconnected without currentSeq for \(self.sessionId) — falling back to full history reload")
                    scheduleHistoryReload(
                        generation: generation,
                        cachedSignature: latestTraceSignature
                    )
                }
                scheduleStateSync(generation: generation)
                hasReceivedConnected = true
                unexpectedStreamExitCount = 0
            }

            if let seq = inboundMeta?.seq {
                let accepted = focusedStreamPort.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: seq
                )
                guard accepted else { return }

                telemetry.recordFreshContentLagIfNeeded(reason: "stream_seq")
                let updatedSeq = focusedStreamPort.lastSeenSeq(sessionId: sessionId)
                focusedStreamPort.persistSeq(updatedSeq, sessionId: sessionId)
            }

            if case .turnAck(let command, _, let stage, _, _) = message,
               stage == .dispatched,
               command == "prompt" || command == "steer" || command == "follow_up" {
                telemetry.startTTFT(modelTags: Self.modelTags(for: effectsStatePort.session(id: sessionId)))
            }

            if case .agentEnd = message {
                telemetry.cancelTTFT()
            }

            telemetry.completeTTFTIfNeeded(signal: message)

        case .idle, .loadingCache, .stopped, .disconnected:
            log.warning("Received message in invalid state: \(self.entryState.logDescription, privacy: .public)")
        }

        let storeResult = effectsStatePort.applySharedStoreUpdate(
            for: message,
            sessionId: sessionId
        )
        routeToTimeline(message, storeResult: storeResult)
        if focusedStreamPort.isFocused(sessionId: sessionId) {
            effectsStatePort.handleActiveSessionUI(
                message,
                sessionId: sessionId,
                storeResult: storeResult
            )
        }
    }

    /// Handle post-stream cleanup: state transition, auto-reconnect, and teardown.
    private func handleStreamEnded(
        hasReceivedConnected: Bool,
        generation: Int
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
                && focusedStreamPort.isFocused(sessionId: sessionId)
                && !focusedStreamPort.fatalSetupError
                && effectsStatePort.session(id: sessionId)?.status != .stopped
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
                effectsStatePort.recordLog(
                    .error,
                    message: "Repeated stream exit; scheduling reconnect",
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

        effectsStatePort.emitTimelineSessionEnded(sessionId: sessionId)

        focusedStreamPort.setReconnectHandler(nil)
        cancelStateSync()
        disconnectIfCurrent(generation)
    }

    /// Reconcile session state from REST after a stop attempt times out.
    func reconcileAfterStop() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor in
            try? await Task.sleep(for: FocusedSessionStopTurnPolicy.reconciliationDelay)
            guard !Task.isCancelled else { return }

            guard let routeScope = self.resolveRouteScope() else {
                log.warning("Reconcile skipped for \(self.sessionId): missing route scope")
                return
            }

            do {
                let session = try await effectsStatePort.refreshSessionState(
                    scope: routeScope,
                    sessionId: sessionId
                )
                effectsStatePort.applyFetchedSessionState(session)
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
    func flushSnapshotIfNeeded(force: Bool = false) async {
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
        } else if historyPort.canFetchRemoteHistory {
            guard let routeScope = resolveRouteScope() else {
                log.debug("Snapshot flush skipped for \(self.sessionId): missing route scope")
                return
            }

            do {
                let snapshot = try await historyPort.fetchLatestTrace(
                    scope: routeScope,
                    sessionId: sessionId,
                    previewBytes: Self.tracePagePreviewBytes
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
        } else {
            await historyPort.saveCachedTrace(
                sessionId: sessionId,
                events: trace,
                page: page
            )
        }

        tracePage = page
        latestTraceSignature = TraceSignature(eventCount: trace.count, lastEventId: trace.last?.id)
        lastSnapshotFlushAt = Date()
    }

    func cleanup() {
        wantsAutoReconnect = false
        onReconnect = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelAutoReconnect()
        cancelPresentationReloadRetry()
        cancelHistoryReload()
        coalescer.flushNow()
        transitionTo(.disconnected(reason: .cancelled))
        resumeStreamingWaiters(with: .failure(CancellationError()))
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
        storeResult: ChatSessionStoreUpdateResult = .notHandled
    ) {
        for event in ServerMessageEffects.timelineEvents(for: message, sessionId: sessionId) {
            coalescer.receive(event)
        }

        if let stopEffect = FocusedSessionStopTurnPolicy.timelineEffect(for: message) {
            guard !suppressTimelineMutationWhilePaused() else { return }
            switch stopEffect {
            case .requested(let message):
                reducer.appendSystemEvent(message)
            case .confirmed(let message, let finalizeTerminalArtifacts):
                coalescer.flushNow()
                if finalizeTerminalArtifacts {
                    reducer.finalizeTerminalArtifactsAsInterrupted()
                }
                reducer.appendSystemEvent(message)
            case .failed(let message):
                reducer.process(.error(sessionId: sessionId, message: message))
            }
            return
        }

        switch message {
        case .agentStart, .agentEnd, .agentSettled, .textDelta, .thinkingDelta:
            break

        case .audioStream(let stream):
            effectsStatePort.handleAudioStream(stream, sessionId: sessionId)

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
                effectsStatePort.applyVoiceReplyModeDetails(details, sessionId: sessionId)
            }
            coalescer.receive(toolCallCorrelator.end(
                sessionId: sessionId, toolCallId: toolCallId,
                details: details, isError: isError,
                resultSegments: resultSegments
            ))

        case .messageEnd(let role, let content, _, _):
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
                focusedStreamPort.fatalSetupError = true
            }

        case .sessionEnded, .cacheMiss, .compactionStart, .compactionEnd, .retryStart, .retryEnd:
            break

        case .commandResult(let command, let requestId, let success, let data, let error):
            let consumed = effectsStatePort.handleCommandResult(
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
            let displayText = Self.queuedMessageTimelineText(
                text: item.message,
                uploadedAttachments: item.attachments ?? []
            )
            reducer.appendUserMessage(displayText, images: item.optimisticImages ?? [])

        case .state, .sessionSummary:
            // Only finalize when leaving a running state. Re-broadcast ready/idle
            // snapshots (state or session_summary) must not flip in-progress tools
            // to Interrupted. Missed agent_settled still recovers on the transition.
            if storeResult.didTransitionOutOfRunning {
                guard !suppressTimelineMutationWhilePaused() else { break }
                coalescer.flushNow()
                reducer.finalizeTerminalArtifactsAsInterrupted()
            }

        default:
            break
        }
    }

    /// Ring buffer catch-up for first connect and WS reconnection.
    ///
    /// Fills the gap in live events between the last seen seq and the
    /// server's current seq. Falls back to a full history reload when
    /// the ring can't serve the gap (ring miss, regression, epoch change,
    /// or fetch failure). Same-epoch first connect uses the stored seq even
    /// when a cached timeline exists.
    private func performCatchUpIfNeeded(
        currentSeq: Int,
        runtimeEpoch: String? = nil,
        generation: Int
    ) async -> CatchUpOutcome {
        guard generation == connectionGeneration else { return .noGap }

        let catchupStartMs = ChatSessionRuntimeTelemetryTracker.nowMs()

        let recordCatchupMs = { (result: String) in
            let durationMs = max(
                0,
                ChatSessionRuntimeTelemetryTracker.nowMs() - catchupStartMs
            )
            self.effectsStatePort.recordTelemetry(
                .catchUp(durationMs: durationMs, result: result),
                sessionId: self.sessionId
            )
        }

        if runtimeEpoch == nil {
            focusedStreamPort.seedLastSeenSeq(sessionId: sessionId, value: currentSeq)
            focusedStreamPort.seedRuntimeEpoch(sessionId: sessionId, value: nil)
            focusedStreamPort.persistSeq(currentSeq, sessionId: sessionId)
            focusedStreamPort.persistEpoch(nil, sessionId: sessionId)
            if case .awaitingConnected = entryState {
                recordCatchupMs("missing_epoch_baseline")
                return .noGap
            }
            scheduleHistoryReload(
                generation: generation,
                cachedSignature: nil
            )
            recordCatchupMs("missing_epoch")
            return .fullReloadScheduled
        }

        let decision = focusedStreamPort.catchUpDecision(
            sessionId: sessionId,
            currentSeq: currentSeq,
            runtimeEpoch: runtimeEpoch
        )

        switch decision {
        case .seqRegression(let resetTo):
            log.warning("Seq regression for \(self.sessionId): currentSeq=\(currentSeq) — scheduling history reload")
            focusedStreamPort.persistSeq(resetTo, sessionId: sessionId)
            focusedStreamPort.persistEpoch(runtimeEpoch, sessionId: sessionId)
            scheduleHistoryReload(
                generation: generation,
                cachedSignature: nil
            )
            recordCatchupMs("seq_regression")
            return .fullReloadScheduled

        case .epochChanged(let resetTo), .missingEpoch(let resetTo):
            focusedStreamPort.persistSeq(resetTo, sessionId: sessionId)
            focusedStreamPort.persistEpoch(runtimeEpoch, sessionId: sessionId)
            if case .awaitingConnected = entryState {
                log.warning("Runtime epoch baseline for \(self.sessionId): currentSeq=\(currentSeq) epoch=\(runtimeEpoch ?? "none", privacy: .public) — first connect history reload remains authoritative")
                recordCatchupMs("epoch_baseline")
                return .noGap
            }
            log.warning("Runtime epoch repair for \(self.sessionId): currentSeq=\(currentSeq) epoch=\(runtimeEpoch ?? "none", privacy: .public) — scheduling history reload")
            scheduleHistoryReload(
                generation: generation,
                cachedSignature: nil
            )
            recordCatchupMs(runtimeEpoch == nil ? "missing_epoch" : "epoch_changed")
            return .fullReloadScheduled

        case .noGap:
            focusedStreamPort.persistEpoch(runtimeEpoch, sessionId: sessionId)
            recordCatchupMs("no_gap")
            return .noGap

        case .fetchSince(let since):
            let response: ChatSessionCatchUpResponse?
            if let catchUpHook = _loadCatchUpForTesting {
                response = await catchUpHook(since, currentSeq)
            } else if let routeScope = resolveRouteScope() {
                response = try? await historyPort.fetchCatchUp(
                    scope: routeScope,
                    sessionId: sessionId,
                    since: since
                )
            } else {
                log.warning("Catch-up skipped for \(self.sessionId): missing workspaceId")
                response = nil
            }

            guard generation == connectionGeneration else { return .noGap }
            guard let response else {
                markSyncFailed()
                log.warning("Catch-up fetch failed for \(self.sessionId) — scheduling history reload")
                scheduleHistoryReload(
                    generation: generation,
                    cachedSignature: nil
                )
                recordCatchupMs("fetch_failed")
                return .fullReloadScheduled
            }

            markSyncSucceeded()

            if let responseEpoch = response.runtimeEpoch,
               let focusedEpoch = runtimeEpoch,
               responseEpoch != focusedEpoch {
                log.warning("Catch-up epoch mismatch for \(self.sessionId) — scheduling history reload")
                focusedStreamPort.seedRuntimeEpoch(sessionId: sessionId, value: focusedEpoch)
                focusedStreamPort.persistEpoch(focusedEpoch, sessionId: sessionId)
                scheduleHistoryReload(
                    generation: generation,
                    cachedSignature: nil
                )
                recordCatchupMs("epoch_mismatch")
                return .fullReloadScheduled
            }

            if !response.catchUpComplete {
                log.warning("Ring miss for \(self.sessionId) since seq \(since) — scheduling history reload")
                focusedStreamPort.seedLastSeenSeq(
                    sessionId: sessionId,
                    value: response.currentSeq
                )
                focusedStreamPort.persistSeq(response.currentSeq, sessionId: sessionId)
                focusedStreamPort.persistEpoch(
                    runtimeEpoch ?? response.runtimeEpoch,
                    sessionId: sessionId
                )
                scheduleHistoryReload(
                    generation: generation,
                    cachedSignature: nil
                )
                effectsStatePort.recordTelemetry(.catchUpRingMiss(true), sessionId: sessionId)
                recordCatchupMs("ring_miss")
                return .fullReloadScheduled
            }

            effectsStatePort.recordTelemetry(.catchUpRingMiss(false), sessionId: sessionId)

            var appliedCatchUp = false
            for event in response.events {
                let accepted = focusedStreamPort.consumeLiveSeq(
                    sessionId: sessionId,
                    seq: event.seq
                )
                guard accepted else { continue }

                let eventStoreResult = effectsStatePort.applySharedStoreUpdate(
                    for: event.message,
                    sessionId: sessionId
                )
                routeToTimeline(event.message, storeResult: eventStoreResult)
                if focusedStreamPort.isFocused(sessionId: sessionId) {
                    effectsStatePort.handleActiveSessionUI(
                        event.message,
                        sessionId: sessionId,
                        storeResult: eventStoreResult
                    )
                }
                appliedCatchUp = true
            }

            effectsStatePort.upsert(response.session)

            let trackedAfterEvents = focusedStreamPort.lastSeenSeq(sessionId: sessionId)
            if response.currentSeq > trackedAfterEvents {
                focusedStreamPort.applyCatchUpProgress(
                    sessionId: sessionId,
                    seq: response.currentSeq
                )
                appliedCatchUp = true
            }

            let persistedSeq = focusedStreamPort.lastSeenSeq(sessionId: sessionId)
            focusedStreamPort.persistSeq(persistedSeq, sessionId: sessionId)
            focusedStreamPort.persistEpoch(
                runtimeEpoch ?? response.runtimeEpoch,
                sessionId: sessionId
            )

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
        cachedEventCount: Int?,
        cachedLastEventId: String?,
        replayID: UUID?,
        allowFirstMessageFallback: Bool = true
    ) async -> TraceSignature? {
        guard let routeScope = resolveRouteScope() else {
            markSyncFailed()
            log.warning("Trace fetch skipped for \(self.sessionId): missing workspaceId")
            return nil
        }
        let workspaceId = routeScope.workspaceId
        let presentationReloadMarker = coalescer.presentationTraceReloadMarker

        let traceFetchStartedMs = ChatSessionRuntimeTelemetryTracker.nowMs()

        do {
            let session: Session
            let trace: [TraceEvent]
            let page: TracePageMetadata?
            if let fetchHook = _fetchSessionTraceForTesting {
                (session, trace) = try await fetchHook(routeScope, sessionId)
                page = nil
            } else {
                let snapshot = try await historyPort.fetchLatestTrace(
                    scope: routeScope,
                    sessionId: sessionId,
                    previewBytes: Self.tracePagePreviewBytes
                )
                session = snapshot.session
                trace = snapshot.trace
                page = snapshot.page
            }

            effectsStatePort.recordTelemetry(
                .traceFetch(
                    durationMs: max(
                        0,
                        ChatSessionRuntimeTelemetryTracker.nowMs() - traceFetchStartedMs
                    ),
                    workspaceId: workspaceId,
                    status: "ok",
                    eventCount: trace.count,
                    errorKind: nil
                ),
                sessionId: sessionId
            )

            guard !Task.isCancelled else { return nil }
            effectsStatePort.upsert(session)
            // History is an authoritative reducer-only apply. Unlike live
            // events, it may run while presentation is paused so a connect or
            // re-entry cannot leave the visible timeline blank. The coalescer
            // still prevents high-frequency live publication in that state.
            tracePage = page
            markSyncSucceeded()

            // `firstMessage` is a list-summary preview and may be truncated.
            // While execution is live, the focused stream owns the complete
            // user message, so an empty trace must not replace it with that
            // preview. Non-live sessions still need the fallback for sparse
            // imported or not-yet-persisted history.
            let sessionIsLive = session.status == .starting
                || session.status == .busy
                || session.status == .stopping
            let timelineTrace = Self.timelineTrace(
                from: trace,
                session: session,
                allowFirstMessageFallback: allowFirstMessageFallback && !sessionIsLive
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
            } else if timelineTrace.isEmpty, allowFirstMessageFallback, sessionIsLive {
                needsInitialScroll = true
                freshnessReason = "history_deferred_to_live"
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
                    let reducerStartMs = ChatSessionRuntimeTelemetryTracker.nowMs()
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
                    let reducerDurationMs = max(
                        0,
                        ChatSessionRuntimeTelemetryTracker.nowMs() - reducerStartMs
                    )

                    effectsStatePort.recordTelemetry(
                        .reducerLoad(
                            durationMs: reducerDurationMs,
                            source: usedFirstMessageFallback ? "history_first_message_fallback" : (usedReplay ? "history+replay" : "history"),
                            eventCount: timelineTrace.count,
                            itemCount: reducer.items.count
                        ),
                        sessionId: sessionId
                    )

                    needsInitialScroll = true
                    telemetry.recordSessionLoadIfNeeded(
                        path: usedFirstMessageFallback ? "first_message_fallback" : (usedReplay ? "full_reload" : "cache_miss"),
                        itemCount: reducer.items.count,
                        workspaceId: workspaceId
                    )
                    let footprint = effectsStatePort.currentMemoryFootprintMB()
                    log.warning("Loaded \(trace.count) fresh trace events for \(self.sessionId) [footprint=\(footprint ?? -1)MB, items=\(self.reducer.items.count), replay=\(usedReplay), firstMessageFallback=\(usedFirstMessageFallback)]")
                    effectsStatePort.recordLog(
                        .info,
                        message: "Session loaded",
                        metadata: [
                            "footprintMB": footprint.map(String.init) ?? "n/a",
                            "traceEvents": String(trace.count),
                            "timelineEvents": String(timelineTrace.count),
                            "timelineItems": String(self.reducer.items.count),
                            "sessionId": self.sessionId,
                            "replay": usedReplay ? "1" : "0",
                            "firstMessageFallback": usedFirstMessageFallback ? "1" : "0",
                        ]
                    )
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

            telemetry.recordFreshContentLagIfNeeded(
                reason: freshnessReason,
                workspaceId: workspaceId
            )

            Task { @MainActor [historyPort, sessionId] in
                await historyPort.saveCachedTrace(
                    sessionId: sessionId,
                    events: trace,
                    page: page
                )
            }

            // Overflow/paused-mutation recovery stays armed until this apply.
            coalescer.acknowledgePresentationTraceReload(ifMarker: presentationReloadMarker)
            return freshSignature
        } catch {
            effectsStatePort.recordTelemetry(
                .traceFetch(
                    durationMs: max(
                        0,
                        ChatSessionRuntimeTelemetryTracker.nowMs() - traceFetchStartedMs
                    ),
                    workspaceId: workspaceId,
                    status: "error",
                    eventCount: nil,
                    errorKind: effectsStatePort.telemetryErrorKind(for: error)
                ),
                sessionId: sessionId
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
    func loadOlderTracePage() async -> Bool {
        guard !isLoadingOlderTracePage else { return false }
        guard reducer.canPrependTracePage else { return false }
        guard let cursor = tracePage?.olderCursor, tracePage?.hasOlder == true else { return false }
        guard historyPort.canFetchRemoteHistory else { return false }
        guard let routeScope = resolveRouteScope() else {
            log.warning("Older trace page skipped for \(self.sessionId): missing workspaceId")
            return false
        }

        isLoadingOlderTracePage = true
        defer { isLoadingOlderTracePage = false }

        do {
            let response = try await historyPort.fetchOlderTracePage(
                scope: routeScope,
                sessionId: sessionId,
                cursor: cursor,
                previewBytes: Self.tracePagePreviewBytes
            )
            return applyPrependedTracePage(response)
        } catch {
            markSyncFailed()
            log.warning("Older trace page failed for \(self.sessionId): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func loadTracePageAround(entryId: String) async -> Bool {
        guard !reducer.items.contains(where: { $0.id == entryId }) else { return true }
        guard !isLoadingOlderTracePage else { return false }
        guard reducer.canPrependTracePage else { return false }
        guard historyPort.canFetchRemoteHistory else { return false }
        guard let routeScope = resolveRouteScope() else {
            log.warning("Trace page around skipped for \(self.sessionId): missing workspaceId")
            return false
        }

        isLoadingOlderTracePage = true
        defer { isLoadingOlderTracePage = false }

        do {
            let response = try await historyPort.fetchTracePageAround(
                scope: routeScope,
                sessionId: sessionId,
                entryId: entryId,
                previewBytes: Self.tracePagePreviewBytes
            )
            guard applyPrependedTracePage(response) else {
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
        _ response: ChatSessionTraceSnapshot
    ) -> Bool {
        guard !Task.isCancelled, let page = response.page else { return false }
        // Paged trace history has the same authoritative, reducer-only safety
        // as the initial cache/history apply. Keep deep-link outline targets
        // loadable while the scene is paused without publishing live events.
        if page.staleCursor {
            tracePage = nil
            scheduleHistoryReload(
                generation: connectionGeneration,
                cachedSignature: nil
            )
            return false
        }

        effectsStatePort.upsert(response.session)
        let didPrepend = reducer.prependTracePage(response.trace)
        guard didPrepend else { return false }
        if !response.session.status.isRunning {
            reducer.finalizeTerminalArtifactsAsInterrupted()
        }
        tracePage = page
        markSyncSucceeded()

        let cacheEvents = reducer.traceEventsForCache()
        Task { @MainActor [historyPort, sessionId] in
            await historyPort.saveCachedTrace(
                sessionId: sessionId,
                events: cacheEvents,
                page: page
            )
        }
        return didPrepend
    }

    private func scheduleHistoryReload(
        generation: Int,
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

        historyReloadTask = Task { @MainActor [weak self] in
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
            } else if self.historyPort.canFetchRemoteHistory {
                if let freshSignature = await self.loadHistory(
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
                    generation: generation
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
    func forceHistoryReload() async -> Bool {
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

        guard historyPort.canFetchRemoteHistory else {
            markSyncFailed()
            return false
        }

        markSyncStarted()
        let replayID = UUID()
        activeHistoryReplayID = replayID
        reducer.beginHistoryReplayBuffer(id: replayID)

        guard let freshSignature = await loadHistory(
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

    private func scheduleStateSync(generation: Int) {
        cancelStateSync()

        stateSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.connectionGeneration else { return }
            try? await self.focusedStreamPort.requestState()
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
        generation: Int
    ) {
        guard attempt < Self.presentationReloadMaxAttempts,
              generation == connectionGeneration,
              coalescer.needsPresentationTraceReload,
              !coalescer.isPresentationPaused else {
            return
        }

        let nextAttempt = attempt + 1
        let delay = presentationReloadRetryDelay(for: attempt)
        cancelPresentationReloadRetry()
        presentationReloadRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  let self,
                  generation == self.connectionGeneration,
                  self.coalescer.needsPresentationTraceReload,
                  !self.coalescer.isPresentationPaused else {
                return
            }

            self.presentationReloadRetryTask = nil
            self.scheduleHistoryReload(
                generation: generation,
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
    private func scheduleConnectAfterExternalOpen(generation: Int) {
        cancelAutoReconnect()
        let claimedSessionId = sessionId
        autoReconnectTask = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard self.focusedStreamPort.externalOpenClaimBlocks(sessionId: claimedSessionId) else { break }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.wantsAutoReconnect,
                  generation == self.connectionGeneration else {
                return
            }
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
        if let activeHistoryReplayID {
            reducer.discardHistoryReplayBuffer(id: activeHistoryReplayID)
            self.activeHistoryReplayID = nil
        }
    }

    private func disconnectIfCurrent(_ generation: Int) {
        guard generation == connectionGeneration else { return }
        // Only disconnect if WE are still the active session.
        // Without this check, when session B takes over the WS,
        // session A's cleanup would kill session B's connection,
        // causing a connect/disconnect ping-pong loop.
        guard focusedStreamPort.isFocused(sessionId: sessionId)
              || focusedStreamPort.focusedSessionId == nil else { return }
        focusedStreamPort.close()
    }
}

private final class StreamingWaiterBox {
    var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
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
