import Foundation
import Testing
@testable import Oppi

@Suite("SessionStatusPill")
struct SessionStatusPillTests {

    // MARK: - Variant derivation

    @Test func waitingWhenPendingPermissions() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 2)
        #expect(variant == .waiting)
    }

    @Test func waitingOverridesReadyStatus() {
        let variant = SessionPillVariant.from(status: .ready, pendingCount: 1)
        #expect(variant == .waiting)
    }

    @Test func waitingOverridesStoppedStatus() {
        let variant = SessionPillVariant.from(status: .stopped, pendingCount: 1)
        #expect(variant == .waiting)
    }

    @Test func workingWhenBusy() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 0)
        #expect(variant == .working)
    }

    @Test func workingWhenStarting() {
        let variant = SessionPillVariant.from(status: .starting, pendingCount: 0)
        #expect(variant == .working)
    }

    @Test func workingWhenStopping() {
        let variant = SessionPillVariant.from(status: .stopping, pendingCount: 0)
        #expect(variant == .working)
    }

    @Test func doneWhenReady() {
        let variant = SessionPillVariant.from(status: .ready, pendingCount: 0)
        #expect(variant == .done)
    }

    @Test func stoppedWhenStopped() {
        let variant = SessionPillVariant.from(status: .stopped, pendingCount: 0)
        #expect(variant == .stopped)
    }

    @Test func errorWhenError() {
        let variant = SessionPillVariant.from(status: .error, pendingCount: 0)
        #expect(variant == .error)
    }

    // MARK: - Ask variants

    @Test func questionWhenPendingAsk() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 0, pendingAskCount: 1)
        #expect(variant == .question)
    }

    @Test func questionOverridesReadyStatus() {
        let variant = SessionPillVariant.from(status: .ready, pendingCount: 0, pendingAskCount: 1)
        #expect(variant == .question)
    }

    @Test func waitingTakesPriorityOverQuestion() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 1, pendingAskCount: 1)
        #expect(variant == .waiting)
    }

    @Test func questionOverridesWorkingStatus() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 0, pendingAskCount: 1)
        #expect(variant == .question)
    }

    // MARK: - Backward compatibility (pendingAskCount defaults to 0)

    @Test func fromWithoutAskCount_busyWorking() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 0)
        #expect(variant == .working)
    }

    @Test func fromWithoutAskCount_waitingWhenPending() {
        let variant = SessionPillVariant.from(status: .busy, pendingCount: 1)
        #expect(variant == .waiting)
    }

    // MARK: - Labels

    @Test func labels() {
        #expect(SessionPillVariant.waiting.label == "Waiting")
        #expect(SessionPillVariant.question.label == "Question")
        #expect(SessionPillVariant.working.label == "Working")
        #expect(SessionPillVariant.done.label == "Done")
        #expect(SessionPillVariant.stopped.label == "Stopped")
        #expect(SessionPillVariant.error.label == "Error")
    }
}
