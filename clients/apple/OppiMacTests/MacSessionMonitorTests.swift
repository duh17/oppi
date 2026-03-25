import Testing
import Foundation
@testable import Oppi

// MARK: - Helpers

/// Build a minimal ServerStats with given totals and active session count.
private func makeStats(
    sessions: Int = 0,
    cost: Double = 0,
    tokens: Int = 0,
    activeCount: Int = 0
) -> ServerStats {
    let activeSessions = (0..<activeCount).map { i in
        StatsActiveSession(
            id: "sess-\(i)",
            status: "idle",
            model: nil,
            cost: 0,
            name: nil,
            firstMessage: nil,
            workspaceName: nil,
            thinkingLevel: nil,
            parentSessionId: nil,
            contextTokens: nil,
            contextWindow: nil,
            createdAt: nil
        )
    }
    return ServerStats(
        memory: StatsMemory(heapUsed: 0, heapTotal: 0, rss: 0, external: 0),
        activeSessions: activeSessions,
        daily: [],
        modelBreakdown: [],
        workspaceBreakdown: [],
        totals: StatsTotals(sessions: sessions, cost: cost, tokens: tokens)
    )
}

// MARK: - Initial state

@Suite("MacSessionMonitor — initial state")
@MainActor
struct MacSessionMonitorInitialStateTests {

    @Test func initialStatsAreNil() {
        let monitor = MacSessionMonitor()
        #expect(monitor.stats == nil)
    }

    @Test func initialSelectedRangeIsSeven() {
        let monitor = MacSessionMonitor()
        #expect(monitor.selectedRange == 7)
    }
}

// MARK: - setFastPolling

@Suite("MacSessionMonitor — setFastPolling")
@MainActor
struct MacSessionMonitorFastPollingTests {

    @Test func setFastPollingNoOpWithoutClient() {
        let monitor = MacSessionMonitor()
        monitor.setFastPolling(true)
        // Should not crash or change state without a client.
        #expect(monitor._isFastPollingForTesting == true)
    }

    @Test func setFastPollingIgnoresDuplicateTrue() {
        let monitor = MacSessionMonitor()
        monitor.setFastPolling(true)
        #expect(monitor._isFastPollingForTesting == true)

        // Calling again with same value should be a no-op (guard).
        monitor.setFastPolling(true)
        #expect(monitor._isFastPollingForTesting == true)
    }

    @Test func setFastPollingIgnoresDuplicateFalse() {
        let monitor = MacSessionMonitor()
        // Default is false.
        monitor.setFastPolling(false)
        #expect(monitor._isFastPollingForTesting == false)
    }

    @Test func setFastPollingToggles() {
        let monitor = MacSessionMonitor()
        #expect(monitor._isFastPollingForTesting == false)

        monitor.setFastPolling(true)
        #expect(monitor._isFastPollingForTesting == true)

        monitor.setFastPolling(false)
        #expect(monitor._isFastPollingForTesting == false)
    }
}

// MARK: - stopPolling

@Suite("MacSessionMonitor — stopPolling")
@MainActor
struct MacSessionMonitorStopPollingTests {

    @Test func stopPollingIsIdempotent() {
        let monitor = MacSessionMonitor()
        monitor.stopPolling()
        monitor.stopPolling()
        // Should not crash.
        #expect(monitor.stats == nil)
    }

    @Test func stopPollingAfterStartCleansUp() {
        let monitor = MacSessionMonitor()
        let client = MacAPIClient(
            baseURL: URL(string: "https://localhost:9999")!,
            token: "test"
        )
        monitor.startPolling(client: client)
        monitor.stopPolling()
        // Stats remain whatever they were — stopPolling only cancels the task.
        #expect(monitor.stats == nil)
    }
}

// MARK: - shouldSkipUpdate (deduplication)

@Suite("MacSessionMonitor — shouldSkipUpdate")
@MainActor
struct MacSessionMonitorDedupTests {

    @Test func skipWhenTotalsAndActiveCountMatch() {
        let a = makeStats(sessions: 5, cost: 12.50, tokens: 1000, activeCount: 2)
        let b = makeStats(sessions: 5, cost: 12.50, tokens: 1000, activeCount: 2)

        #expect(MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }

    @Test func noSkipWhenSessionCountDiffers() {
        let a = makeStats(sessions: 5)
        let b = makeStats(sessions: 6)

        #expect(!MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }

    @Test func noSkipWhenCostDiffers() {
        let a = makeStats(cost: 10.0)
        let b = makeStats(cost: 10.01)

        #expect(!MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }

    @Test func noSkipWhenTokensDiffer() {
        let a = makeStats(tokens: 1000)
        let b = makeStats(tokens: 1001)

        #expect(!MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }

    @Test func noSkipWhenActiveSessionCountDiffers() {
        let a = makeStats(activeCount: 1)
        let b = makeStats(activeCount: 2)

        #expect(!MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }

    @Test func skipWithZeroTotals() {
        let a = makeStats()
        let b = makeStats()

        #expect(MacSessionMonitor.shouldSkipUpdate(existing: a, fetched: b))
    }
}

// MARK: - selectedRange

@Suite("MacSessionMonitor — selectedRange")
@MainActor
struct MacSessionMonitorRangeTests {

    @Test func selectedRangeDefaultIsSeven() {
        let monitor = MacSessionMonitor()
        #expect(monitor.selectedRange == 7)
    }

    @Test func selectedRangeCanBeChanged() {
        let monitor = MacSessionMonitor()
        monitor.selectedRange = 30
        #expect(monitor.selectedRange == 30)
    }
}
