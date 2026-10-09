import Foundation
import GhosttyVt
import Testing
@testable import Oppi

@Suite("SSH terminal attention", .serialized)
@MainActor
struct SSHTerminalAttentionTests {
    @Test func notificationsReachTheFeedAsSanitizedRemoteText() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}]9;Build finished\u{7}".utf8))
        let osc9 = try #require(engine.alerts.notification)
        #expect(osc9.title.isEmpty)
        #expect(osc9.body == "Build finished")

        engine.receive(Data("\u{1b}]777;notify;Claude;Needs \u{202e}approval\u{1b}\\".utf8))
        let osc777 = try #require(engine.alerts.notification)
        #expect(osc777.title == "Claude")
        #expect(osc777.body == "Needs approval")
        #expect(osc777.id == osc9.id, "back to back, the second updates the first")

        // OSC 9;4 is a progress report, not a notification.
        engine.receive(Data("\u{1b}]9;4;1;50\u{7}".utf8))
        #expect(engine.alerts.notification == osc777)
        #expect(engine.alerts.bell == nil)

        let feed = SSHTerminalAlertFeed()
        feed.notify(title: "\u{202e}", body: "")
        #expect(feed.notification == nil, "nothing left to read is not a notification")
    }

    @Test func aBurstOfBellsIsOneBell() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{7}".utf8))
        #expect(engine.alerts.bell?.source == .bell)
        #expect(engine.alerts.notification == nil)

        let feed = SSHTerminalAlertFeed()
        let start = ContinuousClock.now
        feed.ring(at: start)
        let first = try #require(feed.bell)
        feed.ring(at: start + .milliseconds(400))
        #expect(feed.bell == first)
        feed.ring(at: start + SSHTerminalNotice.burstInterval + .milliseconds(400))
        #expect(feed.bell != first)
    }

    /// `while true; do printf '\e]9;hello\a'; done` is one notification: it
    /// cannot undo a dismissal, and its text stays live.
    @Test func aNotificationFloodIsOneNotice() throws {
        let feed = SSHTerminalAlertFeed()
        var attention = SSHTerminalAttention()
        var clock = ContinuousClock.now
        func visible() -> SSHTerminalNotice? {
            attention.notice(from: SSHTerminalAttention.candidates(
                programStatus: SSHTerminalProgramStatusStore(), alerts: feed, isStopped: false
            ))
        }
        feed.notify(title: "", body: "hello 0", at: clock)
        let first = try #require(visible())
        attention.dismiss(first.key)
        for step in 1...50 {
            clock += .milliseconds(50)
            feed.notify(title: "", body: "hello \(step)", at: clock)
        }
        #expect(visible() == nil, "the flood stays folded")
        #expect(feed.notification?.body == "hello 50")

        clock += SSHTerminalNotice.burstInterval
        feed.notify(title: "", body: "hello 50", at: clock)
        #expect(visible() != nil, "the same words after a pause are a new notification")
    }

    /// A program waiting on the person outranks a one-shot notification, and
    /// each source folds away without bringing the other back.
    @Test func aWaitingProgramOutranksANotificationAndEachFoldsAwayOnItsOwn() throws {
        let store = SSHTerminalProgramStatusStore()
        let alerts = SSHTerminalAlertFeed()
        var attention = SSHTerminalAttention()
        func visible() -> SSHTerminalNotice? {
            attention.notice(from: SSHTerminalAttention.candidates(programStatus: store, alerts: alerts, isStopped: false))
        }
        var blocked = SSHTerminalProgramStatusStore.Report(state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED)
        blocked.kind = GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION
        blocked.message = "Allow rg?"

        alerts.notify(title: "", body: "Tests passed")
        let notification = try #require(visible())
        #expect(notification.slot == .alert)
        #expect(notification.lifetime != nil)

        store.apply(blocked)
        let waiting = try #require(visible())
        #expect(waiting.slot == .blocked)
        #expect(waiting.lifetime == nil)

        attention.dismiss(waiting.key)
        #expect(visible() == notification, "folding the blocked card uncovers the notification")
        attention.dismiss(notification.key)
        #expect(visible() == nil, "folding the notification keeps the blocked card down")

        let later = ContinuousClock.now + SSHTerminalNotice.burstInterval
        alerts.notify(title: "", body: "Tests passed", at: later)
        #expect(visible()?.slot == .alert, "the same text after a pause is a new notification")
        blocked.message = "Allow rm?"
        store.apply(blocked, at: later)
        #expect(visible()?.slot == .blocked, "a new blocked message after a pause outranks it again")
    }
}
