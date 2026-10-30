import Testing
import UIKit
@testable import Oppi

/// The Thread strip's status dots and summary as a list cell draws them: live dots for members still
/// going, counts in the list's words, and a strip that keeps its height as members change state.
@MainActor
@Suite("Session thread strip view")
struct SessionThreadStripViewTests {
    private let style = SessionRowStyle.for(.dark)

    /// A root and one child per status. `agents` gives the children those saved Agents in turn.
    private func members(
        _ children: [SessionStatusKind],
        agents: [String] = []
    ) -> (SessionThreadRollup, [String: SessionStatusKind]) {
        func session(_ id: String, parent: String?, status: SessionStatusKind) -> Session {
            var session = Session(
                id: id,
                workspaceId: "ws",
                name: id,
                status: status == .stopped ? .stopped : status == .working ? .busy : .ready,
                createdAt: Date(timeIntervalSince1970: 1_000),
                lastActivity: Date(timeIntervalSince1970: 1_000),
                messageCount: 3,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0,
                parentSessionId: parent
            )
            // The strip names working children by their lifecycle, so a working child is really busy.
            if status == .working { session.programStatus = ProgramStatus(state: .working, since: Date(timeIntervalSince1970: 1_000)) }
            return session
        }
        var all = [session("root", parent: nil, status: .idle)]
        var statuses = ["root": SessionStatusKind.idle]
        for (index, status) in children.enumerated() {
            var child = session("child-\(index)", parent: "root", status: status)
            if !agents.isEmpty {
                child.launch = SessionLaunchMetadata(agentId: agents[index % agents.count], agentIcon: .emoji("\u{1F6E0}\u{FE0F}"))
            }
            all.append(child)
            statuses["child-\(index)"] = status
        }
        return (SessionThreadGrouping.rollups(from: all)[0], statuses)
    }

    private func strip(
        _ children: [SessionStatusKind],
        agents: [String] = [],
        width: CGFloat = 330
    ) -> (SessionThreadStripView, CGFloat) {
        let (rollup, statuses) = members(children, agents: agents)
        let view = SessionThreadStripView()
        view.apply(
            SessionThreadStripView.Content(rollup: rollup, statuses: statuses),
            display: .standard, style: style, iconAssetCache: nil
        )
        let height = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Fitting the Agents hides groups mid-layout, which asks for one more pass.
        view.layoutIfNeeded()
        view.layoutIfNeeded()
        return (view, height)
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
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

    @Test func aMemberStartingOrStoppingNeverChangesTheStripHeight() {
        // The headline line ("X working", "Question \u{00B7} Y") keeps its height empty, so a member going
        // active, blocked, or settled moves nothing below the strip.
        let (_, settled) = strip([.stopped, .stopped])
        let (_, mixed) = strip([.done, .idle, .stopped, .stopped])
        let (_, working) = strip([.working, .stopped])
        let (_, blocked) = strip([.question, .stopped])
        let (_, crowd) = strip(Array(repeating: .working, count: 40) + [.question, .stopped])
        #expect(settled == mixed)
        #expect(working == settled, "A working member changed the strip's height")
        #expect(blocked == settled, "A blocked member changed the strip's height")
        #expect(crowd == settled, "A crowd of active members changed the strip's height")
    }

    @Test func theStripLabelCarriesTheListsCountsForTheChildrenAndNoRetiredWords() {
        let (view, _) = strip([.working, .working, .working, .question, .done, .stopped, .stopped])

        let label = view.accessibilityLabel ?? ""
        #expect(
            label.contains("Thread with 7 child sessions, 3 working · 1 needs you · 1 done · 2 stopped"),
            Comment(rawValue: label)
        )
        #expect(!label.contains("finished"))
        #expect(strip([.working]).0.accessibilityLabel?.contains("Thread with 1 child session, 1 working") == true)
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
}
