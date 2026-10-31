import Testing
import UIKit
@testable import Oppi

/// The list kit's own state row, proven once instead of once per page: a load in
/// flight shows as the compact loading row where the rows will be, a failure is
/// one row with one Retry that keeps its place while the Retry runs, and a page
/// whose load settled with nothing shows its empty state. A page that names no
/// state section draws no row of the kit's.
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

    @Test("A failure is one row with one Retry, under the rows the page kept")
    func failureRowRetries() async throws {
        let page = StateRowPage()
        page.outcome = .failure("Could not load.")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.row(in: page)?.accessibilityLabel == "Could not load."
        })
        let failed = try #require(Self.row(in: page))
        #expect(failed.accessibilityTraits.contains(.button))
        #expect(failed.accessibilityHint == SettingsStateRowCell.retryTitle)
        #expect(Self.rows(in: page).count == 1, "one row, never a red label and a Retry of its own")

        // A failure the page recovered its rows from shows under them.
        page.rows = ["kept"]
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.shownItems == ["kept"] && Self.row(in: page)?.accessibilityLabel == "Could not load."
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
        page.releaseHeld()
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
    func noStateSectionDrawsNoRow() async throws {
        let page = StateRowPage()
        page.stateSectionName = nil
        page.outcome = .failure("Could not load.")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 1 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            page.view.layoutIfNeeded()
            return Self.rows(in: page).isEmpty
        }, "the page keeps its own state: the kit adds no row it was not asked for")
        #expect(page.shownItems.isEmpty)
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
            found += button(withIdentifier: "test.states.loading", in: cell)
            found += button(withIdentifier: "test.states.failed", in: cell)
            found += button(withIdentifier: "test.states.empty", in: cell)
        }
        return found.filter { !$0.isHidden }
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
        case failure(String)
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

    override func emptyState() -> LoadState? {
        .empty(title: "Nothing here.", systemImage: "tray")
    }

    override var stateRowIdentifiers: StateRowIdentifiers {
        StateRowIdentifiers(loading: "test.states.loading", failed: "test.states.failed", empty: "test.states.empty")
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
        case .failure(let message):
            throw LoadFailure(message)
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
