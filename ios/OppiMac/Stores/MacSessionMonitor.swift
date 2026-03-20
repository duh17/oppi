import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "MacSessionMonitor")

/// Polls `GET /server/stats` and exposes the latest stats to the UI.
///
/// Uses a Task-based sleep loop (not Timer) so cancellation is clean and
/// the polling rate can be toggled without timer invalidation ceremony.
///
/// Polling rates:
/// - Fast (popover open): every 3 seconds
/// - Background: every 30 seconds
@MainActor @Observable
final class MacSessionMonitor {

    // MARK: - Public state

    /// Latest stats response, nil before first successful fetch.
    var stats: ServerStats?
    /// True while the polling loop is running.
    var isPolling: Bool = false

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private var client: MacAPIClient?
    private var fastPolling: Bool = false

    private let fastInterval: Duration = .seconds(3)
    private let slowInterval: Duration = .seconds(30)

    // MARK: - Control

    /// Start polling with `client`. Safe to call multiple times — restarts if already running.
    func startPolling(client: MacAPIClient) {
        self.client = client
        isPolling = true
        restartLoop()
        logger.debug("Session monitor started (interval: \(self.fastPolling ? "3s" : "30s"))")
    }

    /// Stop polling and clear cached stats.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
        stats = nil
        logger.debug("Session monitor stopped")
    }

    /// Toggle between fast (3s) and slow (30s) polling.
    ///
    /// Call with `true` when the popover opens, `false` when it closes.
    func setFastPolling(_ fast: Bool) {
        guard fastPolling != fast else { return }
        fastPolling = fast
        if isPolling {
            restartLoop()
            logger.debug("Session monitor interval changed to \(fast ? "3s" : "30s")")
        }
    }

    // MARK: - Private

    private func restartLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        guard let client else { return }
        while !Task.isCancelled {
            let fetched = await client.fetchStats(range: 7)
            if !Task.isCancelled {
                stats = fetched
            }
            let interval = fastPolling ? fastInterval : slowInterval
            do {
                try await Task.sleep(for: interval)
            } catch {
                // Task cancelled — exit loop cleanly.
                break
            }
        }
    }
}
