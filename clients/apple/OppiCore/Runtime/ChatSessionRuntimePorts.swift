import Foundation

/// Cached timeline state supplied to the shared chat runtime.
struct ChatSessionCachedTrace: Sendable {
    let eventCount: Int
    let lastEventId: String?
    let events: [TraceEvent]
    let page: TracePageMetadata?
}

/// An authoritative session trace page and its session projection.
struct ChatSessionTraceSnapshot: Sendable {
    let session: Session
    let trace: [TraceEvent]
    let page: TracePageMetadata?
}

/// Durable focused-stream events returned while repairing a sequence gap.
struct ChatSessionCatchUpResponse: Sendable {
    struct Event: Sendable {
        let seq: Int
        let message: ServerMessage
    }

    let events: [Event]
    let currentSeq: Int
    let runtimeEpoch: String?
    let session: Session
    let catchUpComplete: Bool

    init(
        events: [Event],
        currentSeq: Int,
        runtimeEpoch: String? = nil,
        session: Session,
        catchUpComplete: Bool
    ) {
        self.events = events
        self.currentSeq = currentSeq
        self.runtimeEpoch = runtimeEpoch
        self.session = session
        self.catchUpComplete = catchUpComplete
    }
}

/// Store context needed by timeline reconciliation after a live update.
struct ChatSessionStoreUpdateResult: Sendable {
    let previousWorkspaceId: String?
    let didTransitionOutOfRunning: Bool

    static let notHandled = Self(
        previousWorkspaceId: nil,
        didTransitionOutOfRunning: false
    )
}

enum ChatSessionRuntimeTelemetry: Sendable {
    case cacheLoad(durationMs: Int64, hit: Bool, eventCount: Int)
    case reducerLoad(durationMs: Int64, source: String, eventCount: Int, itemCount: Int)
    case catchUp(durationMs: Int64, result: String)
    case catchUpRingMiss(Bool)
    case sessionLoad(durationMs: Int64, workspaceId: String?, path: String, itemCount: Int)
    case freshContentLag(durationMs: Int64, workspaceId: String?, reason: String, cached: Bool, transport: String)
    case sessionSwitch(durationMs: Int64, cached: Bool)
    case timeToFirstToken(durationMs: Int64, tags: [String: String])
    case traceFetch(durationMs: Int64, workspaceId: String?, status: String, eventCount: Int?, errorKind: String?)
}

enum ChatSessionRuntimeLogLevel: Sendable {
    case info
    case error
}

enum ChatSessionFocusedStreamBindError: Error, Equatable, LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Live session stream is not connected."
        }
    }
}

/// Cached and remote history operations used by `ChatSessionManager`.
///
/// The port intentionally exposes trace-shaped operations rather than a general
/// HTTP client so the shared runtime cannot grow transport-specific behavior.
@MainActor
protocol ChatSessionHistoryPort: AnyObject {
    var canFetchRemoteHistory: Bool { get }
    var canFetchCatchUp: Bool { get }

    func loadCachedTrace(sessionId: String) async -> ChatSessionCachedTrace?
    func saveCachedTrace(
        sessionId: String,
        events: [TraceEvent],
        page: TracePageMetadata?
    ) async

    func fetchLatestTrace(
        scope: SessionRouteScope,
        sessionId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot

    func fetchOlderTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        cursor: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot

    func fetchTracePageAround(
        scope: SessionRouteScope,
        sessionId: String,
        entryId: String,
        previewBytes: Int
    ) async throws -> ChatSessionTraceSnapshot

    func fetchCatchUp(
        scope: SessionRouteScope,
        sessionId: String,
        since: Int
    ) async throws -> ChatSessionCatchUpResponse
}

/// Focused live-stream lifecycle and sequence tracking used by the runtime.
///
/// This is deliberately not a server-connection abstraction: it owns only one
/// focused stream, its durable sequence cursor, state requests, and reconnect
/// signal.
@MainActor
protocol ChatSessionFocusedStreamPort: AnyObject {
    var transportPath: ConnectionTransportPath { get }
    var fatalSetupError: Bool { get set }
    var focusedSessionId: String? { get }
    var isBindTerminal: Bool { get }

    func focus(sessionId: String)
    func open(
        sessionId: String,
        scope: SessionRouteScope
    ) async -> AsyncStream<SessionStreamEvent>?
    func close()
    func isFocused(sessionId: String) -> Bool
    func setStreamRecovering(_ recovering: Bool, sessionId: String)
    func externalOpenClaimBlocks(sessionId: String) -> Bool
    func setActiveSessionIdForTesting(_ sessionId: String)

    func loadPersistedSeq(sessionId: String) -> Int
    func persistSeq(_ seq: Int, sessionId: String)
    func loadPersistedEpoch(sessionId: String) -> String?
    func persistEpoch(_ epoch: String?, sessionId: String)
    func seedLastSeenSeq(sessionId: String, value: Int)
    func seedRuntimeEpoch(sessionId: String, value: String?)
    func lastSeenSeq(sessionId: String) -> Int
    func consumeLiveSeq(sessionId: String, seq: Int) -> Bool
    func catchUpDecision(
        sessionId: String,
        currentSeq: Int,
        runtimeEpoch: String?
    ) -> SessionStreamCatchUpTracker.CatchUpDecision
    func applyCatchUpProgress(sessionId: String, seq: Int)

    func requestState() async throws
    func send(_ message: ClientMessage) async throws
    func setReconnectHandler(_ handler: (@MainActor () -> Void)?)
}

extension ChatSessionFocusedStreamPort {
    func send(_ message: ClientMessage) async throws {
        throw ChatSessionFocusedStreamBindError.timedOut
    }
}

/// Shared session state and outward effects produced by the chat runtime.
///
/// iOS implements this port with its stores and UI/device services. The shared
/// manager emits semantic effects and never imports those implementations.
@MainActor
protocol ChatSessionEffectsStatePort: AnyObject {
    var activeSession: Session? { get }

    func session(id: String) -> Session?
    func upsert(_ session: Session)
    func setActiveSessionId(_ sessionId: String)
    func resolveSessionReentryWorkspaceId(
        sessionId: String,
        workspaceIdHint: String?
    ) -> String?

    func applySharedStoreUpdate(
        for message: ServerMessage,
        sessionId: String
    ) -> ChatSessionStoreUpdateResult
    func handleActiveSessionUI(
        _ message: ServerMessage,
        sessionId: String,
        storeResult: ChatSessionStoreUpdateResult
    )
    func handleAudioStream(_ stream: AudioStreamMessage, sessionId: String)
    func applyVoiceReplyModeDetails(_ details: JSONValue?, sessionId: String)
    func handleCommandResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) -> Bool

    func refreshSessionState(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> Session
    func applyFetchedSessionState(_ session: Session)

    func setTimelineActiveSessionId(_ sessionId: String)
    func emitTimelineSessionEnded(sessionId: String)
    func currentMemoryFootprintMB() -> Int?
    func recordTelemetry(_ event: ChatSessionRuntimeTelemetry, sessionId: String)
    func telemetryErrorKind(for error: any Error) -> String
    func recordLog(
        _ level: ChatSessionRuntimeLogLevel,
        message: String,
        metadata: [String: String]
    )
}
