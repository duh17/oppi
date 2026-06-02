import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("SessionStatusPill")
struct SessionStatusPillTests {
    @Test func workingWhenBusy() {
        let variant = SessionPillVariant.from(status: .busy)
        #expect(variant == .working)
    }

    @Test func workingWhenStarting() {
        let variant = SessionPillVariant.from(status: .starting)
        #expect(variant == .working)
    }

    @Test func workingWhenStopping() {
        let variant = SessionPillVariant.from(status: .stopping)
        #expect(variant == .working)
    }

    @Test func doneWhenReady() {
        let variant = SessionPillVariant.from(status: .ready)
        #expect(variant == .done)
    }

    @Test func idleWhenBlankDraftReadySession() {
        let session = makeTestSession(status: .ready, messageCount: 0, firstMessage: nil)
        let variant = SessionPillVariant.from(session: session)
        #expect(variant == .idle)
    }

    @Test func idleWhenBlankDraftStartingSession() {
        let session = makeTestSession(status: .starting, messageCount: 0, firstMessage: nil)
        let variant = SessionPillVariant.from(session: session)
        #expect(variant == .idle)
    }

    @Test func nonBlankReadySessionStaysDone() {
        let session = makeTestSession(status: .ready, messageCount: 1, firstMessage: "Hello")
        let variant = SessionPillVariant.from(session: session)
        #expect(variant == .done)
    }

    @Test func stoppedWhenStopped() {
        let variant = SessionPillVariant.from(status: .stopped)
        #expect(variant == .stopped)
    }

    @Test func errorWhenError() {
        let variant = SessionPillVariant.from(status: .error)
        #expect(variant == .error)
    }

    @Test func questionWhenPendingAsk() {
        let variant = SessionPillVariant.from(status: .busy, pendingAskCount: 1)
        #expect(variant == .question)
    }

    @Test func questionOverridesReadyStatus() {
        let variant = SessionPillVariant.from(status: .ready, pendingAskCount: 1)
        #expect(variant == .question)
    }

    @Test func questionOverridesWorkingStatus() {
        let variant = SessionPillVariant.from(status: .busy, pendingAskCount: 1)
        #expect(variant == .question)
    }

    @Test func labels() {
        #expect(SessionPillVariant.question.label == "Question")
        #expect(SessionPillVariant.idle.label == "Idle")
        #expect(SessionPillVariant.working.label == "Working")
        #expect(SessionPillVariant.done.label == "Done")
        #expect(SessionPillVariant.stopped.label == "Stopped")
        #expect(SessionPillVariant.error.label == "Error")
    }

    @Test func doneAndIdleStayGreen() {
        #expect(UIColor(SessionPillVariant.done.foregroundColor) == UIColor(Color.themeGreen))
        #expect(UIColor(SessionPillVariant.idle.foregroundColor) == UIColor(Color.themeGreen))
    }
}
