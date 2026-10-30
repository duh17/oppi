import Foundation
import Testing
@testable import Oppi

@Suite("SessionThreadStripSummary")
struct SessionThreadStripSummaryTests {
    private func member(_ id: String, parent: String? = "root", status: SessionStatusKind) -> (Session, SessionStatusKind) {
        let lifecycle: SessionStatus = switch status {
        case .working: .busy
        case .stopped: .stopped
        default: .ready
        }
        let session = Session(
            id: id,
            workspaceId: "ws",
            name: id,
            status: lifecycle,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            parentSessionId: parent
        )
        return (session, status)
    }

    /// A thread of `root` plus children with these statuses, resolved the way the strip is given them.
    private func summary(root: SessionStatusKind = .idle, _ children: [SessionStatusKind]) -> SessionThreadStripSummary {
        let rootMember = member("root", parent: nil, status: root)
        let kids = children.enumerated().map { member("child-\($0.offset)", status: $0.element) }
        let all = [rootMember] + kids
        let statuses = Dictionary(uniqueKeysWithValues: all.map { ($0.0.id, $0.1) })
        let rollup = SessionThreadGrouping.rollups(from: all.map(\.0))[0]
        return SessionThreadStripSummary(rollup: rollup) { statuses[$0.id] ?? .idle }
    }

    private func repeated(_ kind: SessionStatusKind, _ count: Int) -> [SessionStatusKind] {
        Array(repeating: kind, count: count)
    }

    @Test func countsUseTheListsWordsInTheStripsOrderAndOmitZeros() {
        let result = summary(repeated(.stopped, 101) + repeated(.done, 23) + [.question] + repeated(.working, 3))

        #expect(result.text == "3 working · 1 needs you · 23 done · 101 stopped")
        #expect(result.counts.map(\.bucket) == [.working, .needsYou, .done, .stopped])
    }

    @Test func everyStateHasItsWordAndBlockedKindsShareNeedsYou() {
        let result = summary([
            .stopped, .idle, .done, .error, .signIn, .needsApproval, .question, .working,
        ])

        #expect(result.text == "1 working · 3 need you · 1 error · 1 done · 1 idle · 1 stopped")
    }

    @Test func aSingleBlockedMemberAgrees() {
        #expect(summary([.signIn]).text == "1 needs you")
    }

    @Test func theRootIsInNeitherTheCountsNorTheDots() {
        let working = summary(root: .working, [.stopped, .done])
        #expect(working.text == "1 done · 1 stopped")
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
        let result = summary(repeated(.stopped, 4) + [.done])

        #expect(result.text == "1 done · 4 stopped")
        #expect(result.dots.isEmpty)
        #expect(result.hiddenDotCount == 0)
    }

    @Test func aThreadWhoseMembersAreAllActiveHasADotEachAndNoOtherCounts() {
        let result = summary(repeated(.working, 3) + [.error])

        #expect(result.text == "3 working · 1 error")
        #expect(result.dots == [.error, .working, .working, .working])
    }
}
