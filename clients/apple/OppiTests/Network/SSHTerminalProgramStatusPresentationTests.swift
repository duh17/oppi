import Foundation
import GhosttyVt
import Testing
@testable import Oppi

@Suite("SSH terminal program status presentation", .serialized)
@MainActor
struct SSHTerminalProgramStatusPresentationTests {
    private let since = Date(timeIntervalSince1970: 1_000)

    private func record(
        id: String = "",
        _ state: GhosttyProgramStatusState,
        kind: GhosttyProgramStatusKind = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
        app: String = "",
        title: String = "",
        message: String = ""
    ) -> SSHTerminalProgramStatusStore.Record {
        .init(
            id: id, state: state, kind: kind, progress: -1, app: app,
            title: title, message: message, revision: 1, since: since, notice: 1, reportedAt: .now
        )
    }

    private func report(
        _ state: GhosttyProgramStatusState, id: String = "", kind: GhosttyProgramStatusKind = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
        app: String = "", title: String = "", message: String = ""
    ) -> SSHTerminalProgramStatusStore.Report {
        var report = SSHTerminalProgramStatusStore.Report(state: state)
        report.kind = kind
        report.id = id
        report.app = app
        report.title = title
        report.message = message
        return report
    }

    @Test func eachGhosttyStateAndKindMapsOntoTheSharedStatus() {
        let states: [(GhosttyProgramStatusState, ProgramStatusState?)] = [
            (GHOSTTY_PROGRAM_STATUS_STATE_IDLE, .idle),
            (GHOSTTY_PROGRAM_STATUS_STATE_WORKING, .working),
            (GHOSTTY_PROGRAM_STATUS_STATE_DONE, .done),
            (GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, .blocked),
            (GHOSTTY_PROGRAM_STATUS_STATE_ERROR, .error),
            (GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, nil),
            (GHOSTTY_PROGRAM_STATUS_STATE_MAX_VALUE, nil),
        ]
        let kinds: [GhosttyProgramStatusKind] = [
            GHOSTTY_PROGRAM_STATUS_KIND_NONE,
            GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
            GHOSTTY_PROGRAM_STATUS_KIND_QUESTION,
            GHOSTTY_PROGRAM_STATUS_KIND_AUTH,
            GHOSTTY_PROGRAM_STATUS_KIND_MAX_VALUE,
        ]
        for (state, programState) in states {
            #expect(SSHTerminalProgramStatusPresentation.programState(state) == programState)
            for kind in kinds {
                let unseen = SSHTerminalProgramStatusPresentation.status(
                    state: state, kind: kind, since: since, seenAt: nil
                )
                let seen = SSHTerminalProgramStatusPresentation.status(
                    state: state, kind: kind, since: since, seenAt: since
                )
                switch state {
                case GHOSTTY_PROGRAM_STATUS_STATE_IDLE:
                    #expect(unseen == .idle)
                    #expect(seen == .idle)
                case GHOSTTY_PROGRAM_STATUS_STATE_WORKING:
                    #expect(unseen == .working)
                    #expect(seen == .working)
                case GHOSTTY_PROGRAM_STATUS_STATE_DONE:
                    #expect(unseen == .done)
                    #expect(seen == .idle)
                case GHOSTTY_PROGRAM_STATUS_STATE_ERROR:
                    #expect(unseen == .error)
                    #expect(seen == .idle)
                case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED:
                    let expected: SessionStatusKind = switch kind {
                    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: .needsApproval
                    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: .signIn
                    default: .question
                    }
                    #expect(unseen == expected)
                    #expect(seen == expected)
                default:
                    #expect(unseen == nil)
                    #expect(seen == nil)
                }
            }
        }
    }

    @Test func aStoppedSeenOutcomeReadsAsStopped() {
        let done = SSHTerminalProgramStatusPresentation.status(
            state: GHOSTTY_PROGRAM_STATUS_STATE_DONE, since: since, isStopped: true, seenAt: since
        )
        let unseen = SSHTerminalProgramStatusPresentation.status(
            state: GHOSTTY_PROGRAM_STATUS_STATE_ERROR, since: since, isStopped: true, seenAt: nil
        )
        #expect(done == .stopped)
        #expect(unseen == .error)
    }

    @Test func aTerminalTreeRollsUpWithoutCountingTheRootTwice() {
        let store = SSHTerminalProgramStatusStore()
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, app: "deploy"))
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, id: "eu", kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION))
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_DONE, id: "us"))
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "us/logs"))

        let unseen = SSHTerminalProgramStatusPresentation.rollup(store: store, isStopped: false, seenAt: .distantPast)
        #expect(unseen?.root == .working)
        #expect(unseen?.headline == .needsApproval)
        #expect(unseen?.count(.working) == 1) // the child, not the root
        #expect(unseen?.count(.needsApproval) == 1)
        #expect(unseen?.count(.done) == 1)
        #expect(unseen?.rootChipText == "Root: Working")
        #expect(unseen?.summaryText.contains("needs approval") == true)

        let seen = SSHTerminalProgramStatusPresentation.rollup(store: store, isStopped: false, seenAt: .distantFuture)
        #expect(seen?.headline == .needsApproval)
        #expect(seen?.count(.done) == 0)
        #expect(seen?.count(.idle) == 1)

        let empty = SSHTerminalProgramStatusStore()
        #expect(SSHTerminalProgramStatusPresentation.rollup(store: empty, isStopped: false, seenAt: nil) == nil)
    }

    @Test func aBlockedBannerKeepsRemoteTextOutOfTheHostLine() {
        let store = SSHTerminalProgramStatusStore()
        store.apply(report(
            GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
            title: "Not the host", message: "from Oppi\u{202e}\u{200b} Allow running rg?"
        ))
        store.apply(report(
            GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, id: "other", kind: GHOSTTY_PROGRAM_STATUS_KIND_QUESTION,
            message: "What next?"
        ))
        let notice = SSHTerminalProgramStatusPresentation.blockedNotice(store: store, isStopped: false, seenAt: nil)
        #expect(notice?.kind == .needsApproval)
        #expect(notice?.recordID == "")
        #expect(notice?.remoteText == "from Oppi Allow running rg?")
        #expect(notice?.remoteText.contains("\u{202e}") == false)
        #expect(SSHTerminalProgramStatusPresentation.hostCaption("evil\u{2028}from Oppi") == "evil from Oppi")
        #expect(SSHTerminalProgramStatusPresentation.blockedNotice(
            store: SSHTerminalProgramStatusStore(), isStopped: false, seenAt: nil
        ) == nil)
    }

    /// A dismissed card stays down while the same report repeats or the
    /// program rewrites its message in a burst, and comes back for a new
    /// message after a pause, a new kind, or a fresh blocked episode.
    @Test func aDismissedNoticeReturnsOnlyForANewBlockedReport() throws {
        let store = SSHTerminalProgramStatusStore()
        var clock = ContinuousClock.now
        func apply(_ report: SSHTerminalProgramStatusStore.Report, after delay: Duration = .milliseconds(100)) {
            clock += delay
            store.apply(report, at: clock)
        }
        func notice() -> SSHTerminalBlockedNotice? {
            SSHTerminalProgramStatusPresentation.blockedNotice(store: store, isStopped: false, seenAt: nil)
        }
        func key() -> SSHTerminalNotice.Key? { notice().map { SSHTerminalNotice.blocked($0).key } }
        func asking(_ message: String, kind: GhosttyProgramStatusKind = GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION)
            -> SSHTerminalProgramStatusStore.Report {
            report(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: kind, message: message)
        }

        apply(asking("Allow rg?"))
        let dismissed = try #require(key())

        apply(asking("Allow rg?"))
        #expect(key() == dismissed, "a repeated report keeps the card down")

        for step in 0..<20 { apply(asking("Allow rg? \(step)")) }
        #expect(key() == dismissed, "a message rewritten in a burst is the same notice")
        #expect(notice()?.remoteText == "Allow rg? 19", "its text stays live")

        apply(asking("Allow rm?"), after: SSHTerminalNotice.burstInterval)
        #expect(key() != dismissed, "a new message after a pause shows")

        let sameText = key()
        apply(asking("Allow rm?", kind: GHOSTTY_PROGRAM_STATUS_KIND_QUESTION))
        #expect(key() != sameText, "a new kind shows at once")

        let before = key()
        apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING))
        #expect(notice() == nil)
        apply(asking("Allow rm?", kind: GHOSTTY_PROGRAM_STATUS_KIND_QUESTION))
        #expect(key() != before, "blocked again after working is a new episode at once")
    }

    @Test func theSettleHoldEndsForAnyNewerStatus() {
        typealias Hold = SSHTerminalStatusHold
        let working = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_WORKING, revision: 1)
        let blocked = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, revision: 1)
        let done = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_DONE, revision: 2)
        let doneAgain = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_DONE, revision: 3)
        let error = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_ERROR, revision: 2)
        let idle = Hold.Root(state: GHOSTTY_PROGRAM_STATUS_STATE_IDLE, revision: 1)

        let held = Hold.next(nil, from: working, to: done, headline: .idle)
        #expect(held?.kind == .done)
        #expect(Hold.next(nil, from: blocked, to: error, headline: .idle)?.kind == .error)
        #expect(held?.duration ?? .zero < Hold.next(nil, from: working, to: error, headline: .idle)?.duration ?? .zero)

        // A repeat of the same report neither restarts nor clears it.
        #expect(Hold.next(held, from: done, to: doneAgain, headline: .idle) == held)
        // A headline-only change that stays at rest keeps it.
        #expect(Hold.next(held, from: done, to: done, headline: .idle) == held)

        // Anything newer ends it at once.
        #expect(Hold.next(held, from: done, to: done, headline: .working) == nil, "a child started working")
        #expect(Hold.next(held, from: done, to: done, headline: .needsApproval) == nil, "a child is blocked")
        #expect(Hold.next(held, from: done, to: done, headline: .stopped) == nil, "the connection closed")
        #expect(Hold.next(held, from: done, to: working, headline: .working) == nil)
        #expect(Hold.next(held, from: done, to: error, headline: .idle) == nil, "a different outcome report")
        #expect(Hold.next(held, from: done, to: nil, headline: .idle) == nil, "the root was cleared")

        // Only a run that just ended is held; an outcome that was already there is not.
        #expect(Hold.next(nil, from: idle, to: done, headline: .idle) == nil)
        #expect(Hold.next(nil, from: nil, to: done, headline: .idle) == nil)
        #expect(Hold.next(nil, from: working, to: done, headline: .working) == nil)
    }

    @Test func displayTextKeepsARunningLimitAcrossSeparatorsAndFormatCharacters() {
        let mixed = "ab\u{200b}c\u{2028}d\u{0001}e\u{2029}f"
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 0) == "")
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 5) == "abc d")
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 6) == "abc de")
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 7) == "abc de ")
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 8) == "abc de f")
        #expect(SSHTerminalDisplayText.sanitized(mixed, limit: 100) == "abc de f")
        let bounded = String(repeating: "m", count: SSHTerminalDisplayText.titleLimit + 40)
        #expect(SSHTerminalDisplayText.sanitized(bounded, limit: SSHTerminalDisplayText.titleLimit)
            == String(repeating: "m", count: SSHTerminalDisplayText.titleLimit))
    }

    /// A tower of combining marks would grow one line of the blocked card
    /// tall enough to cover the terminal and the composer.
    @Test func displayTextKeepsAtMostTwoCombiningMarksPerBase() {
        let tower = "a" + String(repeating: "\u{0301}", count: 40) + "b" + String(repeating: "\u{20DD}", count: 5)
        #expect(SSHTerminalDisplayText.sanitized(tower, limit: 120) == "a\u{0301}\u{0301}b\u{20DD}\u{20DD}")
        // A dropped format character between marks does not start a new base.
        #expect(SSHTerminalDisplayText.sanitized("e\u{0323}\u{200B}\u{0302}\u{0301}", limit: 120) == "e\u{0323}\u{0302}")
        // Real text with two marks is untouched: Vietnamese, and a keycap.
        #expect(SSHTerminalDisplayText.sanitized("Vi\u{0323}\u{0302}t 1\u{FE0F}\u{20E3}", limit: 120) == "Vi\u{0323}\u{0302}t 1\u{FE0F}\u{20E3}")
        // Dropped marks do not count toward the limit.
        #expect(SSHTerminalDisplayText.sanitized(tower, limit: 4) == "a\u{0301}\u{0301}b")
    }

    @Test func inputModePrefersTheRootRecordThenTheProbeThenHerdr() throws {
        let agent = record(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, app: "pi")
        let shell = record(GHOSTTY_PROGRAM_STATUS_STATE_IDLE, app: "fish")
        let other = record(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION, app: "terraform")
        let prefixed = record(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, app: "claude-code")
        let focused = try herdr(focused: true)
        let unfocused = try herdr(focused: false)

        #expect(SSHTerminalAgentDetector.mode(
            root: agent, app: "pi", foreground: .shell, herdr: unfocused
        ) == .chat)
        #expect(SSHTerminalAgentDetector.mode(
            root: prefixed, app: "claude-code", foreground: nil, herdr: nil
        ) == .chat)
        #expect(SSHTerminalAgentDetector.mode(
            root: shell, app: "fish", foreground: .agent("pi"), herdr: nil
        ) == .chat)
        #expect(SSHTerminalAgentDetector.mode(
            root: other, app: "terraform", foreground: .shell, herdr: nil
        ) == .terminal)
        #expect(SSHTerminalAgentDetector.mode(
            root: nil, app: "", foreground: .herdr, herdr: focused
        ) == .chat)
        #expect(SSHTerminalAgentDetector.mode(
            root: nil, app: "", foreground: .herdr, herdr: unfocused
        ) == .terminal)
        #expect(SSHTerminalAgentDetector.mode(
            root: nil, app: "", foreground: nil, herdr: focused
        ) == nil)
        #expect(SSHTerminalAgentDetector.mode(
            override: .terminal, root: agent, app: "pi", foreground: .agent("pi"), herdr: focused
        ) == .terminal)
        #expect(SSHTerminalAgentDetector.rootSelectsChat(root: nil, app: "pi") == false)
    }

    /// Pi runs as `node`, so the probe reads a shell while Pi is in front: a
    /// live report keeps the chat bar. Once the shell shows its next prompt,
    /// the done report that outlives it no longer does.
    @Test func aReportFromBeforeTheShellPromptNoLongerPicksTheChatBar() throws {
        let engine = try SSHTerminalEngine { _ in }
        let detector = SSHTerminalAgentDetector()
        func mode() -> SSHTerminalInputMode? {
            SSHTerminalAgentDetector.mode(
                root: engine.programStatus.liveRoot, app: engine.programStatus.app(of: ""), foreground: .shell, herdr: nil
            )
        }
        engine.receive(Data("\u{1b}]7501;state=done:app=pi\u{1b}\\".utf8))
        #expect(mode() == .chat, "Pi between turns")

        engine.receive(Data("\u{1b}]133;A\u{7}".utf8))
        #expect(engine.programStatus.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_DONE, "the outcome still shows")
        #expect(mode() == .terminal, "the shell is back in front")
        #expect(detector.mode(programStatus: engine.programStatus, herdr: nil) == nil)

        engine.receive(Data("\u{1b}]7501;state=working:app=pi\u{1b}\\".utf8))
        #expect(mode() == .chat, "Pi started again")
    }

    @Test func herdrStatusesUseTheSharedPresentation() {
        #expect(HerdrSnapshot.Status.working.sessionStatus == .working)
        #expect(HerdrSnapshot.Status.blocked.sessionStatus == .question)
        #expect(HerdrSnapshot.Status.done.sessionStatus == .done)
        #expect(HerdrSnapshot.Status.idle.sessionStatus == .idle)
        #expect(HerdrSnapshot.Status.unknown.sessionStatus == nil)
        #expect(HerdrSnapshot.Status.blocked.sessionStatus?.label == "Question")
        #expect(HerdrSnapshot.Status.done.sessionStatus?.label == "Done")
    }

    private func herdr(focused: Bool) throws -> HerdrSnapshot {
        let json = #"{"workspaces":[],"tabs":[],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"working","focused":\#(focused)}]}"#
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }
}
