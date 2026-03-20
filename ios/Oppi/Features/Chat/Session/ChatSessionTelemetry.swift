import Foundation

/// Fire-and-forget telemetry helpers for ChatSessionManager.
///
/// Each method captures Sendable arguments and dispatches to
/// `ChatMetricsService.shared` on a utility-priority detached task.
/// This keeps the session lifecycle code free of 10-line telemetry
/// blocks that obscure the actual control flow.
enum ChatSessionTelemetry {

    // MARK: - Timing helpers

    static func nowMs() -> Int64 { ChatMetricsService.nowMs() }

    // MARK: - Connect / transport

    static func recordCacheLoad(
        durationMs: Int64,
        sessionId: String,
        hit: Bool,
        eventCount: Int
    ) {
        emit(
            .cacheLoadMs, Double(durationMs), .ms,
            sessionId: sessionId,
            tags: ["hit": hit ? "1" : "0", "events": String(eventCount)]
        )
    }

    static func recordReducerLoad(
        durationMs: Int64,
        sessionId: String,
        source: String,
        eventCount: Int,
        itemCount: Int
    ) {
        emit(
            .reducerLoadMs, Double(durationMs), .ms,
            sessionId: sessionId,
            tags: ["source": source, "events": String(eventCount), "items": String(itemCount)]
        )
    }

    static func recordWsConnect(
        durationMs: Int64,
        sessionId: String,
        transport: String
    ) {
        emit(
            .wsConnectMs, Double(durationMs), .ms,
            sessionId: sessionId,
            tags: ["transport": transport]
        )
    }

    static func recordConnectedDispatchLag(
        lagMs: Int64,
        sessionId: String,
        transport: String
    ) {
        emit(
            .connectedDispatchMs, Double(lagMs), .ms,
            sessionId: sessionId,
            tags: ["transport": transport]
        )
    }

    static func recordTTFT(
        durationMs: Int64,
        sessionId: String,
        tags: [String: String]
    ) {
        emit(.ttftMs, Double(durationMs), .ms, sessionId: sessionId, tags: tags)
    }

    static func recordFreshContentLag(
        durationMs: Int64,
        sessionId: String,
        workspaceId: String?,
        reason: String,
        cached: Bool,
        transport: String
    ) {
        emit(
            .freshContentLagMs, Double(durationMs), .ms,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: ["reason": reason, "cache": cached ? "1" : "0", "transport": transport]
        )
    }

    // MARK: - Catch-up

    static func recordCatchup(
        durationMs: Int64,
        sessionId: String,
        result: String
    ) {
        emit(.catchupMs, Double(durationMs), .ms, sessionId: sessionId, tags: ["result": result])
    }

    static func recordCatchupRingMiss(
        sessionId: String,
        missed: Bool
    ) {
        emit(.catchupRingMiss, missed ? 1 : 0, .count, sessionId: sessionId)
    }

    // MARK: - Session load (vital)

    static func recordSessionLoad(
        durationMs: Int64,
        sessionId: String,
        workspaceId: String?,
        path: String,
        itemCount: Int
    ) {
        emit(
            .sessionLoadMs, Double(durationMs), .ms,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: ["path": path, "items": String(itemCount)]
        )
    }

    // MARK: - History reload

    static func recordFullReload(
        durationMs: Int64,
        sessionId: String,
        workspaceId: String?,
        traceEventCount: Int
    ) {
        emit(
            .fullReloadMs, Double(durationMs), .ms,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: ["trace_events": String(traceEventCount)]
        )
    }

    // MARK: - Private

    private static func emit(
        _ metric: ChatMetricName,
        _ value: Double,
        _ unit: ChatMetricUnit,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        tags: [String: String] = [:]
    ) {
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: value,
                unit: unit,
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
        }
    }
}
