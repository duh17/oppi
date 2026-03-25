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

    @Test func idleWhenReady() {
        let variant = SessionPillVariant.from(status: .ready, pendingCount: 0)
        #expect(variant == .idle)
    }

    @Test func doneWhenStopped() {
        let variant = SessionPillVariant.from(status: .stopped, pendingCount: 0)
        #expect(variant == .done)
    }

    @Test func errorWhenError() {
        let variant = SessionPillVariant.from(status: .error, pendingCount: 0)
        #expect(variant == .error)
    }

    // MARK: - Labels

    @Test func labels() {
        #expect(SessionPillVariant.waiting.label == "Waiting")
        #expect(SessionPillVariant.idle.label == "Idle")
        #expect(SessionPillVariant.working.label == "Working")
        #expect(SessionPillVariant.done.label == "Done")
        #expect(SessionPillVariant.error.label == "Error")
    }
}
