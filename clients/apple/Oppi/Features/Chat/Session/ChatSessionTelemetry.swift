import CoreFoundation
import Foundation

/// Fire-and-forget telemetry helpers for chat runtime and nearby product flows.
///
/// Each method captures Sendable arguments and dispatches to
/// `ChatMetricsService.shared` on a utility-priority detached task.
/// This keeps feature code free of repetitive telemetry blocks that
/// obscure the actual control flow.
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

    static func recordTraceFetch(
        durationMs: Int64,
        sessionId: String,
        workspaceId: String?,
        status: String,
        traceEventCount: Int? = nil,
        errorKind: String? = nil
    ) {
        var tags = ["status": status]
        if let traceEventCount {
            tags["trace_events"] = String(traceEventCount)
        }
        if let errorKind {
            tags["error_kind"] = errorKind
        }
        emit(
            .traceFetchMs, Double(durationMs), .ms,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: tags
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

    // MARK: - Shared helpers

    static func recordTimingMetric(
        _ metric: ChatMetricName,
        durationMs: Int64,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        tags: [String: String] = [:]
    ) {
        emit(
            metric,
            Double(max(0, durationMs)),
            .ms,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: tags
        )
    }

    static func recordCountMetric(
        _ metric: ChatMetricName,
        value: Int = 1,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        tags: [String: String] = [:]
    ) {
        emit(
            metric,
            Double(max(0, value)),
            .count,
            sessionId: sessionId,
            workspaceId: workspaceId,
            tags: tags
        )
    }

    static func metricErrorKind(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }

        if let quickSessionError = error as? QuickSessionError {
            switch quickSessionError {
            case .noConnection:
                return "no_connection"
            case .noWorkspace:
                return "no_workspace"
            }
        }

        if let shareSessionError = error as? ShareSessionRequestError {
            switch shareSessionError {
            case .timedOut:
                return "timeout"
            case .failed:
                return "request_failed"
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "network"
            case .cancelled:
                return "cancelled"
            default:
                return "url_error"
            }
        }

        if error is DecodingError {
            return "decode"
        }

        return "other"
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
