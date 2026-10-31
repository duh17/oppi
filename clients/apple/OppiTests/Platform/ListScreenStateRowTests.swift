import Testing
import UIKit
@testable import Oppi

/// The list kit's own state row, proven once instead of once per page: a load in
/// flight shows as the compact loading row where the rows will be, a failure is
/// one row whose title is the page's and whose reason is the request's, with one
/// Retry that keeps its place while the Retry runs and leaves with a load that
/// succeeds, and a page whose load settled with nothing shows its empty state.
/// The whole-screen state a page with no rows gets is the same failure.
@Suite("List screen state row")
@MainActor
struct ListScreenStateRowTests {
    @Test("A load in flight shows the compact loading row while the page has nothing")
    func loadingRowWhileThereIsNothing() async throws {
        let page = StateRowPage()
        page.outcome = .held
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Loading things…"
        })
        let row = try #require(Self.row(in: page))
        #expect(!row.accessibilityTraits.contains(.button), "a loading row says nothing to press")
        #expect(page.shownItems.isEmpty, "the row is the kit's, not the page's item")
        page.releaseHeld()
    }

    @Test("A failure is the page's title over the request's reason, one row with one Retry")
    func failureRowRetries() async throws {
        let page = StateRowPage()
        page.outcome = .requestFailed("not found")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Couldn't Load Things. not found"
        })
        let failed = try #require(Self.row(in: page))
        #expect(failed.accessibilityTraits.contains(.button))
        #expect(failed.accessibilityHint == SettingsStateRowCell.retryTitle)
        #expect(Self.rows(in: page).count == 1, "one row, never a red label and a Retry of its own")
        #expect(Self.reasonLine(in: page) == "not found", "the reason is its own line under the title")

        // A failure the page recovered its rows from shows under them.
        page.rows = ["kept"]
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.shownItems == ["kept"] && Self.row(in: page)?.accessibilityLabel == "Couldn't Load Things. not found"
        }, "the rows it kept stay listed under the failure")

        // Retry runs the load, and its row becomes the loading row: the same cell,
        // so VoiceOver focus stays on it.
        page.outcome = .held
        failed.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 2 },
                "the Retry loaded the page again")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Loading things…"
        })
        let loading = try #require(Self.row(in: page))
        #expect(loading === failed, "the same row, so VoiceOver focus stays on it")
        #expect(!loading.accessibilityTraits.contains(.button))

        // A load that succeeds takes the row away.
        page.outcome = .success(["kept", "loaded"])
        page.releaseHeld()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return !page.shownItems.isEmpty && Self.rows(in: page).isEmpty
        }, "a successful Retry leaves no state row")
    }

    @Test("A load that could not run is its own title, with no reason under it")
    func pageWordsFailureIsItsTitle() async throws {
        let page = StateRowPage()
        page.outcome = .pageWords("Server is offline")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Server is offline"
        })
        #expect(Self.reasonLine(in: page) == nil, "a complete title needs no second line")
    }

    @Test("A page with no rows states the same failure over the whole screen")
    func wholeScreenFailure() async throws {
        let page = StateRowPage()
        page.stateSectionName = nil
        page.outcome = .requestFailed("not found")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            (page.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text == "Couldn't Load Things"
        }, "a page with nothing to list is its state")
        let shown = try #require(page.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        #expect(shown.secondaryText == "not found")
        #expect(page.shownItems.isEmpty)
    }

    @Test("A load that settled with nothing is the page's empty state")
    func emptyStateWhenTheLoadSettledWithNothing() async throws {
        let page = StateRowPage()
        page.outcome = .success([])
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Nothing here."
        })
        let row = try #require(Self.row(in: page))
        #expect(!row.isUserInteractionEnabled, "an empty state has nothing to press")
        #expect(!row.accessibilityTraits.contains(.button))
    }

    @Test("A page that names no state section draws no row of the kit's")
    func noStateSection() async throws {
        let page = StateRowPage()
        page.stateSectionName = nil
        page.outcome = .success(["row"])
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.shownItems == ["row"]
        })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            page.view.layoutIfNeeded()
            return Self.rows(in: page).isEmpty
        }, "the page keeps its own state: the kit adds no row it was not asked for")
    }

    // MARK: - Helpers

    private func show(_ page: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        return window
    }

    private func hide(_ window: UIWindow) {
        if let page = (window.rootViewController as? UINavigationController)?.viewControllers.first as? StateRowPage {
            page.releaseHeld()
        }
        hideTestWindow(window)
        window.rootViewController = nil
    }

    /// The state row's one button, whatever it is showing: the cell paints the
    /// row and the button over it is its accessible element.
    private static func row(in page: StateRowPage) -> UIButton? {
        page.view.layoutIfNeeded()
        return rows(in: page).first
    }

    private static func rows(in page: StateRowPage) -> [UIButton] {
        var found: [UIButton] = []
        for cell in page.collectionView.visibleCells {
            found += button(withIdentifier: "test.states.state", in: cell)
        }
        return found.filter { !$0.isHidden }
    }

    /// The reason under a failed row's title the reason the cell lays out between its title and
    /// its Retry, read by position rather than by its words, so the test proves
    /// the line is on screen.
    private static func reasonLine(in page: StateRowPage) -> String? {
        page.view.layoutIfNeeded()
        guard let cell = page.collectionView.visibleCells.first(where: { $0 is SettingsStateRowCell }) else {
            return nil
        }
        let lines = labels(in: cell)
            .filter { !$0.isHidden && $0.frame.height > 0 && ($0.text?.isEmpty == false) }
            .sorted { $0.frame.minY < $1.frame.minY }
        return lines.count == 3 ? lines[1].text : nil
    }

    private static func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    private static func button(withIdentifier identifier: String, in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { found.append(button) }
        for subview in view.subviews { found += button(withIdentifier: identifier, in: subview) }
        return found
    }
}

/// A page whose load the test drives, with the kit's state row in a section of
/// its own: the state row's behaviour is the base's, so the page only says what
/// it loads and what its empty state is.
private final class StateRowPage: ListScreenController<StateRowPage.Section, String> {
    enum Section: Hashable, Sendable { case rows, status }

    enum Outcome {
        case success([String])
        /// A request's failure: the page's title over this reason.
        case requestFailed(String)
        /// The page's own words for a load that could not run: its whole title.
        case pageWords(String)
        /// Answers once the test releases it.
        case held
    }

    var outcome: Outcome = .success([])
    /// The section the kit puts its state row in; nil leaves the row to the page.
    var stateSectionName: Section? = .status
    var rows: [String] = []
    private(set) var loads = 0
    private var isHolding = false
    private var gates: [CheckedContinuation<Void, Never>] = []

    init() {
        super.init(title: "States", listIdentifier: "test.states.list")
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func stateSection() -> Section? { stateSectionName }

    override func hasContent() -> Bool { !rows.isEmpty }

    override func loadingCaption() -> String? { "Loading things…" }

    /// The page's own title, told apart from the base's fallback so the test
    /// proves the override is what heads the row.
    override func failureTitle() -> String? { "Couldn't Load Things" }

    override func emptyState() -> LoadState? {
        .empty(title: "Nothing here.", systemImage: "tray")
    }

    override func sections() -> [ListSection<Section, String>] {
        var sections = [ListSection<Section, String>(.rows, items: rows)]
        if stateSectionName != nil { sections.append(ListSection(.status, items: [])) }
        return sections
    }

    override func configure(_ cell: UICollectionViewListCell, item: String) {
        var content = UIListContentConfiguration.cell()
        content.text = item
        cell.contentConfiguration = content
    }

    override func inputs(of item: String) -> AnyHashable { AnyHashable(item) }

    override func load() async throws {
        loads += 1
        switch outcome {
        case .success(let answer):
            rows = answer
        case .requestFailed(let reason):
            throw RequestFailed(reason: reason)
        case .pageWords(let words):
            throw LoadFailure(words)
        case .held:
            isHolding = true
            await withCheckedContinuation { gates.append($0) }
            isHolding = false
            guard !Task.isCancelled else { return }
            rows = ["loaded"]
        }
        setNeedsUpdateProperties()
    }

    /// Answers the oldest load still waiting, in the order they started.
    func releaseHeld() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

/// A request's failure: its reason, which the page's title heads.
private struct RequestFailed: LocalizedError {
    var reason: String

    var errorDescription: String? { reason }
}
