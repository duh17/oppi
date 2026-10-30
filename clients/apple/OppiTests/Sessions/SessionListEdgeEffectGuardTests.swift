import Testing
import UIKit
@testable import Oppi

/// iOS's top scroll edge effect can grow to cover the rows an animated diff inserted and keep that
/// height: a blurred band over the session list after a thread folds open (`ed866aa9f` fixed the same
/// thing for a server switch). The list checks the effect once a fold's apply finishes. A normal fold
/// measures it and stops; a band relays the list out and leaves one breadcrumb.
@MainActor
@Suite("Session list edge effect guard")
struct SessionListEdgeEffectGuardTests {
    private let rootId = "thread-root"

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

    private var listedSessions: [Session] {
        [
            session(rootId, "Plan the router migration", status: .ready, minutesAgo: 60),
            session("child-working", "Migrate the chat routes", status: .busy, parent: rootId, minutesAgo: 40),
            session("child-kypu", "Check the kypu client", status: .busy, parent: rootId, minutesAgo: 25),
            session("child-done", "Audit the old routes", status: .stopped, parent: rootId, minutesAgo: 35),
        ]
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

    /// The real list at iPhone portrait width, under a bar's worth of top safe area, its thread closed.
    private func makeList() -> (list: SessionListCollection<Int, String, Int, Int>, window: UIWindow) {
        let list = SessionListCollection<Int, String, Int, Int>(
            root: makeTestAppRoot(),
            appearance: .plain,
            actions: rowActions,
            iconAssetCache: { nil },
            configureRow: { _, _ in },
            onToggle: { _ in }
        )
        let controller = UIViewController()
        // A navigation bar's worth of top inset: that is the height the effect gets from the bar.
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 96, left: 0, bottom: 0, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        list.collectionView.frame = window.bounds
        controller.view.addSubview(list.collectionView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        apply(threadOpen: false, to: list, in: window)
        return (list, window)
    }

    private func apply(
        threadOpen expanded: Bool,
        to list: SessionListCollection<Int, String, Int, Int>,
        in window: UIWindow
    ) {
        list.apply(snapshot(threadOpen: expanded))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        list.collectionView.layoutIfNeeded()
    }

    /// The thread's own rows once it lists open: its root, its two live members, and the closed fold row
    /// over the stopped one.
    private var openThreadRows: Int { 4 }

    /// The rows the list draws for `open` thread, as the list's own snapshot.
    private func snapshot(threadOpen expanded: Bool) -> SessionListCollection<Int, String, Int, Int>.Snapshot {
        let entries = SessionListEntries.expanding(
            SessionListEntries.threads(listed: listedSessions, loaded: []),
            expandedRoots: expanded ? [rootId] : [],
            stoppedFolds: [:],
            attention: { _ in .none }
        )
        var snapshot = SessionListCollection<Int, String, Int, Int>.Snapshot()
        snapshot.appendSection(0)
        snapshot.append(sessions: entries, to: 0, item: { $0 }, content: { entry in
            SessionListRowContent(
                entry: entry,
                presentation: SessionRowPresentationBuilder.make(session: entry.session, workspaceContext: "oppi"),
                statuses: [:])
        })
        return snapshot
    }

    /// The list's own fold detection: only a root row flipping `isExpanded` counts.
    @Test func onlyAFoldCounts() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }
        let closed = snapshot(threadOpen: false)
        let open = snapshot(threadOpen: true)

        #expect(list.foldsThreads(from: closed, to: open), "Opening a thread was not a fold")
        #expect(list.foldsThreads(from: open, to: closed), "Closing a thread was not a fold")
        #expect(!list.foldsThreads(from: closed, to: closed), "A list that only re-lists its rows was a fold")
        #expect(!list.foldsThreads(from: open, to: open), "An unchanged open thread was a fold")
    }

    /// A normal fold: the guard measures the effect and finds it the height the bar gives it.
    @Test func aNormalFoldMeasuresAndDoesNothingElse() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }
        var measured = 0
        var relayouts = 0
        var reports: [SessionListEdgeEffectReport] = []
        var guardrail = try #require(list.edgeEffectGuard)
        guardrail.measure = { _ in measured += 1; return 196 }
        guardrail.relayout = { relayouts += 1 }
        guardrail.report = { reports.append($0) }
        list.edgeEffectGuard = guardrail

        apply(threadOpen: true, to: list, in: window)
        list.checkTopEdgeEffect(wasAnimated: true)

        #expect(measured == 1, Comment(rawValue: "measured \(measured)"))
        #expect(relayouts == 0, "A normal fold relaid the list out")
        #expect(reports.isEmpty, "A normal fold left a breadcrumb")
        #expect(list.collectionView.numberOfItems(inSection: 0) == openThreadRows)
    }

    /// A band: taller than the bar by more than the tolerance, so the guard relays the list out and
    /// leaves one breadcrumb naming what it saw.
    @Test func aBandRelaysTheListOutAndLeavesOneBreadcrumb() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }
        var relayouts = 0
        var reports: [SessionListEdgeEffectReport] = []
        var guardrail = try #require(list.edgeEffectGuard)
        guardrail.measure = { _ in 376 }
        guardrail.relayout = { relayouts += 1 }
        guardrail.report = { reports.append($0) }
        list.edgeEffectGuard = guardrail

        apply(threadOpen: true, to: list, in: window)
        list.checkTopEdgeEffect(wasAnimated: true)

        #expect(relayouts == 1, "The guard did not relay the list out")
        #expect(reports.count == 1, "One band left \(reports.count) breadcrumbs")
        let report = try #require(reports.first)
        #expect(report.band == 376)
        #expect(report.expected == list.collectionView.adjustedContentInset.top, "Expected height is not the bar's")
        #expect(report.adjustedContentInset == list.collectionView.adjustedContentInset)
        #expect(report.wasAnimated, "The fold animated, so the report should say so")
        #expect(report.headerModes.allSatisfy { $0.hasSuffix(":none") }, "\(report.headerModes)")
        #expect(report.summary.contains("376"), Comment(rawValue: report.summary))
    }

    /// The real remedy: the list empties and applies its snapshot again without animation, so it still
    /// lists the thread's rows afterwards and does not check the effect a second time.
    @Test func theRealRelayoutLeavesTheListWholeAndDoesNotCheckAgain() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }
        var measures = 0
        var reports: [SessionListEdgeEffectReport] = []
        var guardrail = try #require(list.edgeEffectGuard)
        guardrail.measure = { _ in measures += 1; return 900 }
        guardrail.report = { reports.append($0) }
        list.edgeEffectGuard = guardrail

        apply(threadOpen: true, to: list, in: window)
        list.checkTopEdgeEffect(wasAnimated: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        list.collectionView.layoutIfNeeded()

        #expect(reports.count == 1, "The remedy's own apply checked the effect again")
        #expect(measures == 1, "The guard measured \(measures) times for one fold")
        #expect(
            list.collectionView.numberOfItems(inSection: 0) == openThreadRows,
            "The relayout lost the thread's rows: \(list.collectionView.numberOfItems(inSection: 0))"
        )
    }

    /// The pinned header and the sections' header modes are what a breadcrumb needs to tell a band from a
    /// bar the list misread, so a report carries them rather than leaving them out.
    @Test func aReportNamesThePinnedHeaderAndTheHeaderModes() throws {
        let (list, window) = makeList()
        defer { window.isHidden = true }
        var reports: [SessionListEdgeEffectReport] = []
        var guardrail = try #require(list.edgeEffectGuard)
        guardrail.measure = { _ in 376 }
        guardrail.relayout = {}
        guardrail.report = { reports.append($0) }
        list.edgeEffectGuard = guardrail

        apply(threadOpen: true, to: list, in: window)
        list.checkTopEdgeEffect(wasAnimated: true)

        let report = try #require(reports.first)
        #expect(report.headerModes == ["0:none"], Comment(rawValue: report.headerModes.description))
        #expect(report.pinnedHeader == nil, "A section without a header pinned one")
    }

    /// The breadcrumb itself: the client log carries every number a band needs named, so an occurrence on
    /// a device can be read from the server's `telemetry/client-logs-*.jsonl`.
    @Test func theBreadcrumbCarriesTheNumbersAnOperatorNeeds() {
        let report = SessionListEdgeEffectReport(
            band: 376,
            expected: 170,
            adjustedContentInset: UIEdgeInsets(top: 170, left: 0, bottom: 86, right: 0),
            pinnedHeader: CGRect(x: 0, y: 40, width: 402, height: 44),
            headerModes: ["0:supplementary"],
            wasAnimated: true
        )

        let metadata = SessionListEdgeEffect.metadata(for: report)

        #expect(
            Set(metadata.keys) == ["band", "expected", "insetTop", "insetBottom", "pinnedHeader", "headerModes", "animated"],
            Comment(rawValue: metadata.keys.sorted().joined(separator: ","))
        )
        #expect(metadata["band"] == "376.0")
        #expect(metadata["expected"] == "170.0")
        #expect(metadata["insetTop"] == "170.0")
        #expect(metadata["insetBottom"] == "86.0")
        #expect(metadata["pinnedHeader"] == "40.0…84.0")
        #expect(metadata["headerModes"] == "0:supplementary")
        #expect(metadata["animated"] == "true")
    }
}
