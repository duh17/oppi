import Foundation

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

    /// Currently selected time range in days. Changing this re-fetches immediately.
    var selectedRange: Int = 7 {
        didSet {
            guard oldValue != selectedRange, apiClient != nil else { return }
            schedulePolling(fast: isFastPolling)
        }
    }

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

    /// `GET /server/stats/daily/:date` through the same owner client as polling.
    func fetchDailyDetail(date: String) async -> DailyDetail? {
        guard let client = apiClient else { return nil }
        return await client.fetchDailyDetail(date: date)
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
        guard let fetched = await client.fetchStats(range: selectedRange) else { return }
        if let existing = stats, Self.shouldSkipUpdate(existing: existing, fetched: fetched) {
            return
        }
        stats = fetched
    }

    /// Deduplication check: skip only when totals and Home/menu-visible
    /// active-session fields are unchanged. Count alone is not enough —
    /// same-count status, identity, and display-field changes must publish.
    /// Extracted so unit tests can verify without hitting the network.
    static func shouldSkipUpdate(existing: ServerStats, fetched: ServerStats) -> Bool {
        existing.totals.sessions == fetched.totals.sessions
            && existing.totals.cost == fetched.totals.cost
            && existing.totals.tokens == fetched.totals.tokens
            && existing.activeSessions.elementsEqual(fetched.activeSessions) { lhs, rhs in
                lhs.id == rhs.id
                    && lhs.status == rhs.status
                    && lhs.model == rhs.model
                    && lhs.cost == rhs.cost
                    && lhs.name == rhs.name
                    && lhs.firstMessage == rhs.firstMessage
                    && lhs.workspaceName == rhs.workspaceName
                    && lhs.contextTokens == rhs.contextTokens
                    && lhs.contextWindow == rhs.contextWindow
            }
    }

    // MARK: - Test helpers

    #if DEBUG
    /// Test-only: set stats directly.
    func _setStatsForTesting(_ newStats: ServerStats?) { stats = newStats }

    /// Test-only: set client directly.
    func _setClientForTesting(_ client: MacAPIClient?) { apiClient = client }

    /// Test-only: read fast-polling flag.
    var _isFastPollingForTesting: Bool { isFastPolling }
    #endif
}
