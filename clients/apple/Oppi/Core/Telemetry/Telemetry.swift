import Foundation
import os
import UIKit

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

    /// `background` is the app's background record; tests pass their own.
    static func record(
        _ event: some TelemetryEvent,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        timestampMs: Int64 = Date.nowMs(),
        background: TelemetryBackgroundSpans = .shared
    ) {
        // The generated policy reads the struct's typed members, so a dropped
        // event (most cell configures and applies) costs no dictionary,
        // sanitizing, or string building.
        guard event.passesEmitPolicy else { return }
        let fields = event.fieldValues
        // One non-finite field fails JSON encoding for the whole upload batch.
        guard fields.values.allSatisfy(\.isFinite) else { return }
        // Wall-clock durations keep running while iOS suspends the app: one
        // that overlapped a trip to the background measured the suspension.
        if !type(of: event).spansBackground,
           let longestMs = fields.lazy.filter({ $0.key.hasSuffix("_ms") }).map(\.value).max(),
           background.overlaps(intervalMs: longestMs) {
            return
        }

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

/// When the app was last in the background, readable from any thread.
/// `Telemetry.record` asks whether a duration that ends now overlapped a
/// background period. App-level, not per scene: suspension follows the app.
final class TelemetryBackgroundSpans: Sendable {
    static let shared = TelemetryBackgroundSpans()

    /// Follows the app's background transitions from launch on. Call once, on
    /// the main thread, before any scene connects.
    @MainActor
    func observeApplication() {
        if UIApplication.shared.applicationState == .background { enteredBackground() }
        let center = NotificationCenter.default
        _ = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [self] _ in enteredBackground() }
        _ = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [self] _ in leftBackground() }
    }

    private struct State {
        var inBackground = false
        var leftBackgroundAt: ContinuousClock.Instant?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enteredBackground() {
        state.withLock { $0.inBackground = true }
    }

    func leftBackground(at now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            guard state.inBackground else { return }
            state.inBackground = false
            state.leftBackgroundAt = now
        }
    }

    /// Whether an interval of `intervalMs` ending at `now` overlapped a
    /// background period. While in the background, every interval does.
    func overlaps(intervalMs: Double, endingAt now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { state in
            if state.inBackground { return true }
            guard let leftAt = state.leftBackgroundAt else { return false }
            return leftAt > now - .milliseconds(intervalMs)
        }
    }
}
