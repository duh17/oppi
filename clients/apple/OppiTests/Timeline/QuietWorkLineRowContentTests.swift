import UIKit
import Testing
@testable import Oppi

@Suite("QuietWorkLineRowContent")
@MainActor
struct QuietWorkLineRowContentTests {
    private let timestamp = Date(timeIntervalSince1970: 0)

    private func makeWorkLine(
        activities: [String],
        isLive: Bool = false
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "quiet-work-line:test",
            turnID: "test",
            sourceItemIDs: ["test"],
            toolCount: activities.filter { $0 != "thinking" }.count,
            thinkingCount: activities.filter { $0 == "thinking" }.count,
            activityCounts: activities.reduce(into: [String: Int]()) { counts, kind in
                counts[kind, default: 0] += 1
            },
            activities: activities,
            isExpanded: false,
            isLive: isLive,
            liveStartedAt: isLive ? timestamp : nil
        )
    }

    @Test func activitySymbolsFollowCanonicalToolMapping() {
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "thinking") == "sparkles")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "bash") == "dollarsign")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "read") == "magnifyingglass")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "write") == "pencil")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "edit") == "arrow.left.arrow.right")
        // Unknown/extension tools fall back to the generic code symbol.
        #expect(
            QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "mermaid")
                == "chevron.left.forwardslash.chevron.right"
        )
    }

    @Test func accessibilitySummaryAppendsDistinctActivityBreakdown() {
        let summary = QuietWorkLineTimelineRowContentView.accessibilitySummary(
            for: makeWorkLine(activities: ["bash", "bash", "read", "thinking", "bash"])
        )
        #expect(summary == "4 tools, 1 thinking block. Used bash 3, read, thinking")
    }

    @Test func accessibilitySummaryUsesAggregateCountsForCappedRecentActivity() {
        var workLine = makeWorkLine(activities: Array(repeating: "bash", count: 10) + ["thinking", "mermaid"])
        workLine = QuietTimelineWorkLine(
            id: workLine.id,
            turnID: workLine.turnID,
            sourceItemIDs: workLine.sourceItemIDs,
            toolCount: 14,
            thinkingCount: 1,
            activityCounts: ["bash": 14, "thinking": 1, "mermaid": 1],
            activities: workLine.activities,
            isExpanded: workLine.isExpanded,
            isLive: workLine.isLive,
            liveStartedAt: workLine.liveStartedAt
        )

        #expect(
            QuietWorkLineTimelineRowContentView.accessibilitySummary(for: workLine)
                == "14 tools, 1 thinking block. Used bash 14, thinking, mermaid"
        )
    }

    @Test func accessibilitySummaryOmitsBreakdownWithoutActivities() {
        let summary = QuietWorkLineTimelineRowContentView.accessibilitySummary(
            for: makeWorkLine(activities: [])
        )
        // Degenerate strip: no activities and not live → plain empty summary.
        #expect(summary == "")
    }

    @Test func collapsedStripFillDiffersFromUserMessageBubble() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(activities: ["bash"])
            )
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()

        let chip = try #require(chipView(in: view))
        let userFill = UIColor(ThemeRuntimeState.currentPalette().userMessageBg)
        var alpha: CGFloat = 1
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        #expect(chip.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true)
        #expect(alpha < 1)
        #expect(chip.layer.borderWidth > 0)
        #expect(chip.layer.borderColor != nil)
        #expect(color(chip.backgroundColor, approximatelyEquals: userFill) == false)
    }

    @Test func leadingIconFollowsLatestActivityAndHidesWhenEmpty() throws {
        let withActivity = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(activities: ["thinking", "bash"])
            )
        )
        let icon = try #require(iconView(in: withActivity))
        #expect(icon.isHidden == false)
        #expect(icon.image != nil)

        let empty = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(activities: [])
            )
        )
        #expect(try #require(iconView(in: empty)).isHidden)
    }
}

@MainActor
private func chipView(in view: QuietWorkLineTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "chipView" }?.value as? UIView
}

@MainActor
private func iconView(in view: QuietWorkLineTimelineRowContentView) -> UIImageView? {
    Mirror(reflecting: view).children.first { $0.label == "iconView" }?.value as? UIImageView
}

private func color(_ lhs: UIColor?, approximatelyEquals rhs: UIColor, tolerance: CGFloat = 0.01) -> Bool {
    guard let lhs else { return false }

    var lr: CGFloat = 0
    var lg: CGFloat = 0
    var lb: CGFloat = 0
    var la: CGFloat = 0
    var rr: CGFloat = 0
    var rg: CGFloat = 0
    var rb: CGFloat = 0
    var ra: CGFloat = 0

    guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
          rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else {
        return lhs.cgColor == rhs.cgColor
    }

    return abs(lr - rr) <= tolerance &&
        abs(lg - rg) <= tolerance &&
        abs(lb - rb) <= tolerance &&
        abs(la - ra) <= tolerance
}
