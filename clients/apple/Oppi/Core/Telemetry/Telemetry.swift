import Foundation

/// The one way the app records a telemetry event.
///
/// `Telemetry.record(AppTimelineApply(durationMs: 6, items: 40, changed: 2))`.
/// Event names, fields, tag values, and emit bounds come from the generated
/// catalog types, so no call site passes a unit or builds a `[String: String]`.
/// `record` applies the catalog emit policy, then hands the event to
/// `TelemetryEventUploader` on a utility-priority task, so callers on the main
/// thread pay for a policy check and one task spawn.
enum Telemetry {
    /// Sees every event the catalog policy lets through, before the upload
    /// gate, so tests observe emit sites even though automated runs never
    /// upload. Task-local, so a test only sees events recorded inside its own
    /// task while other suites run in parallel. Nil in production.
    @TaskLocal static var _observerForTesting: (@Sendable (TelemetryEventPayload) -> Void)?

    static func record(
        _ event: some TelemetryEvent,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        timestampMs: Int64 = Date.nowMs()
    ) {
        // The generated policy reads the struct's typed members, so a dropped
        // event (most cell configures and applies) costs no dictionary,
        // sanitizing, or string building.
        guard event.passesEmitPolicy else { return }
        let fields = event.fieldValues
        // One non-finite field fails JSON encoding for the whole upload batch.
        guard fields.values.allSatisfy(\.isFinite) else { return }

        let payload = TelemetryEventPayload(
            event,
            fields: fields,
            ts: timestampMs,
            sessionId: Self.cleanID(sessionId),
            workspaceId: Self.cleanID(workspaceId)
        )
        _observerForTesting?(payload)

        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        Task.detached(priority: .utility) {
            await TelemetryEventUploader.shared.enqueue(payload)
        }
    }

    private static func cleanID(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(96))
    }
}
