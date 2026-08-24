import Foundation
import Testing
@testable import Oppi

@Suite("SessionStreamCatchUpTracker — runtime epoch")
struct SessionStreamCatchUpEpochTests {

    @Test func epochMismatchReloadsInsteadOfCatchingUpFromOldSeq() {
        var tracker = SessionStreamCatchUpTracker()
        tracker.seedLastSeenSeq(sessionId: "s1", value: 500)
        tracker.seedRuntimeEpoch(sessionId: "s1", value: "epoch-a")

        let decision = tracker.catchUpDecision(
            sessionId: "s1",
            currentSeq: 600,
            runtimeEpoch: "epoch-b"
        )

        #expect(decision == .epochChanged(resetTo: 0))
        #expect(tracker.lastSeenSeq(sessionId: "s1") == 0)
        #expect(tracker.runtimeEpoch(sessionId: "s1") == "epoch-b")
    }

    @Test func sameEpochFetchesTheGap() {
        var tracker = SessionStreamCatchUpTracker()
        tracker.seedLastSeenSeq(sessionId: "s1", value: 10)
        tracker.seedRuntimeEpoch(sessionId: "s1", value: "epoch-a")

        let decision = tracker.catchUpDecision(
            sessionId: "s1",
            currentSeq: 18,
            runtimeEpoch: "epoch-a"
        )

        #expect(decision == .fetchSince(10))
        #expect(tracker.lastSeenSeq(sessionId: "s1") == 10)
    }

    @Test func missingStoredEpochReloads() {
        var tracker = SessionStreamCatchUpTracker()
        tracker.seedLastSeenSeq(sessionId: "s1", value: 500)

        let decision = tracker.catchUpDecision(
            sessionId: "s1",
            currentSeq: 600,
            runtimeEpoch: "epoch-new"
        )

        #expect(decision == .missingEpoch(resetTo: 0))
        #expect(tracker.lastSeenSeq(sessionId: "s1") == 0)
        #expect(tracker.runtimeEpoch(sessionId: "s1") == "epoch-new")
    }

    @Test func firstEpochObservationWithNoCursorFetchesFromZero() {
        var tracker = SessionStreamCatchUpTracker()

        let decision = tracker.catchUpDecision(
            sessionId: "s1",
            currentSeq: 12,
            runtimeEpoch: "epoch-a"
        )

        #expect(decision == .fetchSince(0))
        #expect(tracker.lastSeenSeq(sessionId: "s1") == 0)
        #expect(tracker.runtimeEpoch(sessionId: "s1") == "epoch-a")
    }

    @Test func epochChangeAcceptsNewRingBootstrapSeqs() {
        var tracker = SessionStreamCatchUpTracker()
        tracker.seedLastSeenSeq(sessionId: "s1", value: 500)
        tracker.seedRuntimeEpoch(sessionId: "s1", value: "epoch-a")

        let decision = tracker.catchUpDecision(
            sessionId: "s1",
            currentSeq: 12,
            runtimeEpoch: "epoch-b"
        )

        #expect(decision == .epochChanged(resetTo: 0))
        let acceptedBootstrap = tracker.consumeLiveSeq(sessionId: "s1", seq: 1)
        #expect(acceptedBootstrap)
        #expect(tracker.lastSeenSeq(sessionId: "s1") == 1)
    }

    @Test func omittedEpochKeepsSeqOnlyCompatibility() {
        var tracker = SessionStreamCatchUpTracker()
        tracker.seedLastSeenSeq(sessionId: "s1", value: 5)

        let decision = tracker.catchUpDecision(sessionId: "s1", currentSeq: 10)
        #expect(decision == .fetchSince(5))
    }
}
