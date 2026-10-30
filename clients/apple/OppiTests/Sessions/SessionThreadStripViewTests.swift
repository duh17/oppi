import Testing
import UIKit
@testable import Oppi

/// The Thread strip's status dots and summary as a list cell draws them: live dots for members still
/// going, counts in the list's words, and a strip that keeps its height as members change state.
@MainActor
@Suite("Session thread strip view")
struct SessionThreadStripViewTests {
    private let style = SessionRowStyle.for(.dark)

    private func members(_ children: [SessionStatusKind]) -> (SessionThreadRollup, [String: SessionStatusKind]) {
        func session(_ id: String, parent: String?, status: SessionStatusKind) -> Session {
            Session(
                id: id,
                workspaceId: "ws",
                name: id,
                status: status == .stopped ? .stopped : .ready,
                createdAt: Date(timeIntervalSince1970: 1_000),
                lastActivity: Date(timeIntervalSince1970: 1_000),
                messageCount: 3,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0,
                parentSessionId: parent
            )
        }
        var all = [session("root", parent: nil, status: .idle)]
        var statuses = ["root": SessionStatusKind.idle]
        for (index, status) in children.enumerated() {
            all.append(session("child-\(index)", parent: "root", status: status))
            statuses["child-\(index)"] = status
        }
        return (SessionThreadGrouping.rollups(from: all)[0], statuses)
    }

    private func strip(_ children: [SessionStatusKind], width: CGFloat = 330) -> (SessionThreadStripView, CGFloat) {
        let (rollup, statuses) = members(children)
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
        return (view, height)
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
        // With a working or blocked member the strip names it in a headline line; the dots add no height.
        let (_, one) = strip([.working, .stopped])
        let (_, crowd) = strip(Array(repeating: .working, count: 40) + [.stopped])
        #expect(one == crowd)
        let (_, oneBlocked) = strip([.question, .stopped])
        let (_, crowdBlocked) = strip(Array(repeating: .working, count: 40) + [.question, .stopped])
        #expect(oneBlocked == crowdBlocked)

        // Nothing active: no headline and no dots, and any mix of settled members is the same height.
        let (_, settled) = strip([.stopped, .stopped])
        let (_, mixed) = strip([.done, .idle, .stopped, .stopped])
        #expect(settled == mixed)
    }

    @Test func theStripLabelCarriesTheListsCountsAndNoRetiredWords() {
        let (view, _) = strip([.working, .working, .working, .question, .done, .stopped, .stopped])

        let label = view.accessibilityLabel ?? ""
        #expect(label.contains("Thread with 8 sessions, 3 working · 1 needs you · 1 done · 2 stopped"), Comment(rawValue: label))
        #expect(!label.contains("finished"))
    }
}
