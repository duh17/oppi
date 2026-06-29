import Foundation

/// Per-server sync state for freshness tracking.
struct ServerSyncState: Sendable {
    var lastSuccessfulSyncAt: Date?
    var isSyncing: Bool = false
    var lastSyncFailed: Bool = false

    // periphery:ignore - used by MultiServerStoreTests via @testable import
    var freshnessState: FreshnessState {
        freshnessState()
    }

    func freshnessState(now: Date = Date(), staleAfter: TimeInterval = 300) -> FreshnessState {
        FreshnessState.derive(
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            isSyncing: isSyncing,
            lastSyncFailed: lastSyncFailed,
            staleAfter: staleAfter,
            now: now
        )
    }

    func freshnessLabel(now: Date = Date()) -> String {
        FreshnessState.updatedLabel(lastSuccessfulSyncAt: lastSuccessfulSyncAt, now: now)
    }

    mutating func markSyncStarted() {
        isSyncing = true
    }

    mutating func markSyncSucceeded(at date: Date = Date()) {
        isSyncing = false
        lastSyncFailed = false
        lastSuccessfulSyncAt = date
    }

    mutating func markSyncFailed() {
        isSyncing = false
        lastSyncFailed = true
    }
}
