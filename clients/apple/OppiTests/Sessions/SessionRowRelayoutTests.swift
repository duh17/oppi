import Testing
import UIKit
@testable import Oppi

/// A session row's cell must always be tall enough for the rows it draws.
///
/// A list measures an item once and keeps that height. A row then changes its
/// own constraints — Compact splitting its details onto a second line at a
/// narrower width, a search snippet, a Thread strip, or a lock hiding the
/// details — and none of that goes through the list's snapshot. The cell has to
/// be measured again, or the taller content is squeezed into the old height and
/// its detail lines are drawn on top of each other.
@MainActor
@Suite("Session row relayout")
struct SessionRowRelayoutTests {
    private func richSession() -> Session {
        var session = Session(
            id: "row-relayout-session",
            workspaceId: "w1",
            workspaceName: "tools",
            name: "start server",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_010_800),
            messageCount: 30,
            tokens: TokenUsage(input: 1_000, output: 200),
            cost: 2.4
        )
        session.model = "openai-codex/gpt-6-luna"
        session.contextTokens = 87_000
        session.contextWindow = 272_000
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 3,
            compactionCount: 1,
            filesChanged: 3,
            changedFiles: ["a.swift", "b.swift", "c.swift"]
        )
        return session
    }

    private var rowContent: SessionListRowContent {
        let session = richSession()
        return SessionListRowContent(
            entry: SessionListEntry(session: session, thread: nil, outsideRoot: nil),
            presentation: SessionRowPresentationBuilder.make(session: session, workspaceContext: "tools"),
            statuses: [:]
        )
    }

    private var rowActions: SessionListRowActions {
        SessionListRowActions(
            open: { _ in },
            openThread: { _ in },
            stop: { _ in },
            resume: { _ in },
            delete: { _ in nil },
            lockTarget: { _ in nil }
        )
    }

    /// The real session list, hosted at iPhone portrait width with one row in
    /// Compact, where every fact shares one detail line while it fits.
    private func makeList() -> (list: SessionListCollection<Int, Int, Int, Int>, window: UIWindow) {
        let root = makeTestAppRoot(
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay(density: .compact))
        )
        let list = SessionListCollection<Int, Int, Int, Int>(
            root: root,
            appearance: .plain,
            actions: rowActions,
            iconAssetCache: { nil },
            configureRow: { _, _ in },
            onToggle: { _ in }
        )
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        list.collectionView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(list.collectionView)
        NSLayoutConstraint.activate([
            list.collectionView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            list.collectionView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            list.collectionView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            list.collectionView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
        ])
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        var snapshot = SessionListCollection<Int, Int, Int, Int>.Snapshot()
        snapshot.appendSection(0)
        snapshot.append(sessions: [rowContent.entry], to: 0, item: { _ in 0 }) { _ in rowContent }
        list.apply(snapshot)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        list.collectionView.layoutIfNeeded()
        return (list, window)
    }

    private func itemHeight(_ list: SessionListCollection<Int, Int, Int, Int>) -> CGFloat {
        list.collectionView.layoutIfNeeded()
        return list.collectionView
            .layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?
            .frame.height ?? -1
    }

    /// The row the list's cell draws.
    private func rowView(in list: SessionListCollection<Int, Int, Int, Int>) -> SessionRowView? {
        func find(_ view: UIView) -> SessionRowView? {
            if let row = view as? SessionRowView { return row }
            for subview in view.subviews {
                if let row = find(subview) { return row }
            }
            return nil
        }
        return list.collectionView.visibleCells.compactMap { find($0) }.first
    }

    /// Frames of the labels the row draws, by their text.
    private func label(_ text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for subview in view.subviews {
            if let label = label(text, in: subview) { return label }
        }
        return nil
    }

    /// Compact joins the workspace, model, context gauge, cost, and status on
    /// one line at iPhone portrait width, and needs a second line for the same
    /// facts in Standard. The row rearranges those constraints itself, outside
    /// any snapshot, so the list must measure the cell again.
    @Test func rowThatRearrangesItsDetailsIsMeasuredAgain() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }

        let compactHeight = itemHeight(list)
        #expect(compactHeight > 0, "The row never measured")

        let row = try #require(rowView(in: list), "No session row in the list's cell")
        let session = richSession()
        // What `SessionListEntryContentView.apply` does for a reconfigured row.
        row.apply(
            SessionRowView.Content(
                presentation: SessionRowPresentationBuilder.make(session: session, workspaceContext: "tools")
            ),
            display: .standard,
            themeID: .dark,
            iconAssetCache: nil
        )
        // Let the self-sizing invalidation land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        list.collectionView.layoutIfNeeded()

        let standardHeight = itemHeight(list)
        #expect(
            standardHeight > compactHeight + 0.5,
            "The cell kept the height it measured for the one-line row: \(standardHeight) vs \(compactHeight)"
        )

        // The two detail rows are drawn apart, not on top of each other.
        if let workspace = label("tools", in: row), let gauge = label("87%", in: row) {
            let workspaceFrame = workspace.convert(workspace.bounds, to: row)
            let gaugeFrame = gauge.convert(gauge.bounds, to: row)
            #expect(
                workspaceFrame.maxY <= gaugeFrame.minY + 0.5,
                "Detail rows overlap: workspace \(workspaceFrame), gauge \(gaugeFrame)"
            )
        }
    }
}
