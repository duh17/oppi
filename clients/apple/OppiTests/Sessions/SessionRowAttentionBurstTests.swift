import Testing
import UIKit
@testable import Oppi

/// A row's icon plays one short burst for each attention it shows, and then
/// rests on its still drawing: when the session starts needing the person, and
/// when the row appears already needing them. A reload of the same attention,
/// every other pass over the row, and a working session leave it still.
@MainActor
@Suite("Session row attention burst")
struct SessionRowAttentionBurstTests {
    private func session(
        _ id: String,
        _ kind: SessionStatusKind,
        agentIcon: IconChoice? = .symbol("sparkles", effect: .bounce)
    ) -> Session {
        var session = Session(
            id: id,
            workspaceId: "ws",
            name: "Build the thing",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        let since = Date(timeIntervalSince1970: 2_000)
        session.launch = SessionLaunchMetadata(agentId: "agent-reviewer", agentIcon: agentIcon)
        switch kind {
        case .working:
            session.status = .busy
            session.currentTurnStartedAt = since
            session.programStatus = ProgramStatus(state: .working, since: since)
        case .error:
            session.programStatus = ProgramStatus(state: .error, since: since)
        default:
            session.programStatus = ProgramStatus(state: .idle, since: since)
        }
        return session
    }

    private func apply(_ session: Session, to row: SessionRowView) {
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session)),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        row.layoutIfNeeded()
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    /// Whether the row's icon currently owns a live layer over its still
    /// drawing, which is what a burst (or an idle symbol effect) looks like.
    private func isPlayingIcon(of row: SessionRowView) -> Bool {
        guard let badge = descendants(of: row, SessionGridBadgeView.self).first,
              let icon = badge.subviews.compactMap({ $0 as? IconChoiceUIView }).first else { return false }
        let shown = icon.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden }
        return shown.count > 1
    }

    private func makeRow(in window: UIWindow, id: String) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 70)
        if id.isEmpty == false { row.accessibilityIdentifier = id }
        window.addSubview(row)
        return row
    }

    private func makeWindow() -> UIWindow {
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.isHidden = false
        return window
    }

    @Test func theIconBurstsWhenTheSessionStartsNeedingThePerson() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let row = makeRow(in: window, id: "burst-transition")

        apply(session("transition", .idle), to: row)
        #expect(!isPlayingIcon(of: row), "a session at rest leaves the icon still")

        apply(session("transition", .error), to: row)
        #expect(isPlayingIcon(of: row), "the icon plays when the row starts needing the person")
    }

    @Test func aRowDisplayedNeedingThePersonBurstsWhenItAppears() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 70)

        // Configured off screen, as a list cell is before the list shows it.
        apply(session("appears", .error), to: row)
        #expect(!isPlayingIcon(of: row), "nothing plays before the row is on screen")

        window.addSubview(row)
        #expect(isPlayingIcon(of: row), "the icon plays as the row appears needing the person")
    }

    @Test func aReloadOfTheSameAttentionLeavesTheIconStill() async throws {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let row = makeRow(in: window, id: "burst-reload")
        let needing = session("reload", .error)

        apply(needing, to: row)
        #expect(isPlayingIcon(of: row))
        // The burst is bounded; let it finish before the reload.
        try await Task.sleep(for: IconChoiceUIView.burstDuration + .milliseconds(300))
        #expect(!isPlayingIcon(of: row), "the burst ends on its own")

        apply(needing, to: row)
        #expect(!isPlayingIcon(of: row), "a reload of the same attention does not play again")
    }

    @Test func aReusedRowPlaysForTheSessionItNowShowsAndStopsOtherwise() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let row = makeRow(in: window, id: "burst-reuse")

        apply(session("first", .error), to: row)
        #expect(isPlayingIcon(of: row))
        // Another session that needs the person takes the reused row over.
        apply(session("second", .error), to: row)
        #expect(isPlayingIcon(of: row))
        // The attention clears: the burst stops and the icon rests.
        apply(session("second", .idle), to: row)
        #expect(!isPlayingIcon(of: row), "a row whose session stops needing the person holds still")
    }

    @Test func aWorkingSessionNeverBursts() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let row = makeRow(in: window, id: "burst-working")

        apply(session("working", .working), to: row)
        #expect(!isPlayingIcon(of: row))
        apply(session("working", .working), to: row)
        #expect(!isPlayingIcon(of: row))
    }

    /// Reduce Motion, Low Power Mode, and Auto-Play Animated Images off each
    /// hold the icon still; `playBurst()` and the idle animation both read the
    /// app's one motion policy.
    @Test func motionPolicyHoldsTheIconStill() {
        #expect(MotionPolicy.effective(setting: .full, reduceMotion: true) == .off)
        #expect(MotionPolicy.effective(setting: .full, lowPowerMode: true) == .off)
        #expect(MotionPolicy.effective(setting: .full, animatedImages: false) == .off)
        #expect(MotionPolicy.effective(setting: .full) == .full)
    }
}
