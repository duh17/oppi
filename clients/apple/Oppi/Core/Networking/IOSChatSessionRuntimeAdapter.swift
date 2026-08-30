import Foundation

/// iOS composition adapter for the shared chat-session runtime.
///
/// It implements the three narrow runtime ports without exposing a general
/// `ServerConnection` surface to OppiCore. The adapter is rebound at each
/// existing iOS call boundary so callers keep the `ChatSessionManager` API.
@MainActor
final class IOSChatSessionRuntimeAdapter:
    ChatSessionHistoryPort,
    ChatSessionFocusedStreamPort,
    ChatSessionEffectsStatePort
{
    private weak var connection: ServerConnection?
    private weak var sessionStore: SessionStore?

    func bind(connection: ServerConnection, sessionStore: SessionStore) {
        self.connection = connection
        self.sessionStore = sessionStore
    }

    // MARK: - History/cache

    var canFetchRemoteHistory: Bool { connection?.apiClient != nil }
    var canFetchCatchUp: Bool { connection?.apiClient != nil }

    func loadCachedTrace(sessionId: String) async -> ChatSessionCachedTrace? {
        let cached: CachedTrace?
        if let serverId = connection?.currentServerId ?? sessionStore?.activeServerId {
            cached = await TimelineCache.shared.loadTrace(sessionId, serverId: serverId)
        } else {
            cached = await TimelineCache.shared.loadTrace(sessionId)
        }
        return cached.map {
            ChatSessionCachedTrace(
                eventCount: $0.eventCount,
                lastEventId: $0.lastEventId,
                events: $0.events,
                page: $0.page
            )
        }
    }

    func saveCachedTrace(
        sessionId: String,
        events: [TraceEvent],
        page: TracePageMetadata?
    ) async {
        if let serverId = connection?.currentServerId ?? sessionStore?.activeServerId {
            await TimelineCache.shared.saveTrace(
                sessionId,
                serverId: serverId,
                events: events,
                page: page
            )
        } else {
            await TimelineCache.shared.saveTrace(sessionId, events: events, page: page)
        }
    }

    func fetchLatestTrace(
        scope: SessionRouteScope,
        sessionId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        let api = try requireAPIClient()
        do {
            let response = try await api.getSessionTracePage(
                scope: scope,
                sessionId: sessionId,
                previewBytes: previewBytes
            )
            return Self.snapshot(response)
        } catch {
            guard Self.shouldFallbackToFullTrace(error) else { throw error }
            let fallback = try await api.getSession(
                scope: scope,
                sessionId: sessionId,
                traceView: .full
            )
            return ChatSessionTraceSnapshot(
                session: fallback.session,
                trace: fallback.trace,
                page: nil
            )
        }
    }

    func fetchOlderTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        cursor: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        let response = try await requireAPIClient().getSessionTracePage(
            scope: scope,
            sessionId: sessionId,
            cursor: cursor,
            previewBytes: previewBytes
        )
        return Self.snapshot(response)
    }

    func fetchTracePageAround(
        scope: SessionRouteScope,
        sessionId: String,
        entryId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        let response = try await requireAPIClient().getSessionTracePage(
            scope: scope,
            sessionId: sessionId,
            aroundEntryId: entryId,
            previewBytes: previewBytes
        )
        return Self.snapshot(response)
    }

    func fetchCatchUp(
        scope: SessionRouteScope,
        sessionId: String,
        since: Int
    ) async throws -> ChatSessionCatchUpResponse {
        let response = try await requireAPIClient().getSessionEvents(
            scope: scope,
            id: sessionId,
            since: since
        )
        return ChatSessionCatchUpResponse(
            events: response.events.map {
                ChatSessionCatchUpResponse.Event(seq: $0.seq, message: $0.message)
            },
            currentSeq: response.currentSeq,
            runtimeEpoch: response.runtimeEpoch,
            session: response.session,
            catchUpComplete: response.catchUpComplete
        )
    }

    // MARK: - Focused stream

    var transportPath: ConnectionTransportPath {
        connection?.transportPath ?? .paired
    }

    var fatalSetupError: Bool {
        get { connection?.fatalSetupError ?? false }
        set { connection?.fatalSetupError = newValue }
    }

    var focusedSessionId: String? { connection?.focusedSessionId }
    var isBindTerminal: Bool { connection?.isFocusedStreamBindTerminal() == true }

    func focus(sessionId: String) {
        connection?.focusSession(sessionId)
    }

    func open(
        sessionId: String,
        scope: SessionRouteScope
    ) async -> AsyncStream<SessionStreamEvent>? {
        await connection?.streamSession(sessionId, routeScope: scope)
    }

    func close() {
        connection?.disconnectSession()
    }

    func isFocused(sessionId: String) -> Bool {
        connection?.isFocusedSession(sessionId) == true
    }

    func setStreamRecovering(_ recovering: Bool, sessionId: String) {
        connection?.setFocusedSessionStreamRecovering(recovering, sessionId: sessionId)
    }

    func externalOpenClaimBlocks(sessionId: String) -> Bool {
        connection?.externalSessionOpenClaimBlocks(sessionId) == true
    }

    func setActiveSessionIdForTesting(_ sessionId: String) {
        connection?._setActiveSessionIdForTesting(sessionId)
    }

    func loadPersistedSeq(sessionId: String) -> Int {
        UserDefaults.standard.integer(forKey: Self.seqDefaultsKey(sessionId: sessionId))
    }

    func persistSeq(_ seq: Int, sessionId: String) {
        UserDefaults.standard.set(seq, forKey: Self.seqDefaultsKey(sessionId: sessionId))
    }

    func loadPersistedEpoch(sessionId: String) -> String? {
        UserDefaults.standard.string(forKey: Self.epochDefaultsKey(sessionId: sessionId))
    }

    func persistEpoch(_ epoch: String?, sessionId: String) {
        let key = Self.epochDefaultsKey(sessionId: sessionId)
        if let epoch, !epoch.isEmpty {
            UserDefaults.standard.set(epoch, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func seedLastSeenSeq(sessionId: String, value: Int) {
        connection?.sessionStreamCoordinator.seedLastSeenSeq(
            sessionId: sessionId,
            value: value
        )
    }

    func seedRuntimeEpoch(sessionId: String, value: String?) {
        connection?.sessionStreamCoordinator.seedRuntimeEpoch(
            sessionId: sessionId,
            value: value
        )
    }

    func lastSeenSeq(sessionId: String) -> Int {
        connection?.sessionStreamCoordinator.lastSeenSeq(sessionId: sessionId) ?? 0
    }

    func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        connection?.sessionStreamCoordinator.consumeLiveSeq(
            sessionId: sessionId,
            seq: seq
        ) ?? false
    }

    func catchUpDecision(
        sessionId: String,
        currentSeq: Int,
        runtimeEpoch: String?
    ) -> SessionStreamCatchUpTracker.CatchUpDecision {
        connection?.sessionStreamCoordinator.catchUpDecision(
            sessionId: sessionId,
            currentSeq: currentSeq,
            runtimeEpoch: runtimeEpoch
        ) ?? .noGap
    }

    func applyCatchUpProgress(sessionId: String, seq: Int) {
        connection?.sessionStreamCoordinator.applyCatchUpProgress(
            sessionId: sessionId,
            seq: seq
        )
    }

    func requestState() async throws {
        guard let connection else { throw URLError(.notConnectedToInternet) }
        try await connection.requestState()
    }

    func setReconnectHandler(_ handler: (@MainActor () -> Void)?) {
        connection?.silenceWatchdog.onReconnect = handler
    }

    // MARK: - Effects/state

    var activeSession: Session? { sessionStore?.activeSession }

    func session(id: String) -> Session? {
        sessionStore?.session(id: id)
    }

    func upsert(_ session: Session) {
        sessionStore?.upsert(session)
    }

    func setActiveSessionId(_ sessionId: String) {
        sessionStore?.activeSessionId = sessionId
    }

    func resolveSessionReentryWorkspaceId(
        sessionId: String,
        workspaceIdHint: String?
    ) -> String? {
        connection?.sessionReentryWorkspaceId(
            for: sessionId,
            workspaceIdHint: workspaceIdHint
        )
    }

    func applySharedStoreUpdate(
        for message: ServerMessage,
        sessionId: String
    ) -> ChatSessionStoreUpdateResult {
        guard let result = connection?.applySharedStoreUpdate(
            for: message,
            sessionId: sessionId
        ) else {
            return .notHandled
        }
        return ChatSessionStoreUpdateResult(
            previousWorkspaceId: result.previousWorkspaceId,
            didTransitionOutOfRunning: result.didTransitionOutOfRunning
        )
    }

    func handleActiveSessionUI(
        _ message: ServerMessage,
        sessionId: String,
        storeResult: ChatSessionStoreUpdateResult
    ) {
        let connectionResult = ServerConnection.StoreUpdateResult(
            stateContext: nil,
            handled: true
        )
        // State transition finalization is owned by the shared manager. The iOS
        // UI router only needs the previous workspace when refreshing commands.
        // Preserve it by handling state directly when present.
        if case .state(let session) = message {
            connection?.handleState(
                session,
                previousWorkspaceId: storeResult.previousWorkspaceId
            )
            connection?.applyCleanupEffects(
                for: message,
                sessionId: sessionId,
                isFocusedSession: true
            )
            return
        }
        if case .sessionSummary(let summary) = message {
            connection?.handleState(
                summary.session,
                previousWorkspaceId: storeResult.previousWorkspaceId
            )
            connection?.applyCleanupEffects(
                for: message,
                sessionId: sessionId,
                isFocusedSession: true
            )
            return
        }
        connection?.handleActiveSessionUI(
            message,
            sessionId: sessionId,
            storeResult: connectionResult
        )
    }

    func handleAudioStream(_ stream: AudioStreamMessage, sessionId: String) {
        connection?.audioPlayer.handleAudioStream(stream, sessionId: sessionId)
    }

    func applyVoiceReplyModeDetails(_ details: JSONValue?, sessionId: String) {
        AppPreferences.Voice.applySessionReplyModeDetails(details, sessionId: sessionId)
    }

    func handleCommandResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) -> Bool {
        connection?.handleCommandResult(
            command: command,
            requestId: requestId,
            success: success,
            data: data,
            error: error,
            sessionId: sessionId
        ) ?? false
    }

    func refreshSessionState(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> Session {
        let result = try await requireAPIClient().getSession(
            scope: scope,
            sessionId: sessionId
        )
        return result.session
    }

    func applyFetchedSessionState(_ session: Session) {
        connection?.applyFetchedSessionState(session)
    }

    func setTimelineActiveSessionId(_ sessionId: String) {
        ChatTimelinePerf.activeSessionId = sessionId
    }

    func emitTimelineSessionEnded(sessionId: String) {
        ChatTimelinePerf.emitJankRate(sessionId: sessionId, phase: "session_end")
    }

    func currentMemoryFootprintMB() -> Int? {
        AppDiagnosticsService.currentFootprintMB()
    }

    func recordTelemetry(_ event: ChatSessionRuntimeTelemetry, sessionId: String) {
        switch event {
        case .cacheLoad(let durationMs, let hit, let eventCount):
            ChatSessionTelemetry.recordCacheLoad(
                durationMs: durationMs,
                sessionId: sessionId,
                hit: hit,
                eventCount: eventCount
            )
        case .reducerLoad(let durationMs, let source, let eventCount, let itemCount):
            ChatSessionTelemetry.recordReducerLoad(
                durationMs: durationMs,
                sessionId: sessionId,
                source: source,
                eventCount: eventCount,
                itemCount: itemCount
            )
        case .catchUp(let durationMs, let result):
            ChatSessionTelemetry.recordCatchup(
                durationMs: durationMs,
                sessionId: sessionId,
                result: result
            )
        case .catchUpRingMiss(let missed):
            ChatSessionTelemetry.recordCatchupRingMiss(
                sessionId: sessionId,
                missed: missed
            )
        case .sessionLoad(let durationMs, let workspaceId, let path, let itemCount):
            ChatSessionTelemetry.recordSessionLoad(
                durationMs: durationMs,
                sessionId: sessionId,
                workspaceId: workspaceId,
                path: path,
                itemCount: itemCount
            )
        case .freshContentLag(let durationMs, let workspaceId, let reason, let cached, let transport):
            ChatSessionTelemetry.recordFreshContentLag(
                durationMs: durationMs,
                sessionId: sessionId,
                workspaceId: workspaceId,
                reason: reason,
                cached: cached,
                transport: transport
            )
        case .sessionSwitch(let durationMs, let cached):
            ChatSessionTelemetry.recordSessionSwitch(
                durationMs: durationMs,
                sessionId: sessionId,
                cached: cached
            )
        case .timeToFirstToken(let durationMs, let tags):
            ChatSessionTelemetry.recordTTFT(
                durationMs: durationMs,
                sessionId: sessionId,
                tags: tags
            )
        case .traceFetch(let durationMs, let workspaceId, let status, let eventCount, let errorKind):
            ChatSessionTelemetry.recordTraceFetch(
                durationMs: durationMs,
                sessionId: sessionId,
                workspaceId: workspaceId,
                status: status,
                traceEventCount: eventCount,
                errorKind: errorKind
            )
        }
    }

    func telemetryErrorKind(for error: any Error) -> String {
        ChatSessionTelemetry.metricErrorKind(for: error)
    }

    func recordLog(
        _ level: ChatSessionRuntimeLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        switch level {
        case .info:
            ClientLog.info("ChatSession", message, metadata: metadata)
        case .error:
            ClientLog.error("ChatSession", message, metadata: metadata)
        }
    }

    // MARK: - Helpers

    private func requireAPIClient() throws -> APIClient {
        guard let api = connection?.apiClient else {
            throw URLError(.notConnectedToInternet)
        }
        return api
    }

    private static func snapshot(
        _ response: APIClient.SessionTracePageResponse
    ) -> ChatSessionTraceSnapshot {
        ChatSessionTraceSnapshot(
            session: response.session,
            trace: response.trace,
            page: response.page
        )
    }

    /// Networking-boundary owner for iOS trace-page fallback. 404/405/409 mean
    /// the paged route is missing or stale; callers load a full session trace.
    static func shouldFallbackToFullTrace(_ error: any Error) -> Bool {
        guard case APIError.server(let status, _) = error else { return false }
        return status == 404 || status == 405 || status == 409
    }

    private static func seqDefaultsKey(sessionId: String) -> String {
        "chat.lastSeenSeq.\(sessionId)"
    }

    private static func epochDefaultsKey(sessionId: String) -> String {
        "chat.runtimeEpoch.\(sessionId)"
    }
}
