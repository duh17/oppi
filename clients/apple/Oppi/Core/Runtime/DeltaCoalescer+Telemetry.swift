import Foundation

extension DeltaCoalescerTelemetry {
    static let appMetrics = DeltaCoalescerTelemetry(
        recordFlushWindow: { window in
            Telemetry.record(
                AppCoalescerWindow(
                    flushes: window.flushCount,
                    events: window.eventCount,
                    payloadBytes: window.byteCount
                ),
                sessionId: window.sessionId
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
