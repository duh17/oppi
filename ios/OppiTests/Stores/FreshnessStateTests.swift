import Foundation
import Testing
@testable import Oppi

@Suite("FreshnessState")
struct FreshnessStateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func deriveReturnsSyncingWhenInFlight() {
        let state = FreshnessState.derive(
            lastSuccessfulSyncAt: now.addingTimeInterval(-30),
            isSyncing: true,
            lastSyncFailed: false,
            staleAfter: 300,
            now: now
        )

        #expect(state == .syncing)
    }

    @Test func deriveReturnsOfflineAfterFailedAttempt() {
        let state = FreshnessState.derive(
            lastSuccessfulSyncAt: now.addingTimeInterval(-30),
            isSyncing: false,
            lastSyncFailed: true,
            staleAfter: 300,
            now: now
        )

        #expect(state == .offline)
    }

    @Test func deriveReturnsLiveForRecentSuccessfulSync() {
        let state = FreshnessState.derive(
            lastSuccessfulSyncAt: now.addingTimeInterval(-120),
            isSyncing: false,
            lastSyncFailed: false,
            staleAfter: 300,
            now: now
        )

        #expect(state == .live)
    }

    @Test func deriveReturnsStaleWhenLastSuccessTooOld() {
        let state = FreshnessState.derive(
            lastSuccessfulSyncAt: now.addingTimeInterval(-900),
            isSyncing: false,
            lastSyncFailed: false,
            staleAfter: 300,
            now: now
        )

        #expect(state == .stale)
    }

    @Test func updatedLabelFormatsRelativeTimestamp() {
        let label = FreshnessState.updatedLabel(
            lastSuccessfulSyncAt: now.addingTimeInterval(-125),
            now: now
        )

        #expect(label == "Updated 2m ago")
    }

    @Test func updatedLabelUsesNeverWhenNoSuccessTimestamp() {
        let label = FreshnessState.updatedLabel(lastSuccessfulSyncAt: nil, now: now)

        #expect(label == "Updated never")
    }
}
