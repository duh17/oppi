import Foundation
import Testing
@testable import Oppi

@Suite("Focused session runtime policy")
struct FocusedSessionRuntimePolicyTests {
    @Test func stoppedSessionRefreshesHistoryBeforeAnyStream() {
        #expect(
            FocusedSessionConnectionPolicy.initialAction(for: .stopped)
                == .refreshHistoryBeforeStreamDecision
        )
    }

    @Test func activeOrUnknownSessionOpensStreamImmediately() {
        for status in [SessionStatus.starting, .ready, .busy, .stopping, .error, nil] {
            #expect(FocusedSessionConnectionPolicy.initialAction(for: status) == .openStream)
        }
    }

    @Test func refreshedStoppedSessionRemainsHistoryOnly() {
        #expect(
            FocusedSessionConnectionPolicy.actionAfterHistoryRefresh(for: .stopped)
                == .remainHistoryOnly
        )
    }

    @Test func refreshedNonStoppedSessionCanOpenStream() {
        for status in [SessionStatus.starting, .ready, .busy, .stopping, .error, nil] {
            #expect(
                FocusedSessionConnectionPolicy.actionAfterHistoryRefresh(for: status)
                    == .openStream
            )
        }
    }

    @Test func stopRequestedProducesStatusWithoutFinalization() {
        #expect(
            FocusedSessionStopTurnPolicy.timelineEffect(
                for: .stopRequested(source: .user, reason: nil)
            ) == .requested(message: "Stopping…")
        )
        #expect(
            FocusedSessionStopTurnPolicy.timelineEffect(
                for: .stopRequested(source: .user, reason: "Stopping current turn")
            ) == .requested(message: "Stopping current turn")
        )
    }

    @Test func stopConfirmedFinalizesBeforeShowingConfirmation() {
        #expect(
            FocusedSessionStopTurnPolicy.timelineEffect(
                for: .stopConfirmed(source: .user, reason: nil)
            ) == .confirmed(message: "Stop confirmed", finalizeTerminalArtifacts: true)
        )
    }

    @Test func stopFailureIsRenderedAsAnError() {
        #expect(
            FocusedSessionStopTurnPolicy.timelineEffect(
                for: .stopFailed(source: .timeout, reason: "Stop timed out")
            ) == .failed(message: "Stop failed: Stop timed out")
        )
    }

    @Test func unrelatedMessagesHaveNoStopTurnEffect() {
        #expect(FocusedSessionStopTurnPolicy.timelineEffect(for: .agentStart) == nil)
        #expect(FocusedSessionStopTurnPolicy.reconciliationDelay == .seconds(10))
    }
}
