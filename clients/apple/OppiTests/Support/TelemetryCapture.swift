import Foundation
@testable import Oppi

/// Collects the events `Telemetry.record` accepts while `run`'s body executes.
///
/// The observer is task-local, so a test sees only its own events even while
/// other suites record telemetry in parallel. It sits before the upload gate:
/// automated runs never upload, but emit sites are observable.
final class TelemetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TelemetryEventPayload] = []

    var events: [TelemetryEventPayload] {
        lock.withLock { recorded }
    }

    func events(named name: String) -> [TelemetryEventPayload] {
        events.filter { $0.name == name }
    }

    func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await Telemetry.$_observerForTesting.withValue({ [self] payload in
            lock.withLock { recorded.append(payload) }
        }, operation: {
            try await body()
        }, isolation: isolation)
    }

    /// Synchronous form for emit sites that need no suspension.
    func runSync<T>(_ body: () throws -> T) rethrows -> T {
        try Telemetry.$_observerForTesting.withValue({ [self] payload in
            lock.withLock { recorded.append(payload) }
        }) {
            try body()
        }
    }
}
