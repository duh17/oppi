import Testing
import UIKit
@testable import Oppi

/// A screen whose body is one `LoadState`. The state is shown through
/// `UIContentUnavailableView`, the region rendering this commit ships: a
/// controller's own `contentUnavailableConfiguration` is hosted by UIKit on a
/// display pass the test process does not run, so its view is not inspectable
/// here (UI tests cover that path on the running app).
@MainActor
private final class StateScreen: UIViewController {
    var state: LoadState = .connecting {
        didSet { paint() }
    }

    /// Starts as the state it shows, not as a loading placeholder.
    private lazy var body = UIContentUnavailableView(loadState: state)

    override func loadView() {
        view = UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        paint()
    }

    func buttons(in view: UIView? = nil) -> [UIButton] {
        let scope = view ?? body
        let own = (scope as? UIButton).map { [$0] } ?? []
        return own + scope.subviews.flatMap { buttons(in: $0) }
    }

    /// The buttons the person can see and press.
    func visibleButtons() -> [UIButton] {
        view.layoutIfNeeded()
        return buttons().filter { !$0.isHidden && $0.window != nil && $0.alpha > 0 }
    }

    /// The words on the state view itself, which exist only once UIKit has
    /// built it (the configuration alone would answer before any layout).
    func labels() -> [String] {
        func labels(in view: UIView) -> [String] {
            let own = (view as? UILabel)?.text.map { [$0] } ?? []
            return own + view.subviews.flatMap { labels(in: $0) }
        }
        view.layoutIfNeeded()
        return labels(in: body)
    }

    var shown: UIContentUnavailableConfiguration? {
        body.configuration as? UIContentUnavailableConfiguration
    }

    private func paint() {
        let palette = ThemeRuntimeState.currentPalette()
        body.configuration = UIContentUnavailableConfiguration.loadState(
            state,
            palette: palette,
            background: palette.bg
        )
    }
}

@Suite("LoadState content", .serialized)
@MainActor
struct LoadStateContentTests {
    private func mount(_ screen: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func view(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let found = self.view(identifier: identifier, in: subview) { return found }
        }
        return nil
    }

    /// Waits for the state's view to show `predicate`: the labels and the button
    /// arrive on a later layout pass, not in the same runloop turn as the
    /// configuration.
    private func settle(_ screen: StateScreen, until predicate: @escaping () -> Bool) async {
        _ = await waitForMainActorCondition(timeout: .seconds(2)) {
            screen.view.layoutIfNeeded()
            return predicate()
        }
    }

    @Test func aFailureWithRetryShowsOneRetryButtonThatRunsIt() async throws {
        let screen = StateScreen()
        let window = try mount(screen)
        defer { hideTestWindow(window) }
        var retries = 0
        screen.state = .failed(title: "Unable to Load", message: "Server is offline", retry: RetryAction { retries += 1 })
        await settle(screen) { screen.visibleButtons().count == 1 }

        let shown = screen.visibleButtons()
        #expect(shown.map { $0.configuration?.title } == ["Retry"], "one Retry button")
        #expect(retries == 0, "a Retry on screen does not run on its own")
        shown.first?.sendActions(for: .primaryActionTriggered)
        #expect(retries == 1, "pressing Retry runs the state's action")
    }

    @Test func aFailureWithoutRetryShowsNoButton() async throws {
        let screen = StateScreen()
        let window = try mount(screen)
        defer { hideTestWindow(window) }
        screen.state = .failed(title: "Unable to Load", message: "Server is offline", retry: nil)
        // Wait for the built view's words, not the configuration: a state with no
        // retry must come out of layout with no button, not merely with
        // `retry == nil` in the value we just assigned.
        await settle(screen) { screen.labels().contains("Unable to Load") }

        #expect(screen.labels().contains("Unable to Load"), "the failure's title is on the view")
        #expect(screen.labels().contains("Server is offline"), "the failure's reason is on the view")
        #expect(screen.visibleButtons().isEmpty, "a screen with no way to reload shows no button")
    }

    @Test func aStateChangeReplacesTheConfigurationAndTheOldRetryNeverFires() async throws {
        let screen = StateScreen()
        let window = try mount(screen)
        defer { hideTestWindow(window) }
        var first = 0
        var second = 0
        screen.state = .failed(title: "Unable to Load", message: "one", retry: RetryAction { first += 1 })
        await settle(screen) { screen.visibleButtons().count == 1 }

        // A new failure: its Retry is the one that runs.
        screen.state = .failed(title: "Unable to Load", message: "two", retry: RetryAction { second += 1 })
        await settle(screen) {
            screen.labels().contains("two") && screen.visibleButtons().count == 1
        }
        #expect(screen.shown?.secondaryText == "two")
        try #require(screen.visibleButtons().first).sendActions(for: .primaryActionTriggered)
        #expect((first, second) == (0, 1), "the Retry on screen belongs to the second state")

        // Loading again: the button goes with the state. (UIKit keeps the same
        // button instance inside the view and only hides it, so the check is what
        // the person can reach, not whether the object is still in the tree.)
        screen.state = .loading("Loading…")
        await settle(screen) {
            screen.shown?.text == "Loading…" && screen.visibleButtons().isEmpty
        }
        #expect(screen.visibleButtons().isEmpty, "loading offers nothing to press")
        #expect((first, second) == (0, 1), "only the state on screen ran its Retry")
    }

    /// A screen that owns its state view gives it a stable scoped id, so a test
    /// or driver finds the Retry inside that scope, not by title across the
    /// screen. Server Metrics is the screen that owns one today.
    @Test func aScreenFindsRetryInsideItsScopedStateView() async throws {
        let page = UIViewController()
        page.view = UIView()
        let status = ServerMetricsStatusView(frame: CGRect(x: 0, y: 0, width: 358, height: 220))
        page.view.addSubview(status)
        let window = try mount(page)
        defer { hideTestWindow(window) }

        var retries = 0
        status.onRetry = { retries += 1 }
        status.apply(ThemeRuntimeState.currentPalette())
        status.show(.failed("Server is offline"))

        let scope = try #require(view(identifier: "server.metrics.status", in: page.view), "the state view's scoped id")
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            page.view.layoutIfNeeded()
            return !scope.subviews.isEmpty
        })
        let retry = try #require(
            scope.concreteButtons.first { $0.configuration?.title == "Retry" },
            "Retry sits inside the scoped state view"
        )
        #expect(retry.window != nil, "and it is on screen")
        retry.sendActions(for: .primaryActionTriggered)
        #expect(retries == 1, "pressing it retries the metrics load")
    }
}

private extension UIView {
    /// Every button under this view, itself included.
    var concreteButtons: [UIButton] {
        let own = (self as? UIButton).map { [$0] } ?? []
        return own + subviews.flatMap(\.concreteButtons)
    }
}
