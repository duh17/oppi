import Testing
import UIKit
@testable import Oppi

/// The Thread strip's status dots and summary as a list cell draws them: live dots for members still
/// going, counts in the list's words, one line while the thread is settled, and a strip that keeps its
/// height as members change state.
@MainActor
@Suite("Session thread strip view")
struct SessionThreadStripViewTests {
    private let style = SessionRowStyle.for(.dark)

    /// A member whose own status, resolved without this device's seen state, is `kind`.
    private func session(_ id: String, parent: String?, _ kind: SessionStatusKind) -> Session {
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

    /// A root and one child per state. `agents` gives the children those saved Agents in turn.
    private func members(_ children: [SessionStatusKind], agents: [String] = []) -> SessionThreadRollup {
        var all = [session("root", parent: nil, .idle)]
        for (index, kind) in children.enumerated() {
            var child = session("child-\(index)", parent: "root", kind)
            if !agents.isEmpty {
                child.launch = SessionLaunchMetadata(agentId: agents[index % agents.count], agentIcon: .emoji("\u{1F6E0}\u{FE0F}"))
            }
            all.append(child)
        }
        return SessionThreadGrouping.rollups(from: all)[0]
    }

    private func strip(
        _ children: [SessionStatusKind],
        agents: [String] = [],
        width: CGFloat = 330
    ) -> (SessionThreadStripView, CGFloat) {
        let rollup = members(children, agents: agents)
        let view = SessionThreadStripView()
        view.apply(
            SessionThreadStripView.Content(rollup: rollup),
            display: .standard, style: style, iconAssetCache: nil
        )
        let height = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // The row fits its Agent groups before it lays out, so one pass settles what is hidden.
        view.layoutIfNeeded()
        return (view, height)
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    /// Applies one thread to an existing strip and returns the height it takes, laid out at `width`.
    private func apply(
        _ children: [SessionStatusKind],
        agents: [String] = [],
        to view: SessionThreadStripView,
        width: CGFloat = 330
    ) -> CGFloat {
        view.apply(
            SessionThreadStripView.Content(rollup: members(children, agents: agents)),
            display: .standard, style: style, iconAssetCache: nil
        )
        let height = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return height
    }

    /// The middle of the Agents, the dot line, and the counts line, in the strip's own coordinates.
    private func rows(of view: SessionThreadStripView) -> (agents: CGFloat, dots: CGFloat, counts: CGFloat) {
        func middle<T: UIView>(_ type: T.Type) -> CGFloat {
            let child = descendants(of: view, type)[0]
            return child.convert(child.bounds, to: view).midY
        }
        return (middle(SessionThreadAgentClusterView.self), middle(SessionThreadStatusDotsView.self), middle(SessionThreadSummaryLabel.self))
    }

    private func shownDots(_ view: SessionThreadStatusDotsView) -> [CALayer] {
        (view.layer.sublayers ?? []).filter { !$0.isHidden }
    }

    // MARK: Dots

    @Test func dotsTakeTheirStatusTintAndOnlyWorkingOnesPulse() {
        let view = SessionThreadStatusDotsView()
        view.apply([.needsYou, .error, .working, .working], hiddenCount: 0, style: style)

        let dots = shownDots(view)
        #expect(dots.count == 4)
        #expect(dots.map { $0.backgroundColor.map(UIColor.init(cgColor:)) } == [
            style.tint(.needsApproval), style.tint(.error), style.tint(.working), style.tint(.working),
        ])
        #expect(dots.map { $0.animation(forKey: "pulse") != nil } == [false, false, true, true])
    }

    @Test func reusingTheViewForFewerDotsLeavesNoStaleDotOrPulse() {
        let view = SessionThreadStatusDotsView()
        view.apply([.working, .working, .working, .working, .working], hiddenCount: 0, style: style)
        view.apply([.needsYou], hiddenCount: 0, style: style)

        let all = view.layer.sublayers ?? []
        #expect(shownDots(view).count == 1)
        #expect(shownDots(view).first?.animation(forKey: "pulse") == nil, "A needs-you dot does not pulse")
        #expect(all.filter(\.isHidden).allSatisfy { $0.animation(forKey: "pulse") == nil })
    }

    @Test func theDotLineKeepsItsHeightWithAndWithoutDots() {
        let view = SessionThreadStatusDotsView()
        view.apply([], hiddenCount: 0, style: style)
        let empty = view.intrinsicContentSize
        view.apply(Array(repeating: .working, count: SessionThreadStripSummary.maxDots), hiddenCount: 5, style: style)
        let full = view.intrinsicContentSize

        #expect(empty.width == 0)
        #expect(empty.height == full.height)
        #expect(full.width > empty.width)
    }

    // MARK: Strip

    /// Settling is the only state change that resizes the row: a settled thread draws one line, and every
    /// thread with an active member keeps the taller headline + dots + counts, so a member changing state
    /// inside an active thread never moves the rows below.
    @Test func aSettledThreadIsOneLineAndEveryActiveThreadKeepsItsHeight() {
        let (_, settled) = strip([.stopped, .stopped])
        let (_, settledDone) = strip([.done, .idle, .stopped])
        let (_, working) = strip([.working, .stopped])
        let (_, blocked) = strip([.question, .stopped])
        let (_, crowd) = strip(Array(repeating: .working, count: 40) + [.question, .stopped])

        #expect(settledDone == settled, "A thread with no active member draws the same one line")
        #expect(working > settled, "An active thread keeps the headline and dot lines")
        #expect(blocked == working, "A blocked member changed an active strip's height")
        #expect(crowd == working, "A crowd of active members changed an active strip's height")
    }

    /// The Agents sit on the dot line while a member is active, where they have the whole width, and join
    /// the counts line once the thread settles, so the settled strip stays one line.
    @Test func theAgentsShareTheCountsLineOnlyWhileTheThreadIsSettled() {
        func lines(_ children: [SessionStatusKind]) -> (agents: CGRect, counts: CGRect, dots: CGRect, view: UIView) {
            let (view, _) = strip(children, agents: ["a", "b"])
            let agents = descendants(of: view, SessionThreadAgentClusterView.self)[0]
            let counts = descendants(of: view, SessionThreadSummaryLabel.self)[0]
            let dots = descendants(of: view, SessionThreadStatusDotsView.self)[0]
            return (agents.convert(agents.bounds, to: view), counts.convert(counts.bounds, to: view), dots.convert(dots.bounds, to: view), view)
        }

        let settled = lines([.stopped, .stopped])
        #expect(abs(settled.agents.midY - settled.counts.midY) < 1, "The settled strip keeps the Agents on the counts line")
        #expect(settled.agents.maxY <= settled.view.bounds.maxY)

        let active = lines([.working, .stopped])
        #expect(abs(active.agents.midY - active.dots.midY) < 1, "An active strip keeps the Agents on the dot line")
        #expect(active.counts.minY > active.dots.minY)
    }

    /// A list reuses the strip's cell as threads wake and settle: one reused view draws every state as a
    /// fresh one does, and the Agents land in that state's row each time.
    @Test func reusingOneStripAcrossStatesDrawsEachLikeAFreshOne() {
        let agents = ["a", "b"]
        let active = [SessionStatusKind.working, .stopped, .stopped]
        let settled = [SessionStatusKind.stopped, .idle, .stopped]
        let runs: [(states: [[SessionStatusKind]], isActive: [Bool])] = [
            ([active, settled, active], [true, false, true]),
            ([settled, active, settled], [false, true, false]),
        ]

        for run in runs {
            let reused = SessionThreadStripView()
            for (state, isActive) in zip(run.states, run.isActive) {
                let reusedHeight = apply(state, agents: agents, to: reused)
                let (fresh, freshHeight) = strip(state, agents: agents)
                #expect(reusedHeight == freshHeight, "A reused strip is \(reusedHeight) high where a fresh one is \(freshHeight)")

                let reusedRows = rows(of: reused)
                let freshRows = rows(of: fresh)
                #expect(abs(reusedRows.agents - freshRows.agents) < 0.5, "The Agents sit elsewhere after a reuse")
                if isActive {
                    #expect(abs(reusedRows.agents - reusedRows.dots) < 1, "The Agents left the dot line of an active strip")
                } else {
                    #expect(abs(reusedRows.agents - reusedRows.counts) < 1, "The Agents left the counts line of a settled strip")
                }
            }
        }
    }

    @Test func theStripLabelCarriesTheListsCountsForTheChildrenAndNoRetiredWords() {
        let (view, _) = strip([.working, .working, .working, .question, .done, .stopped, .stopped])

        let label = view.accessibilityLabel ?? ""
        #expect(
            label.contains("Thread with 7 child sessions, 3 working · 1 needs you · 1 idle · 2 stopped"),
            Comment(rawValue: label)
        )
        #expect(!label.contains("done"), Comment(rawValue: label))
        #expect(!label.contains("finished"))
        #expect(strip([.working]).0.accessibilityLabel?.contains("Thread with 1 child session, 1 working") == true)
    }

    /// VoiceOver names the answer a blocked child waits for, while the counts fold every blocked kind into
    /// one "needs you".
    @Test func theVoiceOverHeadlineKeepsEachBlockedKindsOwnWords() {
        let question = strip([.question, .stopped]).0.accessibilityLabel ?? ""
        #expect(
            question.contains("Question. Thread with 2 child sessions, 1 needs you · 1 stopped"),
            Comment(rawValue: question)
        )
        let signIn = strip([.signIn, .stopped]).0.accessibilityLabel ?? ""
        #expect(
            signIn.contains("Sign-in. Thread with 2 child sessions, 1 needs you · 1 stopped"),
            Comment(rawValue: signIn)
        )
    }

    @Test func theAgentsClusterCountsTheChildrenSoItAddsUpToTheCounts() {
        // Three Agents over 7 children (root excluded): 3 + 2 + 2.
        let (view, _) = strip([.working, .working, .working, .question, .done, .stopped, .stopped], agents: ["a", "b", "c"])
        let cluster = descendants(of: view, SessionThreadAgentClusterView.self)[0]
        let counts = cluster.arrangedSubviews.compactMap { $0 as? UIStackView }
            .flatMap { descendants(of: $0, UILabel.self) }
            .compactMap(\.text).filter { $0.hasPrefix("×") }

        #expect(counts == ["×3", "×2", "×2"])
    }

    /// 12 dots, "+N", and three Agent groups on a phone-width strip and a narrow split: the dots keep their
    /// width and the Agents give way, so nothing reaches past the strip or over the dots.
    @Test(arguments: [330.0, 260.0])
    func aFullDotLineAndThreeAgentGroupsNeverOverflowTheStatusRow(width: Double) {
        let children = Array(repeating: SessionStatusKind.working, count: 14) + [.question] + Array(repeating: .stopped, count: 5)
        let (view, _) = strip(children, agents: ["worker", "reviewer", "scout"], width: CGFloat(width))
        let dots = descendants(of: view, SessionThreadStatusDotsView.self)[0]
        let cluster = descendants(of: view, SessionThreadAgentClusterView.self)[0]
        let dotsFrame = dots.convert(dots.bounds, to: view)
        let clusterFrame = cluster.convert(cluster.bounds, to: view)
        let groups = cluster.arrangedSubviews.compactMap { $0 as? UIStackView }.filter { !$0.isHidden }

        #expect(dotsFrame.width == dots.intrinsicContentSize.width, "The dots keep their full width")
        #expect(dotsFrame.maxX <= view.bounds.maxX - 8 + 0.5)
        #expect(clusterFrame.maxX <= view.bounds.maxX - 8 + 0.5, "Agents reach past the strip: \(clusterFrame)")
        if !groups.isEmpty { #expect(dotsFrame.maxX <= clusterFrame.minX, "Agents overlap the dots") }
        #expect(width > 300 ? groups.count == 3 : groups.count < 3)
    }

    /// A settled strip never runs past its width either: the counts keep their room and the Agents fold.
    @Test(arguments: [330.0, 260.0])
    func aSettledStripWithAgentsNeverRunsPastItsWidth(width: Double) {
        let children = Array(repeating: SessionStatusKind.stopped, count: 137) + [.idle, .idle]
        let (view, _) = strip(children, agents: ["worker", "reviewer", "scout"], width: CGFloat(width))
        let cluster = descendants(of: view, SessionThreadAgentClusterView.self)[0]
        let counts = descendants(of: view, SessionThreadSummaryLabel.self)[0]

        #expect(counts.convert(counts.bounds, to: view).maxX <= view.bounds.maxX - 8 + 0.5)
        #expect(cluster.convert(cluster.bounds, to: view).maxX <= view.bounds.maxX - 8 + 0.5)
    }
}
