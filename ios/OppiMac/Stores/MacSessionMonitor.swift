import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "MacSessionMonitor")

/// Polls `/server/stats` and publishes the latest ``ServerStats`` to SwiftUI views.
///
/// Call ``startPolling(client:)`` to begin background polling (30 s interval).
/// Call ``setFastPolling(_:)`` with `true` when the popover is open (3 s interval)
/// and `false` when it closes to revert to background rate.
@MainActor
@Observable
final class MacSessionMonitor {

    // MARK: - Published state

    var stats: ServerStats?

    // MARK: - Private

    private var apiClient: MacAPIClient?
    private var pollingTask: Task<Void, Never>?
    private var isFastPolling = false

    // MARK: - API

    /// Configure the client and begin polling at the background (30 s) rate.
    func startPolling(client: MacAPIClient) {
        apiClient = client
        schedulePolling(fast: isFastPolling)
    }

    /// Switch between fast (3 s, popover open) and slow (30 s, background) polling.
    func setFastPolling(_ fast: Bool) {
        guard fast != isFastPolling else { return }
        isFastPolling = fast
        if apiClient != nil {
            schedulePolling(fast: fast)
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    private func schedulePolling(fast: Bool) {
        pollingTask?.cancel()
        let interval: TimeInterval = fast ? 3 : 30
        pollingTask = Task {
            // Fetch immediately so the popover has fresh data on open.
            await fetchStats()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await fetchStats()
            }
        }
    }

    private func fetchStats() async {
        guard let client = apiClient else { return }
        let fetched = await client.fetchStats(range: 7)
        stats = fetched
    }
}
