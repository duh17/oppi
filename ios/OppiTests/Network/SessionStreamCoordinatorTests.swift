import Foundation
import Testing
@testable import Oppi

// MARK: - Catch-Up Decision Logic

@Suite("SessionStreamCoordinator Catch-Up Decision")
struct SessionStreamCoordinatorCatchUpTests {

    @Test func noGapWhenCurrentSeqEqualsLastSeen() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 10)

        #expect(decision == .noGap)
    }

    @Test func fetchSinceWhenCurrentSeqAhead() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 10)

        #expect(decision == .fetchSince(5))
    }

    @Test func seqRegressionWhenCurrentSeqBehind() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 5)

        #expect(decision == .seqRegression(resetTo: 5))
    }

    /// After seqRegression, lastSeen should be reset to currentSeq.
    /// Subsequent catchUpDecision with the same seq should show noGap.
    @Test func seqRegressionResetsLastSeenToCurrentSeq() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        _ = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 5)

        let lastSeen = await coordinator.lastSeenSeq(sessionId: "s1")
        #expect(lastSeen == 5, "After regression, lastSeen should be reset to currentSeq")

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 5)
        #expect(decision == .noGap, "Same seq after regression should be noGap")
    }

    /// Fresh session: lastSeen defaults to 0, server reports currentSeq 0.
    @Test func freshSessionWithCurrentSeqZeroGivesNoGap() async {
        let coordinator = SessionStreamCoordinator()

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 0)

        #expect(decision == .noGap)
    }

    /// Fresh session: lastSeen defaults to 0, server reports currentSeq > 0.
    /// Client missed all messages, needs to fetch from 0.
    @Test func freshSessionWithCurrentSeqAboveZeroGivesFetchSinceZero() async {
        let coordinator = SessionStreamCoordinator()

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 5)

        #expect(decision == .fetchSince(0))
    }

    /// Server restart scenario: had seq 10, server comes back with seq 0.
    @Test func seqRegressionToZero() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 0)

        #expect(decision == .seqRegression(resetTo: 0))
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 0)
    }

    /// Integration: subscribe -> receive messages -> reconnect -> catch-up.
    /// After consuming messages up to seq 8, reconnect sees currentSeq 12.
    @Test func catchUpAfterConsumedMessages() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)

        // Receive messages 6, 7, 8 during streaming
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 6)
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 7)
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 8)

        // Reconnect — server reports currentSeq 12
        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 12)

        // We last saw 8, server is at 12, fetch the gap
        #expect(decision == .fetchSince(8))
    }
}

// MARK: - consumeLiveSeq

@Suite("SessionStreamCoordinator consumeLiveSeq")
struct SessionStreamCoordinatorConsumeSeqTests {

    @Test func returnsTrueAndAdvancesForNewSeq() async {
        let coordinator = SessionStreamCoordinator()

        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 1)

        #expect(consumed)
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 1)
    }

    @Test func returnsFalseForDuplicateSeq() async {
        let coordinator = SessionStreamCoordinator()
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5)

        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5)

        #expect(!consumed, "Duplicate seq should be rejected")
    }

    @Test func returnsFalseForLowerSeq() async {
        let coordinator = SessionStreamCoordinator()
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 10)

        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5)

        #expect(!consumed, "Out-of-order (lower) seq should be rejected")
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10, "lastSeen should not regress")
    }

    /// Edge case: seq 0 on a fresh session (lastSeen defaults to 0).
    /// The guard is `seq > current`, so 0 > 0 is false.
    ///
    /// FINDING: seq 0 is never consumable on a fresh session. If the
    /// server uses 0-based seq numbering, the first message would be
    /// silently dropped. In practice servers appear to use 1-based seqs.
    @Test func returnsFalseForSeqZeroOnFreshSession() async {
        let coordinator = SessionStreamCoordinator()

        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 0)

        #expect(!consumed, "seq 0 rejected because guard requires seq > current (0)")
    }

    @Test func returnsTrueForSeq1OnFreshSession() async {
        let coordinator = SessionStreamCoordinator()

        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 1)

        #expect(consumed)
    }

    @Test func sequentialConsumptionWorks() async {
        let coordinator = SessionStreamCoordinator()

        for seq in 1...10 {
            let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: seq)
            #expect(consumed, "seq \(seq) should be consumed")
        }

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10)
    }

    /// Server may skip seqs (messages for other subscriptions or gaps).
    /// Any seq > current should be accepted.
    @Test func nonSequentialGapsAreAccepted() async {
        let coordinator = SessionStreamCoordinator()

        #expect(await coordinator.consumeLiveSeq(sessionId: "s1", seq: 1))
        #expect(await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5))
        #expect(await coordinator.consumeLiveSeq(sessionId: "s1", seq: 10))

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10)
    }

    /// After a regression resets lastSeen, previously-consumed seqs above
    /// the new baseline should be accepted again.
    @Test func consumeWorksAfterRegressionReset() async {
        let coordinator = SessionStreamCoordinator()

        // Consume up to seq 8
        for seq in 1...8 {
            _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: seq)
        }

        // Regression to 3
        _ = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 3)

        // Seq 5 was previously consumed, but after regression it's above baseline (3)
        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5)
        #expect(consumed, "After regression, seq 5 should be accepted (above new baseline 3)")
    }
}

// MARK: - Seq State Management

@Suite("SessionStreamCoordinator Seq State")
struct SessionStreamCoordinatorSeqStateTests {

    @Test func lastSeenSeqDefaultsToZero() async {
        let coordinator = SessionStreamCoordinator()

        #expect(await coordinator.lastSeenSeq(sessionId: "never-seen") == 0)
    }

    @Test func seedSetsValue() async {
        let coordinator = SessionStreamCoordinator()

        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 42)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 42)
    }

    @Test func seedOverwritesPreviousValue() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 20)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 20)
    }

    @Test func applyCatchUpProgressAdvancesForward() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)

        await coordinator.applyCatchUpProgress(sessionId: "s1", seq: 10)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10)
    }

    @Test func applyCatchUpProgressDoesNotRegress() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        await coordinator.applyCatchUpProgress(sessionId: "s1", seq: 5)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10, "applyCatchUpProgress should not decrease lastSeen")
    }

    @Test func applyCatchUpProgressNoOpForEqualSeq() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)

        await coordinator.applyCatchUpProgress(sessionId: "s1", seq: 10)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10)
    }

    /// Full lifecycle: seed -> consume -> apply catch-up -> catch-up decision
    @Test func fullLifecycleSequence() async {
        let coordinator = SessionStreamCoordinator()

        // 1. Subscribe, server reports currentSeq 5
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)

        // 2. Receive live messages 6, 7, 8
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 6)
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 7)
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 8)
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 8)

        // 3. Reconnect, server reports currentSeq 12
        let decision = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 12)
        #expect(decision == .fetchSince(8))

        // 4. Catch-up batch: apply progress for seqs 9, 10, 11, 12
        await coordinator.applyCatchUpProgress(sessionId: "s1", seq: 12)
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 12)

        // 5. Verify no gap after catch-up
        let decision2 = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 12)
        #expect(decision2 == .noGap)
    }
}

// MARK: - State Machine

@Suite("SessionStreamCoordinator State Machine")
struct SSCStateMachineTests {

    @Test func initialStateIsIdle() async {
        let coordinator = SessionStreamCoordinator()

        #expect(await coordinator.state == .idle)
    }

    @Test func noteStreamDisconnectedResetsToIdle() async {
        let coordinator = SessionStreamCoordinator()

        await coordinator.noteStreamDisconnected()

        #expect(await coordinator.state == .idle)
    }

    /// noteStreamDisconnected is valid from idle (.disconnected is in
    /// idle's allowed events). Should remain idle without logging a
    /// warning about unexpected transitions.
    @Test func noteStreamDisconnectedFromIdleStaysIdle() async {
        let coordinator = SessionStreamCoordinator()
        #expect(await coordinator.state == .idle)

        // Should not crash or produce unexpected behavior
        await coordinator.noteStreamDisconnected()
        await coordinator.noteStreamDisconnected()
        await coordinator.noteStreamDisconnected()

        #expect(await coordinator.state == .idle)
    }
}

// MARK: - Eager Command Resolution

@Suite("SessionStreamCoordinator Eager Resolution")
struct SSCEagerResolutionTests {

    @Test func subscribeIsEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(coordinator.shouldResolveEagerly(command: "subscribe"))
    }

    @Test func unsubscribeIsEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(coordinator.shouldResolveEagerly(command: "unsubscribe"))
    }

    @Test func getQueueIsEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(coordinator.shouldResolveEagerly(command: "get_queue"))
    }

    @Test func promptIsNotEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(!coordinator.shouldResolveEagerly(command: "prompt"))
    }

    @Test func getStateIsNotEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(!coordinator.shouldResolveEagerly(command: "get_state"))
    }

    @Test func emptyStringIsNotEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(!coordinator.shouldResolveEagerly(command: ""))
    }

    @Test func unknownCommandIsNotEager() {
        let coordinator = SessionStreamCoordinator()
        #expect(!coordinator.shouldResolveEagerly(command: "frobnicate"))
    }
}

// MARK: - Multi-Session Isolation

@Suite("SessionStreamCoordinator Multi-Session Isolation")
struct SSCMultiSessionTests {

    @Test func lastSeenSeqIndependentPerSession() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)
        await coordinator.seedLastSeenSeq(sessionId: "s2", value: 20)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 10)
        #expect(await coordinator.lastSeenSeq(sessionId: "s2") == 20)
        #expect(await coordinator.lastSeenSeq(sessionId: "s3") == 0)
    }

    @Test func consumeLiveSeqIndependentPerSession() async {
        let coordinator = SessionStreamCoordinator()
        _ = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 5)
        _ = await coordinator.consumeLiveSeq(sessionId: "s2", seq: 10)

        // Consuming for s1 should not affect s2
        let consumed = await coordinator.consumeLiveSeq(sessionId: "s1", seq: 6)
        #expect(consumed)
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 6)
        #expect(await coordinator.lastSeenSeq(sessionId: "s2") == 10)
    }

    @Test func catchUpDecisionIndependentPerSession() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)
        await coordinator.seedLastSeenSeq(sessionId: "s2", value: 15)

        let d1 = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 10)
        let d2 = await coordinator.catchUpDecision(sessionId: "s2", currentSeq: 10)

        #expect(d1 == .fetchSince(5), "s1: lastSeen 5, server at 10, need catch-up")
        #expect(d2 == .seqRegression(resetTo: 10), "s2: lastSeen 15, server at 10, regression")
    }

    @Test func applyCatchUpProgressIndependentPerSession() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 5)
        await coordinator.seedLastSeenSeq(sessionId: "s2", value: 5)

        await coordinator.applyCatchUpProgress(sessionId: "s1", seq: 20)

        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 20)
        #expect(await coordinator.lastSeenSeq(sessionId: "s2") == 5, "s2 should be unaffected")
    }

    /// Regression on one session should not affect another.
    @Test func regressionIsolatedPerSession() async {
        let coordinator = SessionStreamCoordinator()
        await coordinator.seedLastSeenSeq(sessionId: "s1", value: 10)
        await coordinator.seedLastSeenSeq(sessionId: "s2", value: 10)

        // Regress s1 to 3
        let d1 = await coordinator.catchUpDecision(sessionId: "s1", currentSeq: 3)
        #expect(d1 == .seqRegression(resetTo: 3))

        // s2 should be unaffected
        #expect(await coordinator.lastSeenSeq(sessionId: "s1") == 3)
        #expect(await coordinator.lastSeenSeq(sessionId: "s2") == 10)

        // s2 can still catch up normally
        let d2 = await coordinator.catchUpDecision(sessionId: "s2", currentSeq: 15)
        #expect(d2 == .fetchSince(10))
    }
}
