import CoreFoundation
import Foundation

/// Fire-and-forget telemetry helpers for ChatSessionManager.
///
/// Each method captures Sendable arguments and dispatches to
/// `ChatMetricsService.shared` on a utility-priority detached task.
/// This keeps the session lifecycle code free of 10-line telemetry
/// blocks that obscure the actual control flow.
enum ChatSessionTelemetry {

    /// Process start timestamp for app launch metric.
    /// Static let is lazy (dispatch_once) — call `warmProcessStartTime()` from
    /// AppDelegate.didFinishLaunchingWithOptions to force capture before any views load.
    static let processStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    /// Force-evaluate `processStartTime`. Call once from AppDelegate.
    static func warmProcessStartTime() {
        _ = processStartTime
    }

    // MARK: - Timing helpers

    static func nowMs() -> Int64 { Date.nowMs() }

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

    // MARK: - App Launch

    static func recordAppLaunch() {
        let launchMs = Int64(max(0, (CFAbsoluteTimeGetCurrent() - processStartTime) * 1_000))
        emit(.appLaunchMs, Double(launchMs), .ms)
    }

    // MARK: - Session Switch

    static func recordSessionSwitch(
        durationMs: Int64,
        sessionId: String,
        cached: Bool
    ) {
        emit(
            .sessionSwitchMs, Double(durationMs), .ms,
            sessionId: sessionId,
            tags: ["cached": cached ? "1" : "0"]
        )
    }

    // MARK: - Permission Overlay

    static func recordPermissionOverlay(
        durationMs: Int64,
        sessionId: String,
        action: String
    ) {
        emit(
            .permissionOverlayMs, Double(durationMs), .ms,
            sessionId: sessionId,
            tags: ["action": action]
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
