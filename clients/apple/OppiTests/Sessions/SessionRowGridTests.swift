import Testing
import UIKit
@testable import Oppi

/// A thread's rows share one column grid with the row above them: the strip and the stopped fold start
/// on the thread root's title column and end on its trailing text column, and each child row starts one
/// title column further in. The list is the real one, so the cells' own margins are in the measurement.
@MainActor
@Suite("Session row grid")
struct SessionRowGridTests {
    private let rootId = "thread-root"
    /// The rows of the thread `entries` draws, in list order.
    private let items = ["thread-root", "child-working", "grandchild", "stopped-members:thread-root"]

    private func session(
        _ id: String,
        _ name: String,
        status: SessionStatus,
        parent: String? = nil,
        minutesAgo: Double
    ) -> Session {
        Session(
            id: id,
            workspaceId: "oppi",
            workspaceName: "oppi",
            name: name,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_000 - minutesAgo * 60),
            lastActivity: Date(timeIntervalSince1970: 2_000 - minutesAgo * 60),
            messageCount: 4,
            tokens: TokenUsage(input: 1_000, output: 200),
            cost: 0.4,
            parentSessionId: parent
        )
    }

    /// An open thread with a live child, its own working child, and a stopped child, so the strip, a
    /// first-level row, a second-level row, and the stopped fold all draw.
    private var entries: [SessionListEntry] {
        let sessions = [
            session(rootId, "Plan the router migration", status: .ready, minutesAgo: 60),
            session("child-working", "Migrate the chat routes", status: .busy, parent: rootId, minutesAgo: 40),
            session("grandchild", "Write the route table", status: .busy, parent: "child-working", minutesAgo: 30),
            session("child-stopped", "Audit the old routes", status: .stopped, parent: rootId, minutesAgo: 35),
        ]
        return SessionListEntries.expanding(
            SessionListEntries.threads(listed: sessions, loaded: []),
            expandedRoots: [rootId],
            stoppedFolds: [:],
            attention: { _ in .none }
        )
    }

    private var rowActions: SessionListRowActions {
        SessionListRowActions(
            open: { _ in },
            toggleThread: { _ in },
            toggleStoppedMembers: { _ in },
            stop: { _ in },
            resume: { _ in },
            delete: { _ in nil },
            lockTarget: { _ in nil }
        )
    }

    private func content(_ entry: SessionListEntry) -> SessionListRowContent {
        SessionListRowContent(
            entry: entry,
            presentation: SessionRowPresentationBuilder.make(session: entry.session, workspaceContext: "oppi"),
            statuses: [:]
        )
    }

    /// The real list at iPhone portrait width, with the open thread's rows in it.
    private func makeList() -> (
        list: SessionListCollection<Int, String, Int, Int>,
        window: UIWindow,
        rows: [SessionListEntry]
    ) {
        let list = SessionListCollection<Int, String, Int, Int>(
            root: makeTestAppRoot(),
            appearance: .plain,
            actions: rowActions,
            iconAssetCache: { nil },
            configureRow: { _, _ in },
            onToggle: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let controller = UIViewController()
        list.collectionView.frame = window.bounds
        controller.view.addSubview(list.collectionView)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let rows = entries
        var snapshot = SessionListCollection<Int, String, Int, Int>.Snapshot()
        snapshot.appendSection(0)
        snapshot.append(sessions: rows, to: 0, item: { $0 }, content: { [self] entry in content(entry) })
        list.apply(snapshot)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        list.collectionView.layoutIfNeeded()
        return (list, window, rows)
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    /// The views of `type` in the cell of `item`, in the collection view's coordinates.
    private func frames<T: UIView>(
        _ type: T.Type,
        ofItem item: Int,
        in list: SessionListCollection<Int, String, Int, Int>
    ) throws -> [CGRect] {
        let cell = try #require(list.collectionView.cellForItem(at: IndexPath(item: item, section: 0)))
        return descendants(of: cell, type).map { $0.convert($0.bounds, to: list.collectionView) }
    }

    /// The words a row draws, in the collection view's coordinates.
    private func labels(
        ofItem item: Int,
        in list: SessionListCollection<Int, String, Int, Int>
    ) throws -> [(text: String, frame: CGRect)] {
        let cell = try #require(list.collectionView.cellForItem(at: IndexPath(item: item, section: 0)))
        return descendants(of: cell, UILabel.self)
            .filter { !$0.isHidden && $0.bounds.width > 0 }
            .map {
                (
                    text: $0.text ?? $0.attributedText?.string ?? "",
                    frame: $0.convert($0.bounds, to: list.collectionView)
                )
            }
    }

    @Test func theThreadRowsShareTheRootRowsColumns() throws {
        let (list, window, rows) = makeList()
        defer { window.isHidden = true }
        #expect(rows.map(\.id) == items, "Not the rows this test measures")

        let strip = try #require(try frames(SessionThreadStripView.self, ofItem: 0, in: list).first)
        let fold = try #require(try frames(SessionThreadStoppedFoldControl.self, ofItem: 3, in: list).first)
        let rootRow = try #require(try frames(SessionRowView.self, ofItem: 0, in: list).first)
        let childRow = try #require(try frames(SessionRowView.self, ofItem: 1, in: list).first)
        let rootLabels = try labels(ofItem: 0, in: list)

        // The root row's two text columns, where its own words draw.
        let title = try #require(rootLabels.first { $0.text == rows[0].session.displayTitle })
        let titleColumn = title.frame.minX
        let textTrailing = try #require(rootLabels.map(\.frame.maxX).max())
        #expect(titleColumn > rootRow.minX, "The title column starts past the row's icon")
        let words = Comment(rawValue: rootLabels.map { "\($0.text)@\($0.frame.minX)" }.joined(separator: " | "))

        #expect(abs(strip.minX - titleColumn) < 0.5, words)
        #expect(abs(strip.maxX - textTrailing) < 0.5, "The strip ends at \(strip.maxX), not on the row's text edge \(textTrailing)")
        #expect(abs(fold.minX - titleColumn) < 0.5, "The stopped fold starts at \(fold.minX), not on the title column \(titleColumn)")
        #expect(abs(fold.maxX - textTrailing) < 0.5, "The stopped fold ends at \(fold.maxX), not on the row's text edge")
        #expect(
            abs(childRow.minX - titleColumn) < 0.5,
            "The child row starts at \(childRow.minX), so its icon is off the title column \(titleColumn)"
        )
    }

    /// Each level steps in by one title column, and the stopped fold sits at the first level's, level
    /// with the thread's child rows.
    @Test func eachLevelStepsInOneTitleColumn() throws {
        let (list, window, rows) = makeList()
        defer { window.isHidden = true }
        #expect(rows.map(\.id) == items, "Not the rows this test measures")

        let rootRow = try #require(try frames(SessionRowView.self, ofItem: 0, in: list).first)
        let rootTitle = try #require(try labels(ofItem: 0, in: list).first { $0.text == rows[0].session.displayTitle })
        let child = try #require(try frames(SessionRowView.self, ofItem: 1, in: list).first)
        let grandchild = try #require(try frames(SessionRowView.self, ofItem: 2, in: list).first)
        let fold = try #require(try frames(SessionThreadStoppedFoldControl.self, ofItem: 3, in: list).first)
        // The root row's own step from its leading edge to its title: the one step every level takes.
        let column = rootTitle.frame.minX - rootRow.minX

        #expect(column > 0)
        #expect(abs((grandchild.minX - child.minX) - column) < 0.5, "A level did not step one title column")
        #expect(abs(fold.minX - child.minX) < 0.5, "The fold sat at another depth than the thread's children")
    }
}
