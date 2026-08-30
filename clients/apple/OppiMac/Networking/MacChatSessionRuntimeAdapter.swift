import Foundation
import OSLog

private let macChatSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacChatSession"
)

enum MacChatSessionRuntimeAdapterError: Error, Equatable, LocalizedError {
    case missingWorkspaceScope
    case streamUnavailable

    var errorDescription: String? {
        switch self {
        case .missingWorkspaceScope:
            "Missing workspace scope"
        case .streamUnavailable:
            ChatSessionFocusedStreamBindError.timedOut.errorDescription
        }
    }
}

/// Unix-socket composition adapter for the shared chat-session runtime.
///
/// History fetch, focused stream, and live command send use the owner Unix
/// socket with `sk_`. They must not send that token over HTTPS/WSS.
/// TimelineCache is iOS-only, so history cache is a no-op. Voice reply-mode
/// persists through `AppPreferenceStore`. Live WAV autoplay uses
/// `MacVoiceReplyPlayer`; completed attachments stay tap-to-play on the Mac
/// AVPlayer Unix-socket range path. Composer dictation uses a separate
/// `/dictation/stream` Unix-socket WebSocket. Correlated `command_result`
/// request IDs are consumed so they stay off the timeline. Ask/queue chrome
/// still comes from live effects.
@MainActor
final class MacChatSessionRuntimeAdapter:
    ChatSessionHistoryPort,
    ChatSessionFocusedStreamPort,
    ChatSessionEffectsStatePort
{
    let client: MacWorkspaceClient
    private let token: String
    weak var liveSessionOwner: MacSessionTraceStore?

    private var sessionsById: [String: Session] = [:]
    private var activeSessionIdValue: String?
    private var focusedSessionIdValue: String?
    private var liveTransport: MacUnixWebSocketTransport?
    private var terminalStreamConnectError = false
    private var catchUpTracker = SessionStreamCatchUpTracker()
    private var persistedSeq: [String: Int] = [:]
    private var persistedEpoch: [String: String] = [:]

    var _sendClientMessageForTesting: ((ClientMessage) async throws -> Bool)?
    private(set) var _recordedTelemetryForTesting: [ChatSessionRuntimeTelemetry] = []
    let voiceReplyPlayer: MacVoiceReplyPlayer
    var screenAwakeController: MacScreenAwakeController

    init(
        client: MacWorkspaceClient,
        token: String,
        voiceReplyPlayer: MacVoiceReplyPlayer = MacVoiceReplyPlayer(),
        screenAwakeController: MacScreenAwakeController = .shared
    ) {
        self.client = client
        self.token = token
        self.voiceReplyPlayer = voiceReplyPlayer
        self.screenAwakeController = screenAwakeController
    }

    /// Send on the focused Unix-socket stream. Throws when no live transport
    /// is bound; Mac commands do not fall back to HTTP.
    func send(_ message: ClientMessage) async throws {
        if let sendClientMessage = _sendClientMessageForTesting {
            let sent = try await sendClientMessage(message)
            guard sent else {
                throw MacChatSessionRuntimeAdapterError.streamUnavailable
            }
            return
        }
        guard let liveTransport else {
            throw MacChatSessionRuntimeAdapterError.streamUnavailable
        }
        try await liveTransport.send(.text(try message.jsonString()))
    }

    func makeFocusedStreamTransport(
        workspaceId: String,
        sessionId: String
    ) -> MacUnixWebSocketTransport {
        makeFocusedStreamTransport(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func makeFocusedStreamTransport(
        scope: SessionRouteScope,
        sessionId: String
    ) -> MacUnixWebSocketTransport {
        MacUnixWebSocketTransport(
            socketPath: client.socketPath,
            path: MacUnixWebSocketTransport.focusedSessionPath(
                scope: scope,
                sessionId: sessionId
            ),
            headers: MacUnixWebSocketTransport.ownerHeaders(token: token)
        )
    }

    // MARK: - History/cache

    var canFetchRemoteHistory: Bool { true }
    var canFetchCatchUp: Bool { true }

    func loadCachedTrace(sessionId: String) async -> ChatSessionCachedTrace? {
        nil
    }

    func saveCachedTrace(
        sessionId: String,
        events: [TraceEvent],
        page: TracePageMetadata?
    ) async {}

    func fetchLatestTrace(
        scope: SessionRouteScope,
        sessionId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        try await fetchTracePage(
            scope: scope,
            sessionId: sessionId,
            previewBytes: previewBytes
        )
    }

    func fetchOlderTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        cursor: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        try await fetchTracePage(
            scope: scope,
            sessionId: sessionId,
            previewBytes: previewBytes,
            cursor: cursor
        )
    }

    func fetchTracePageAround(
        scope: SessionRouteScope,
        sessionId: String,
        entryId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot {
        try await fetchTracePage(
            scope: scope,
            sessionId: sessionId,
            previewBytes: previewBytes,
            aroundEntryId: entryId
        )
    }

    func fetchCatchUp(
        scope: SessionRouteScope,
        sessionId: String,
        since: Int
    ) async throws -> ChatSessionCatchUpResponse {
        try requireSupportedScope(scope)
        let response = try await client.getSessionEvents(
            scope: scope,
            sessionId: sessionId,
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

    var transportPath: ConnectionTransportPath { .unix }
    var fatalSetupError = false
    var focusedSessionId: String? { focusedSessionIdValue }
    var isBindTerminal: Bool { terminalStreamConnectError }

    func focus(sessionId: String) {
        terminalStreamConnectError = false
        focusedSessionIdValue = sessionId
    }

    func open(
        sessionId: String,
        scope: SessionRouteScope
    ) async -> AsyncStream<SessionStreamEvent>? {
        terminalStreamConnectError = false
        do {
            try requireSupportedScope(scope)
        } catch {
            return nil
        }
        close()
        focusedSessionIdValue = sessionId

        let transport = makeFocusedStreamTransport(
            scope: scope,
            sessionId: sessionId
        )
        do {
            try await transport.connect()
        } catch {
            terminalStreamConnectError = Self.isTerminalStreamConnectError(error)
            macChatSessionLogger.error(
                "Focused stream connect failed: \(error.localizedDescription, privacy: .public) terminal=\(self.terminalStreamConnectError, privacy: .public)"
            )
            transport.cancel()
            return nil
        }

        liveTransport = transport
        liveSessionOwner?.applyLiveRuntimeStreamAvailability(true)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                defer {
                    continuation.finish()
                    if self.liveTransport === transport {
                        self.liveTransport = nil
                        self.liveSessionOwner?.applyLiveRuntimeStreamAvailability(false)
                    }
                }
                do {
                    while !Task.isCancelled {
                        let message = try await transport.receive()
                        let text: String
                        switch message {
                        case .text(let value):
                            text = value
                        case .data(let data):
                            text = String(data: data, encoding: .utf8) ?? ""
                        }
                        guard !text.isEmpty else { continue }
                        let streamMessage: StreamMessage
                        do {
                            streamMessage = try StreamMessage.decode(from: text)
                        } catch {
                            macChatSessionLogger.error(
                                "Focused stream decode failed: \(error.localizedDescription, privacy: .public)"
                            )
                            continue
                        }
                        continuation.yield(
                            SessionStreamEvent(
                                sessionId: streamMessage.sessionId ?? sessionId,
                                message: streamMessage.message,
                                meta: InboundStreamMeta(
                                    seq: streamMessage.seq,
                                    currentSeq: streamMessage.currentSeq,
                                    runtimeEpoch: streamMessage.runtimeEpoch,
                                    receivedAtMs: ChatSessionRuntimeTelemetryTracker.nowMs(),
                                    transportPath: transportPath
                                )
                            )
                        )
                    }
                } catch {
                    macChatSessionLogger.debug(
                        "Focused stream ended: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                transport.cancel()
            }
        }
    }

    func close() {
        liveTransport?.cancel()
        liveTransport = nil
        focusedSessionIdValue = nil
        liveSessionOwner?.applyLiveRuntimeStreamAvailability(false)
    }

    func isFocused(sessionId: String) -> Bool {
        focusedSessionIdValue == sessionId
    }

    static func isTerminalStreamConnectError(_ error: any Error) -> Bool {
        guard let transportError = error as? WebSocketTransportError,
              case .upgradeRejected(let statusCode) = transportError else {
            return false
        }
        switch statusCode {
        case 401, 403, 404, 405:
            return true
        default:
            return false
        }
    }

    func setStreamRecovering(_ recovering: Bool, sessionId: String) {}

    func externalOpenClaimBlocks(sessionId: String) -> Bool {
        false
    }

    func setActiveSessionIdForTesting(_ sessionId: String) {
        focusedSessionIdValue = sessionId
    }

    func loadPersistedSeq(sessionId: String) -> Int {
        persistedSeq[sessionId] ?? 0
    }

    func persistSeq(_ seq: Int, sessionId: String) {
        persistedSeq[sessionId] = seq
    }

    func loadPersistedEpoch(sessionId: String) -> String? {
        persistedEpoch[sessionId]
    }

    func persistEpoch(_ epoch: String?, sessionId: String) {
        if let epoch, !epoch.isEmpty {
            persistedEpoch[sessionId] = epoch
        } else {
            persistedEpoch.removeValue(forKey: sessionId)
        }
    }

    func seedLastSeenSeq(sessionId: String, value: Int) {
        catchUpTracker.seedLastSeenSeq(sessionId: sessionId, value: value)
    }

    func seedRuntimeEpoch(sessionId: String, value: String?) {
        catchUpTracker.seedRuntimeEpoch(sessionId: sessionId, value: value)
    }

    func lastSeenSeq(sessionId: String) -> Int {
        catchUpTracker.lastSeenSeq(sessionId: sessionId)
    }

    func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        catchUpTracker.consumeLiveSeq(sessionId: sessionId, seq: seq)
    }

    func catchUpDecision(
        sessionId: String,
        currentSeq: Int,
        runtimeEpoch: String?
    ) -> SessionStreamCatchUpTracker.CatchUpDecision {
        catchUpTracker.catchUpDecision(
            sessionId: sessionId,
            currentSeq: currentSeq,
            runtimeEpoch: runtimeEpoch
        )
    }

    func applyCatchUpProgress(sessionId: String, seq: Int) {
        catchUpTracker.applyCatchUpProgress(sessionId: sessionId, seq: seq)
    }

    func requestState() async throws {
        guard let liveTransport else {
            throw MacChatSessionRuntimeAdapterError.streamUnavailable
        }
        try await liveTransport.send(.text(try ClientMessage.getState().jsonString()))
    }

    func setReconnectHandler(_ handler: (@MainActor () -> Void)?) {}

    // MARK: - Effects/state

    var activeSession: Session? {
        guard let activeSessionIdValue else { return nil }
        return sessionsById[activeSessionIdValue]
    }

    func session(id: String) -> Session? {
        sessionsById[id]
    }

    func upsert(_ session: Session) {
        sessionsById[session.id] = session
        liveSessionOwner?.applyLiveRuntimeSession(session)
    }

    func setActiveSessionId(_ sessionId: String) {
        activeSessionIdValue = sessionId
    }

    func resolveSessionReentryWorkspaceId(
        sessionId: String,
        workspaceIdHint: String?
    ) -> String? {
        sessionsById[sessionId]?.workspaceId ?? workspaceIdHint
    }

    func applySharedStoreUpdate(
        for message: ServerMessage,
        sessionId: String
    ) -> ChatSessionStoreUpdateResult {
        switch message {
        case .connected(let session):
            return applySessionUpdate(session, sessionId: sessionId)
        case .state(let session):
            return applySessionUpdate(session, sessionId: sessionId)
        case .sessionSummary(let summary):
            return applySessionUpdate(summary.session, sessionId: sessionId)
        case .agentStart:
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            return .notHandled
        case .agentSettled:
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            return .notHandled
        case .stopConfirmed:
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            return .notHandled
        case .stopFailed:
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            return .notHandled
        case .sessionEnded:
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            return .notHandled
        case .sessionDeleted(let deletedId):
            screenAwakeController.clearSessionActivity(sessionId: deletedId)
            return .notHandled
        default:
            return .notHandled
        }
    }

    func handleActiveSessionUI(
        _ message: ServerMessage,
        sessionId: String,
        storeResult: ChatSessionStoreUpdateResult
    ) {
        liveSessionOwner?.applyLiveRuntimeMessage(message, sessionId: sessionId)
    }

    func handleAudioStream(_ stream: AudioStreamMessage, sessionId: String) {
        voiceReplyPlayer.handleAudioStream(stream, sessionId: sessionId)
    }

    func applyVoiceReplyModeDetails(_ details: JSONValue?, sessionId: String) {
        AppPreferenceStore.Voice.applySessionReplyModeDetails(details, sessionId: sessionId)
    }

    func handleCommandResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) -> Bool {
        // Prompt/steer/follow-up, queue, and model/thinking acks are control-plane
        // responses. Consume them like iOS so the coalescer does not also write
        // a timeline error. Ask/queue chrome stays on live effects.
        switch command {
        case "prompt", "steer", "follow_up",
             "get_queue", "set_queue",
             "set_model", "cycle_model",
             "set_thinking_level", "cycle_thinking_level":
            return true
        default:
            return requestId != nil
        }
    }

    func refreshSessionState(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> Session {
        let snapshot = try await fetchLatestTrace(
            scope: scope,
            sessionId: sessionId,
            previewBytes: 4_096
        )
        upsert(snapshot.session)
        return snapshot.session
    }

    func applyFetchedSessionState(_ session: Session) {
        upsert(session)
    }

    func setTimelineActiveSessionId(_ sessionId: String) {}

    func emitTimelineSessionEnded(sessionId: String) {}

    func currentMemoryFootprintMB() -> Int? { nil }

    func recordTelemetry(_ event: ChatSessionRuntimeTelemetry, sessionId: String) {
        _recordedTelemetryForTesting.append(event)
        switch event {
        case .freshContentLag(let durationMs, let workspaceId, let reason, let cached, let transport):
            var metadata = [
                "sessionId": sessionId,
                "durationMs": String(durationMs),
                "reason": reason,
                "cached": cached ? "1" : "0",
                "transport": transport,
            ]
            if let workspaceId {
                metadata["workspaceId"] = workspaceId
            }
            recordLog(.info, message: "Fresh content lag", metadata: metadata)
        case .traceFetch(_, _, let status, _, _) where status == "error":
            liveSessionOwner?.noteHistoryLoadFailed()
        default:
            break
        }
    }

    func telemetryErrorKind(for error: any Error) -> String {
        String(describing: type(of: error))
    }

    func recordLog(
        _ level: ChatSessionRuntimeLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        let detail = metadata
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        switch level {
        case .info:
            macChatSessionLogger.info("\(message, privacy: .public) \(detail, privacy: .public)")
        case .error:
            macChatSessionLogger.error("\(message, privacy: .public) \(detail, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func fetchTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        previewBytes: Int,
        cursor: String? = nil,
        aroundEntryId: String? = nil
    ) async throws -> ChatSessionTraceSnapshot {
        try requireSupportedScope(scope)
        let page = try await client.getSessionTracePage(
            scope: scope,
            sessionId: sessionId,
            previewBytes: previewBytes,
            cursor: cursor,
            aroundEntryId: aroundEntryId
        )
        return ChatSessionTraceSnapshot(
            session: page.session,
            trace: page.trace,
            page: page.page
        )
    }

    private func applySessionUpdate(
        _ session: Session,
        sessionId: String
    ) -> ChatSessionStoreUpdateResult {
        let previous = sessionsById[sessionId]
        upsert(session)
        let didTransitionOutOfRunning =
            (previous?.status.isRunning ?? false) && session.status.isTerminal
        if session.status.isRunning {
            screenAwakeController.setSessionActivity(true, sessionId: session.id)
        } else if didTransitionOutOfRunning {
            screenAwakeController.setSessionActivity(false, sessionId: session.id)
        }
        return ChatSessionStoreUpdateResult(
            previousWorkspaceId: previous?.workspaceId,
            didTransitionOutOfRunning: didTransitionOutOfRunning
        )
    }

    private func workspaceId(from scope: SessionRouteScope) throws -> String {
        guard case .workspace(let workspaceId) = scope else {
            throw MacChatSessionRuntimeAdapterError.missingWorkspaceScope
        }
        let trimmed = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacChatSessionRuntimeAdapterError.missingWorkspaceScope
        }
        return trimmed
    }

    private func requireSupportedScope(_ scope: SessionRouteScope) throws {
        switch scope {
        case .control:
            return
        case .workspace:
            _ = try workspaceId(from: scope)
        }
    }
}

extension ChatSessionManager {
    convenience init(
        sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil,
        adapter: MacChatSessionRuntimeAdapter
    ) {
        self.init(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: routeScope,
            historyPort: adapter,
            focusedStreamPort: adapter,
            effectsStatePort: adapter,
            reducer: TimelineReducer(environment: .none),
            coalescer: DeltaCoalescer()
        )
    }
}
