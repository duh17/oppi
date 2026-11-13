import Foundation
import Testing
@testable import Oppi

@Suite("SessionThreadStripSummary")
struct SessionThreadStripSummaryTests {
    /// A session whose own status, resolved without this device's seen state, is `kind`. The strip reads
    /// the record, so every fixture has to carry the record that resolves to the state it stands for.
    private func session(_ id: String, parent: String? = "root", _ kind: SessionStatusKind) -> Session {
        var session = Session(
            id: id,
            workspaceId: "ws",
            name: id,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            parentSessionId: parent
        )
        let since = Date(timeIntervalSince1970: 2_000)
        switch kind {
        case .working:
            session.status = .busy
            session.currentTurnStartedAt = since
            session.programStatus = ProgramStatus(state: .working, since: since)
        case .needsApproval: session.programStatus = ProgramStatus(state: .blocked, kind: .permission, since: since)
        case .question: session.programStatus = ProgramStatus(state: .blocked, kind: .question, since: since)
        case .signIn: session.programStatus = ProgramStatus(state: .blocked, kind: .auth, since: since)
        case .error: session.programStatus = ProgramStatus(state: .error, since: since)
        case .done: session.programStatus = ProgramStatus(state: .done, since: since)
        case .idle: session.programStatus = ProgramStatus(state: .idle, since: since)
        case .stopped: session.status = .stopped
        }
        return session
    }

    private func summary(root: SessionStatusKind = .idle, children: [Session]) -> SessionThreadStripSummary {
        let rollup = SessionThreadGrouping.rollups(from: [session("root", parent: nil, root)] + children)[0]
        return SessionThreadStripSummary(rollup: rollup) { SessionListPresentation.classify($0) }
    }

    /// A thread of `root` plus one child per kind.
    private func summary(root: SessionStatusKind = .idle, _ kinds: [SessionStatusKind]) -> SessionThreadStripSummary {
        summary(root: root, children: kinds.enumerated().map { session("child-\($0.offset)", $0.element) })
    }

    private func repeated(_ kind: SessionStatusKind, _ count: Int) -> [SessionStatusKind] {
        Array(repeating: kind, count: count)
    }

    /// The strip's stopped count is the fold's count: both answer "is this member stopped", never "has the
    /// person looked at it". The fixture is a device screenshot: stopped members whose result this device has
    /// not opened read Done on their own rows, and the fold holds every one of them.
    @Test func theStoppedCountIsTheFoldsOwnCount() {
        var unseenResult = session("unseen-result", .stopped)
        unseenResult.programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 2_000))
        let liveResult = session("live-result", .done)
        let thread = [
            session("root", parent: nil, .idle), unseenResult, session("plain-stopped", .stopped),
            session("worker", .working), liveResult,
        ]
        let rollup = SessionThreadGrouping.rollups(from: thread)[0]
        let result = SessionThreadStripSummary(rollup: rollup) { SessionListPresentation.classify($0) }
        let fold = rollup.listing { _ in .none }.stopped

        #expect(fold.count == 2)
        #expect(result.counts.first { $0.bucket == .stopped }?.count == fold.count)
        #expect(result.counts.reduce(0) { $0 + $1.count } == rollup.descendants.count)
        #expect(result.text == "1 working · 1 idle · 2 stopped")
    }

    /// Every bucket adds up to the children, on any mix.
    @Test(arguments: [
        [SessionStatusKind.stopped, .done, .idle, .working, .question, .error],
        Array(repeating: SessionStatusKind.stopped, count: 7),
        [SessionStatusKind.working, .working, .working, .signIn, .needsApproval],
        [SessionStatusKind.done, .done, .stopped],
    ])
    func everyBucketAddsUpToTheChildren(kinds: [SessionStatusKind]) {
        let result = summary(kinds)
        #expect(result.counts.reduce(0) { $0 + $1.count } == kinds.count)
        #expect(result.counts.allSatisfy { $0.count > 0 })
    }

    /// Opening a member is not news: a stopped member stays stopped whether its result is unseen (Done on its
    /// row) or seen, and a live one keeps its bucket, so the strip never changes under the person's thumb.
    @Test func aMemberBeingSeenNeverChangesTheStrip() {
        var unseen = session("a", .stopped)
        unseen.programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 2_000))
        let seen = session("a", .stopped)

        #expect(summary(children: [unseen]) == summary(children: [seen]))
        // A live member's unseen result and its settled rest are the same quiet state here.
        #expect(summary(children: [session("b", .done)]) == summary(children: [session("b", .idle)]))
    }

    /// The drawn counts line repeats nothing the dots already draw: an active thread counts only its idle and
    /// stopped members, in that order, and leaves working, needs you, and error to the dots. A settled thread
    /// draws no dots and counts nothing else, so its line is the whole summary. The full summary, and so
    /// VoiceOver, keeps every bucket.
    @Test func theDrawnCountsLeaveWhatTheDotsDrawToTheDots() {
        let result = summary(repeated(.stopped, 102) + [.idle] + repeated(.working, 15) + [.question, .error])

        #expect(result.text == "15 working · 1 needs you · 1 error · 1 idle · 102 stopped")
        #expect(result.quietText == "1 idle · 102 stopped")
        #expect(result.isActive)

        let settled = summary(repeated(.stopped, 4) + [.idle])
        #expect(!settled.isActive)
        #expect(settled.quietText == settled.text, "A settled thread's line is its whole summary")
        #expect(settled.quietText == "1 idle · 4 stopped")
    }

    /// A thread whose members are all active has nothing the dots leave out: no words on the drawn line.
    @Test func aThreadOfOnlyActiveMembersDrawsNoCountWords() {
        #expect(summary([.working, .question, .error]).quietText.isEmpty)
    }

    @Test func countsUseTheListsWordsInTheStripsOrderAndOmitZeros() {
        let result = summary(repeated(.stopped, 101) + repeated(.done, 23) + [.question] + repeated(.working, 3))

        #expect(result.text == "3 working · 1 needs you · 23 idle · 101 stopped")
        #expect(result.counts.map(\.bucket) == [.working, .needsYou, .idle, .stopped])
    }

    @Test func everyStateHasItsWordAndBlockedKindsShareNeedsYou() {
        let result = summary([
            .stopped, .idle, .done, .error, .signIn, .needsApproval, .question, .working,
        ])

        #expect(result.text == "1 working · 3 need you · 1 error · 2 idle · 1 stopped")
        #expect(!result.text.contains("done"), "The strip has no Done: a settled outcome is Idle here, seen or not")
    }

    @Test func aSingleBlockedMemberAgrees() {
        #expect(summary([.signIn]).text == "1 needs you")
    }

    @Test func errorsAgreeInNumber() {
        #expect(summary([.error]).text == "1 error")
        #expect(summary([.error, .error]).text == "2 errors")
    }

    /// The SSH terminal's record-tree summary and the strip use one vocabulary for the states they share.
    /// Done is not one of them: the strip answers the fold's question, which has no Done.
    @Test(arguments: [SessionStatusKind.working, .error, .idle, .stopped])
    func theStripAndTheTerminalRollupSayTheSameThing(kind: SessionStatusKind) {
        for count in [1, 2] {
            #expect(
                SessionThreadStripSummary.Bucket(kind).text(count: count) == SessionStatusRollup.chipText(kind, count: count)
            )
        }
    }

    @Test func theRootIsInNeitherTheCountsNorTheDots() {
        let working = summary(root: .working, [.stopped, .done])
        #expect(working.text == "1 idle · 1 stopped")
        #expect(working.dots.isEmpty)

        let blocked = summary(root: .needsApproval, [.working])
        #expect(blocked.text == "1 working")
        #expect(blocked.dots == [.working])
    }

    @Test func onlyActiveMembersGetDotsMostUrgentFirst() {
        let result = summary([.working, .stopped, .done, .error, .idle, .question, .working, .signIn])

        #expect(result.dots == [.needsYou, .needsYou, .error, .working, .working])
        #expect(result.hiddenDotCount == 0)
    }

    @Test func dotsStopAtTheCapAndCountTheRest() {
        let result = summary(repeated(.working, 20) + [.question] + repeated(.stopped, 50))

        #expect(result.dots.count == SessionThreadStripSummary.maxDots)
        #expect(result.dots.first == .needsYou, "A member that needs you stays in view under the cap")
        #expect(result.hiddenDotCount == 21 - SessionThreadStripSummary.maxDots)
        #expect(result.text == "20 working · 1 needs you · 50 stopped")
    }

    @Test func exactlyTheCapLeavesNothingHidden() {
        let result = summary(repeated(.working, SessionThreadStripSummary.maxDots))

        #expect(result.dots.count == SessionThreadStripSummary.maxDots)
        #expect(result.hiddenDotCount == 0)
    }

    @Test func aThreadWhoseMembersAllStoppedHasCountsAndNoDots() {
        let result = summary(repeated(.stopped, 4) + [.idle])

        #expect(result.text == "1 idle · 4 stopped")
        #expect(result.dots.isEmpty)
        #expect(result.hiddenDotCount == 0)
    }

    @Test func aThreadWhoseMembersAreAllActiveHasADotEachAndNoOtherCounts() {
        let result = summary(repeated(.working, 3) + [.error])

        #expect(result.text == "3 working · 1 error")
        #expect(result.dots == [.error, .working, .working, .working])
    }
}
