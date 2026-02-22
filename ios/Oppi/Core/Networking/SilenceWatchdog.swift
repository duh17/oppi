import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SilenceWatchdog")

/// Monitors active streaming sessions for unexpected silence.
///
/// Two tiers:
/// 1. After `probeTimeout` (15s): fires `onProbe` to send a state request.
/// 2. After `reconnectTimeout` (45s): fires `onReconnect` — the WS receive
///    path is likely zombie (TCP alive but no frames delivered).
@MainActor
final class SilenceWatchdog {
    static let defaultProbeTimeout: Duration = .seconds(15)
    static let defaultReconnectTimeout: Duration = .seconds(45)

    var onProbe: (() async throws -> Void)?
    var onReconnect: (() -> Void)?

    private(set) var lastEventTime: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    private let probeTimeout: Duration
    private let reconnectTimeout: Duration

    init(
        probeTimeout: Duration = SilenceWatchdog.defaultProbeTimeout,
        reconnectTimeout: Duration = SilenceWatchdog.defaultReconnectTimeout
    ) {
        self.probeTimeout = probeTimeout
        self.reconnectTimeout = reconnectTimeout
    }

    /// Record that a meaningful event was received (resets the silence clock).
    func recordEvent() {
        lastEventTime = .now
    }

    /// Start monitoring. Cancels any existing watchdog task.
    func start() {
        lastEventTime = .now
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var probed = false
            while !Task.isCancelled {
                try? await Task.sleep(for: self.probeTimeout)
                guard !Task.isCancelled else { return }
                guard let lastEvent = self.lastEventTime else { break }

                let elapsed = ContinuousClock.now - lastEvent
                if elapsed >= self.reconnectTimeout {
                    logger.error("No events for \(elapsed) — forcing WS reconnect")
                    self.onReconnect?()
                    break
                } else if elapsed >= self.probeTimeout, !probed {
                    try? await self.onProbe?()
                    probed = true
                }
            }
        }
    }

    /// Stop monitoring and clear state.
    func stop() {
        task?.cancel()
        task = nil
        lastEventTime = nil
    }
}
