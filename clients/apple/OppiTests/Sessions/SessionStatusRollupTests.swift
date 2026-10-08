import Foundation
import Testing
@testable import Oppi

@Suite("SessionStatusRollup")
struct SessionStatusRollupTests {
    // MARK: Headline

    @Test(arguments: [
        // blocked (with its kind) > working > error > done > idle > stopped
        ([SessionStatusKind.working, .question, .done], SessionStatusKind.question),
        ([.working, .error, .done, .idle, .stopped], .working),
        ([.done, .error, .idle], .error),
        ([.idle, .done, .stopped], .done),
        ([.stopped, .idle], .idle),
        ([.stopped, .stopped], .stopped),
        // Among blocked kinds: approval, then sign-in, then question.
        ([.question, .signIn, .needsApproval], .needsApproval),
        ([.question, .signIn], .signIn),
    ])
    func headlineFollowsPrecedence(others: [SessionStatusKind], expected: SessionStatusKind) {
        // The root takes part in the headline even though it is not in the counts.
        let rollup = SessionStatusRollup(root: .stopped, others: others)
        #expect(rollup.headline == expected)
    }

    @Test func aBlockedRootOutranksWorkingChildren() {
        let rollup = SessionStatusRollup(root: .needsApproval, others: [.working, .working])
        #expect(rollup.headline == .needsApproval)
    }

    @Test func anEmptyTreeHasNoHeadline() {
        #expect(SessionStatusRollup(root: nil, others: []).headline == nil)
    }

    // MARK: Chips

    @Test func chipsCountEachStateInHeadlineOrder() {
        let rollup = SessionStatusRollup(
            root: .idle,
            others: [.stopped, .done, .working, .error, .needsApproval, .done, .working, .done,
                     .stopped, .stopped, .stopped, .idle]
        )

        #expect(rollup.chips.map(\.text) == [
            "1 needs approval", "2 working", "1 failed", "3 done", "1 idle", "4 finished",
        ])
        #expect(rollup.summaryText == "1 needs approval · 2 working · 1 failed · 3 done · 1 idle · 4 finished")
    }

    @Test func rootGetsItsOwnChipAndIsNotCountedTwice() {
        let rollup = SessionStatusRollup(root: .working, others: [.working])

        #expect(rollup.rootChipText == "Root: Working")
        #expect(rollup.count(.working) == 1)
        #expect(rollup.chips.map(\.text) == ["1 working"])
    }

    @Test(arguments: [
        (SessionStatusKind.needsApproval, 1, "1 needs approval"),
        (.needsApproval, 2, "2 need approval"),
        (.signIn, 1, "1 needs sign-in"),
        (.signIn, 3, "3 need sign-in"),
        (.question, 1, "1 question"),
        (.question, 2, "2 questions"),
    ])
    func blockedChipsAgreeInNumber(kind: SessionStatusKind, count: Int, expected: String) {
        #expect(SessionStatusRollup.chipText(kind, count: count) == expected)
    }

    @Test func emptyStatesProduceNoChips() {
        let rollup = SessionStatusRollup(root: nil, others: [])
        #expect(rollup.chips.isEmpty)
        #expect(rollup.rootChipText == nil)
        #expect(rollup.summaryText.isEmpty)
    }

    // MARK: Threads

    @Test func threadRollupResolvesEachMemberWithTheCallersSeenState() {
        func member(_ id: String, parent: String? = nil, lifecycle: SessionStatus, program: ProgramStatus?) -> Session {
            var session = makeTestSession(id: id, status: lifecycle, messageCount: 2, firstMessage: "go")
            session.parentSessionId = parent
            session.programStatus = program
            return session
        }
        let since = Date(timeIntervalSince1970: 100)
        let members = [
            member("root", lifecycle: .ready, program: ProgramStatus(state: .idle, since: since)),
            member("a", parent: "root", lifecycle: .ready, program: ProgramStatus(state: .done, since: since)),
            member("b", parent: "root", lifecycle: .ready, program: ProgramStatus(state: .done, since: since)),
            member("c", parent: "root", lifecycle: .busy, program: ProgramStatus(state: .working, since: since)),
        ]
        let thread = SessionThreadGrouping.rollups(from: members)[0]
        let seenAtByMember = ["a": Date(timeIntervalSince1970: 200)]

        let rollup = thread.statusRollup { member in
            SessionStatusKind.resolve(session: member, seenAt: seenAtByMember[member.id])
        }

        // Member "a" was seen, so it is Idle; "b" is still an unseen Done.
        #expect(rollup.root == .idle)
        #expect(rollup.chips.map(\.text) == ["1 working", "1 done", "1 idle"])
        #expect(rollup.headline == .working)
    }
}
