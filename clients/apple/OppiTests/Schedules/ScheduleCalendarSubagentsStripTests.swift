import Testing
import UIKit
@testable import Oppi

/// The strip under a scheduled run that launched subagents, laid out at a phone's row width: how many,
/// what they cost, which Agents, and dots only while one is still going.
@MainActor
@Suite("Schedule calendar subagents strip")
struct ScheduleCalendarSubagentsStripTests {
    private let style = SessionRowStyle.for(.dark)

    private var context: ScheduleCalendarRowContext {
        ScheduleCalendarRowContext(
            palette: ThemeID.dark.palette, now: Date(timeIntervalSince1970: 3_000), calendar: .current,
            badge: nil, assetCache: nil, isAccessibilitySize: false, showsTime: true, isNext: false, isWide: false
        )
    }

    /// The night's subagents: 12 workers, 10 night agents, 4 scouts, `working` of the workers still going.
    private func subagents(working: Int) -> ScheduleCalendarAgenda.Subagents {
        let agents = Array(repeating: ("worker", "🛠"), count: 12) + Array(repeating: ("night", "🌙"), count: 10)
            + Array(repeating: ("scout", "🔎"), count: 4)
        let sessions = agents.enumerated().map { index, agent in
            var session = Session(
                id: "sub-\(index)", workspaceId: "oppi", name: "Subagent \(index)", status: .stopped,
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)), lastActivity: Date(timeIntervalSince1970: 2_000),
                messageCount: 10, tokens: TokenUsage(input: 0, output: 0), cost: index == 0 ? 0.07 : 1.5,
                launch: SessionLaunchMetadata(agentId: agent.0, agentIcon: .emoji(agent.1)), parentSessionId: "night"
            )
            if index < working {
                session.status = .busy
                session.programStatus = ProgramStatus(state: .working, since: Date(timeIntervalSince1970: 2_500))
            }
            return session
        }
        return ScheduleCalendarAgenda.Subagents(sessions: sessions)
    }

    /// `width` is what the row gives the strip on an iPhone 16 Pro (402 pt), as measured in the
    /// running app: the list's insets and the cell's margins taken off.
    private func layOut(_ subagents: ScheduleCalendarAgenda.Subagents, width: CGFloat = 336) -> UIView {
        let summary = SessionThreadStripSummary(descendants: subagents.sessions) { SessionListPresentation.classify($0) }
        let view = ScheduleCalendarRowViews.subagents(subagents, summary: summary, style: style, context: context)
        let height = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return view
    }

    private func all<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + all(type, in: $0) }
    }

    private func visible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return false }
            current = node.superview
        }
        return true
    }

    @Test("a settled run's subagents draw one line: the count, their cost, and the Agents, with no dots")
    func settledIsOneLine() throws {
        let view = layOut(subagents(working: 0))
        let counts = try #require(all(SessionThreadSummaryLabel.self, in: view).first)
        #expect(counts.text == "26 subagents")
        let cost = try #require(all(SessionThreadCountsLine.self, in: view).first?.cost)
        #expect(cost.text == "$37.57" && visible(cost))
        #expect(all(SessionThreadStatusRow.self, in: view).allSatisfy { !visible($0) }, "No dot line while nothing runs")

        let agents = try #require(all(SessionThreadAgentClusterView.self, in: view).first)
        #expect(visible(agents))
        #expect(agents.superview is SessionThreadCountsLine, "The Agents share the counts line")
        let groups = all(UILabel.self, in: agents).filter(visible).compactMap(\.text)
        #expect(groups == ["×12", "×10", "×4"], "Every Agent fits a phone's row, largest group first")
        let line = try #require(all(SessionThreadCountsLine.self, in: view).first)
        #expect(agents.convert(agents.bounds, to: line).maxX <= line.bounds.width + 0.5, "The Agents fit the line")
    }

    @Test("while subagents work, a dot each sits on its own line above the counts")
    func activeDrawsDots() throws {
        let view = layOut(subagents(working: 3))
        let row = try #require(all(SessionThreadStatusRow.self, in: view).first)
        #expect(visible(row))
        #expect(row.dots.intrinsicContentSize.width
            == 3 * SessionThreadStatusDotsView.dotSize + 2 * SessionThreadStatusDotsView.dotSpacing)
        let line = try #require(all(SessionThreadCountsLine.self, in: view).first)
        #expect(row.convert(row.bounds, to: view).maxY <= line.convert(line.bounds, to: view).minY, "Dots above the counts")
        #expect(line.summary.text == "26 subagents")
        #expect(row.agents.superview === row, "The Agents move to the dot line while it shows")
    }
}
