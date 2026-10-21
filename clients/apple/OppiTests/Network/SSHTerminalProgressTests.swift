import Foundation
import GhosttyVt
import Testing
import UIKit
@testable import Oppi

private typealias Report = SSHTerminalProgressReport

@Suite("SSH terminal OSC 9;4 progress", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalProgressTests {
    private func osc(_ body: String) -> Data { Data("\u{1b}]9;4;\(body)\u{1b}\\".utf8) }

    // MARK: Store state machine

    @Test func reportStatesCarryTheirPercentAndTheRingFill() {
        #expect(Report(state: .set, percent: 40).fraction == 0.4)
        #expect(Report(state: .set, percent: 140).percent == 100)
        #expect(Report(state: .error, percent: 70).fraction == 0.7)
        // No position: an error or an indeterminate report spins, a pause is full.
        #expect(Report(state: .error, percent: nil).fraction == nil)
        #expect(Report(state: .indeterminate, percent: 55).percent == nil)
        #expect(Report(state: .indeterminate, percent: 55).fraction == nil)
        #expect(Report(state: .paused, percent: nil).fraction == 1)
        #expect(Report(state: .paused, percent: 30).fraction == 0.3)
    }

    @Test func eachReportReplacesTheLastAndRemoveClears() {
        let store = SSHTerminalProgressStore()
        store.apply(.init(state: .set, percent: 10))
        store.apply(.init(state: .set, percent: 40))
        #expect(store.report == Report(state: .set, percent: 40))
        store.apply(.init(state: .error, percent: nil))
        #expect(store.report == Report(state: .error, percent: nil))
        store.reset()
        #expect(store.report == nil)
    }

    @Test func aReportNotRenewedExpiresAfterTheTimeoutAndEveryReportRestartsIt() {
        let store = SSHTerminalProgressStore(timeout: .seconds(15))
        let start = ContinuousClock.now
        store.apply(.init(state: .set, percent: 20), at: start)
        #expect(!store.expireIfStale(at: start.advanced(by: .seconds(14))))
        #expect(store.report != nil)

        // A repeat of the same report is proof of life: the clock restarts.
        store.apply(.init(state: .set, percent: 20), at: start.advanced(by: .seconds(14)))
        #expect(!store.expireIfStale(at: start.advanced(by: .seconds(28))))
        #expect(store.report != nil)

        #expect(store.expireIfStale(at: start.advanced(by: .seconds(29))))
        #expect(store.report == nil)
        #expect(!store.expireIfStale(at: start.advanced(by: .seconds(60))))
    }

    @Test func theStaleTimerClearsTheReportByItself() async {
        let store = SSHTerminalProgressStore(timeout: .milliseconds(40))
        store.apply(.init(state: .indeterminate, percent: nil))
        #expect(store.report != nil)
        let giveUp = ContinuousClock.now.advanced(by: .seconds(10))
        while store.report != nil, ContinuousClock.now < giveUp {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.report == nil)
    }

    @Test func aResetBeforeTheDeadlineLeavesNoTimerToClearALaterReport() async {
        let store = SSHTerminalProgressStore(timeout: .milliseconds(150))
        store.apply(.init(state: .set, percent: 5))
        store.reset()
        store.apply(.init(state: .set, percent: 90))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(store.report == Report(state: .set, percent: 90))
    }

    // MARK: Engine bytes

    @Test func osc94ReportsReachTheStoreWithTheirStates() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(osc("1;40"))
        #expect(engine.progress.report == Report(state: .set, percent: 40))
        engine.receive(osc("1")) // A set with no number is 0, as libghostty parses it.
        #expect(engine.progress.report == Report(state: .set, percent: 0))
        engine.receive(osc("3"))
        #expect(engine.progress.report == Report(state: .indeterminate, percent: nil))
        engine.receive(osc("2"))
        #expect(engine.progress.report == Report(state: .error, percent: nil))
        engine.receive(osc("2;70"))
        #expect(engine.progress.report == Report(state: .error, percent: 70))
        engine.receive(osc("4"))
        #expect(engine.progress.report == Report(state: .paused, percent: nil))
        engine.receive(osc("4;60"))
        #expect(engine.progress.report == Report(state: .paused, percent: 60))
        engine.receive(osc("0"))
        #expect(engine.progress.report == nil)
    }

    @Test func aFullResetAndTheEndOfTheConnectionClearProgress() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(osc("1;40"))
        engine.receive(Data("\u{1b}c".utf8)) // RIS
        #expect(engine.progress.report == nil)

        engine.receive(osc("3"))
        #expect(engine.progress.report != nil)
        engine.close()
        #expect(engine.progress.report == nil)
        engine.receive(osc("1;50")) // A closed terminal hears nothing more.
        #expect(engine.progress.report == nil)
    }

    @Test func progressAndProgramStatusAreIndependent() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}]7501;state=working\u{1b}\\".utf8))
        engine.receive(osc("1;40"))
        #expect(engine.programStatus.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING)
        engine.receive(osc("0"))
        #expect(engine.programStatus.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING)
        engine.receive(osc("1;10"))
        engine.receive(Data("\u{1b}]7501;state=clear\u{1b}\\".utf8))
        #expect(engine.progress.report == Report(state: .set, percent: 10))
    }

    // MARK: Glyph

    @Test func theGlyphSpeaksProgressAlongsideStatusAndAloneIsNotAButton() {
        let glyph = SSHTerminalStatusGlyphButton()
        glyph.apply(
            status: nil, summary: "", themeID: .dark, reduceMotion: false, root: nil,
            progress: Report(state: .set, percent: 40)
        )
        #expect(glyph.accessibilityValue == "Progress 40%")
        #expect(!glyph.accessibilityTraits.contains(.button))
        #expect(!glyph.isUserInteractionEnabled)

        glyph.apply(
            status: .working, summary: "", themeID: .dark, reduceMotion: false, root: nil,
            progress: Report(state: .set, percent: 40)
        )
        #expect(glyph.accessibilityValue == "\(SessionStatusKind.working.label), Progress 40%")
        #expect(glyph.accessibilityTraits.contains(.button))
        #expect(glyph.isUserInteractionEnabled)

        glyph.apply(status: .working, summary: "", themeID: .dark, reduceMotion: false, root: nil, progress: nil)
        #expect(glyph.accessibilityValue == SessionStatusKind.working.label)
        #expect(Report(state: .paused, percent: 30).spokenValue == "Progress paused at 30%")
        #expect(Report(state: .error, percent: nil).spokenValue == "Progress failed")
        #expect(Report(state: .indeterminate, percent: nil).spokenValue == "Progress, in progress")
    }

    @Test func theRingFillsToThePercentSpinsWhenIndeterminateAndStaysStillUnderReducedMotion() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ring = SSHTerminalProgressRingView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        window.addSubview(ring)
        #expect(ring.isHidden)

        ring.apply(Report(state: .set, percent: 40), color: .blue, reduceMotion: false)
        #expect(!ring.isHidden)
        #expect(ring.drawnFraction == 0.4)
        #expect(!ring.isSpinning)

        ring.apply(Report(state: .indeterminate, percent: nil), color: .blue, reduceMotion: false)
        #expect(ring.isSpinning)

        ring.apply(Report(state: .indeterminate, percent: nil), color: .blue, reduceMotion: true)
        #expect(!ring.isSpinning)
        #expect(ring.drawnFraction == 1)

        ring.apply(Report(state: .paused, percent: nil), color: .orange, reduceMotion: false)
        #expect(!ring.isSpinning)
        #expect(ring.drawnFraction == 1)

        ring.apply(Report(state: .error, percent: nil), color: .red, reduceMotion: false)
        #expect(ring.isSpinning)

        ring.apply(nil, color: .red, reduceMotion: false)
        #expect(ring.isHidden)
        #expect(!ring.isSpinning)
    }
}
