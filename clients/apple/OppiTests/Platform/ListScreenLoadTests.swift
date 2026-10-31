import Testing
import UIKit
@testable import Oppi

/// The kit's load lifecycle, proven once instead of once per page: one task per
/// page, started by the page's policy and by what the page loads, cancelled when
/// the page leaves and when its subject changes, and never showing a cancel as a
/// failure.
@Suite("List screen load lifecycle")
@MainActor
struct ListScreenLoadTests {
    @Test("A page that loads each appearance loads on appearance, a pull to refresh, and a subject change")
    func eachAppearanceLoadsEveryTime() async throws {
        let page = LoadPage(policy: .eachAppearance)
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["First"] })
        #expect(page.loads == 1)
        #expect(page.collectionView.refreshControl != nil, "a page that loads has the list's pull to refresh")

        page.collectionView.refreshControl?.sendActions(for: .valueChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 2 }, "pull to refresh loads")

        // Away and back: another appearance is another load.
        window.rootViewController = UIViewController()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })
        window.rootViewController = UINavigationController(rootViewController: page)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 3 }, "appearing loads")
    }

    @Test("A page that loads once keeps what it loaded when it appears again, and setNeedsLoad loads")
    func onceUntilSubjectChangesKeepsWhatItLoaded() async throws {
        let page = LoadPage(policy: .onceUntilSubjectChanges)
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["First"] })

        window.rootViewController = UIViewController()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })
        page.answer = "Second"
        window.rootViewController = UINavigationController(rootViewController: page)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isShowing })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.loads == 1 },
                "appearing again does not load")
        #expect(page.rows == ["First"], "the page keeps what it loaded")

        // A pull to refresh or a Retry still loads.
        page.collectionView.refreshControl?.sendActions(for: .valueChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Second"] },
                "a pull to refresh loads the page that loads once")

        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 3 }, "setNeedsLoad loads")
    }

    @Test("A page that loads nothing has no task and no pull to refresh")
    func noPolicyLoadsNothing() async throws {
        let page = LoadPage(policy: .none)
        let window = try show(page)
        defer { hide(window) }

        #expect(page.collectionView.refreshControl == nil, "a page that loads nothing has no spinner to pull")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.loads == 0 })
    }

    @Test("A subject change cancels the running load, drops what it showed, and starts the new one")
    func subjectChangeCancelsAndRestarts() async throws {
        let page = LoadPage(policy: .eachAppearance)
        page.subject = "server-a"
        page.outcome = .held
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isHolding })

        // Another server: the load for the old one is no longer this page's.
        page.subject = "server-b"
        page.answer = "From b"
        page.outcome = .success
        page.setNeedsUpdateProperties()

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["From b"] })
        #expect(page.subjectChanges == 1, "the page drops what the old subject showed")
        #expect(page.loads == 2, "the change starts a load for the new subject")

        // The old subject's answer arrives late and changes nothing.
        page.answer = "From a"
        page.releaseHoldingLoad()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { page.rows == ["From b"] })
        #expect(page.loadFailure == nil)
    }

    @Test("Leaving cancels the load and stores no error")
    func leavingCancelsAndStoresNoError() async throws {
        let page = LoadPage(policy: .eachAppearance)
        page.outcome = .held
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isHolding })
        #expect(page.isLoading)

        window.rootViewController = UIViewController()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })
        #expect(!page.isLoading, "a page that left is not loading")
        #expect(page.loadFailure == nil, "a cancelled load is not a failure")

        // What it finds after the page is gone is nobody's answer.
        page.releaseHoldingLoad()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            page.rows.isEmpty && page.loadFailure == nil
        })
    }

    @Test("A load cancelled under the page is not a failure")
    func cancelledLoadIsNotAFailure() async throws {
        let page = LoadPage(policy: .eachAppearance)
        page.outcome = .cancelled
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loads == 1 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            page.loadFailure == nil && !page.isLoading
        }, "a cancel is control flow, not a failure to report")
    }

    @Test("A thrown error is the page's failure, and setNeedsLoad loads again and clears it")
    func aThrownErrorIsTheFailure() async throws {
        let page = LoadPage(policy: .eachAppearance)
        page.outcome = .failure("Server offline")
        let window = try show(page)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loadFailure == "Server offline" })
        #expect(!page.isLoading)

        // A Retry (or a foreground return, a settled sign-in) asks for a load.
        page.outcome = .success
        page.answer = "Loaded"
        page.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.rows == ["Loaded"] })
        #expect(page.loadFailure == nil, "a load that succeeds clears the failure")
        #expect(page.loads == 2)
    }

    @Test("A row a page does not key is drawn again when what it draws changes")
    func defaultInputsRedrawAChangedRow() async throws {
        let page = UnkeyedPage()
        let window = try show(page, navigation: false)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.rowText(in: page) == "First title"
        })

        // The page draws a value it does not declare in `inputs(of:)`; the pass
        // that follows draws the row again instead of leaving it stale.
        page.rowTitle = "Second title"
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.rowText(in: page) == "Second title"
        }, "the default key redraws the row the page did not key")
    }

    // MARK: - Helpers

    private func show(_ page: UIViewController, navigation: Bool = true) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = navigation ? UINavigationController(rootViewController: page) : page
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        if let page = (window.rootViewController as? UINavigationController)?.viewControllers.first as? LoadPage {
            page.releaseHoldingLoad()
        }
        hideTestWindow(window)
        window.rootViewController = nil
    }

    private static func rowText(in page: UnkeyedPage) -> String? {
        page.view.layoutIfNeeded()
        guard let indexPath = page.indexPath(for: "row"),
              let cell = page.collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell else { return nil }
        return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }
}

/// A page whose load the test drives: it counts the loads, answers with what the
/// test set, and waits where the test wants a load in flight.
private final class LoadPage: ListScreenController<LoadPage.Section, String> {
    enum Section: Hashable, Sendable { case only }

    enum Outcome {
        case success
        case failure(String)
        /// Answers once the test releases it.
        case held
        /// Fails as a request cancelled under the page does.
        case cancelled
    }

    private let policy: LoadPolicy
    var subject: AnyHashable?
    var outcome: Outcome = .success
    /// What a successful load answers.
    var answer = "First"

    private(set) var loads = 0
    private(set) var subjectChanges = 0
    private(set) var rows: [String] = []
    private(set) var isHolding = false
    private var gate: CheckedContinuation<Void, Never>?

    init(policy: LoadPolicy) {
        self.policy = policy
        super.init(title: "Load", listIdentifier: "test.load.list")
    }

    override var loadPolicy: LoadPolicy { policy }

    override func loadSubject() -> AnyHashable? { subject }

    override func subjectDidChange() {
        subjectChanges += 1
        rows = []
        setNeedsUpdateProperties()
    }

    override func load() async throws {
        loads += 1
        switch outcome {
        case .success:
            rows = [answer]
        case .failure(let message):
            throw LoadFailure(message)
        case .cancelled:
            throw CancellationError()
        case .held:
            isHolding = true
            await withCheckedContinuation { gate = $0 }
            isHolding = false
            // A cancelled load's answer is nobody's: the page drops it, as a page
            // that awaited a request does with `Task.isCancelled`.
            guard !Task.isCancelled else { return }
            rows = [answer]
        }
        setNeedsUpdateProperties()
    }

    override func sections() -> [ListSection<Section, String>] {
        [ListSection(.only, items: rows)]
    }

    func releaseHoldingLoad() {
        guard let gate else { return }
        self.gate = nil
        gate.resume()
    }
}

/// A page that draws a value it does not declare as a row input.
private final class UnkeyedPage: ListScreenController<UnkeyedPage.Section, String> {
    enum Section: Hashable, Sendable { case only }

    var rowTitle = "First title"

    init() {
        super.init(title: "Unkeyed", listIdentifier: "test.unkeyed.list")
    }

    override func sections() -> [ListSection<Section, String>] {
        [ListSection(.only, items: ["row"])]
    }

    override func configure(_ cell: UICollectionViewListCell, item: String) {
        var content = UIListContentConfiguration.cell()
        content.text = rowTitle
        cell.contentConfiguration = content
    }
}
