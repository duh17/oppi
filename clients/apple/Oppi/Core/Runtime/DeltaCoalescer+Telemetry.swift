import Foundation

extension DeltaCoalescerTelemetry {
    static let appMetrics = DeltaCoalescerTelemetry(
        recordFlushWindow: { window in
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushEvents,
                value: Double(window.eventCount),
                unit: .count,
                sessionId: window.sessionId,
                tags: ["flushes": String(window.flushCount)]
            )
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushBytes,
                value: Double(window.byteCount),
                unit: .count,
                sessionId: window.sessionId,
                tags: ["flushes": String(window.flushCount)]
            )
        },
        recordLargeTimelinePayload: { payload in
            MetricKitCrashContextStore.recordLargeTimelinePayload(
                sessionId: payload.sessionId,
                eventCount: payload.eventCount,
                bytes: payload.byteCount,
                largestEventBytes: payload.largestEventByteCount
            )
        }
    )
}
