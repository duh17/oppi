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
    let body = UIContentUnavailableView(loadState: .loading(nil))

    var state: LoadState = .connecting {
        didSet { paint() }
    }

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

    private func paint() {
        let palette = ThemeRuntimeState.currentPalette()
        body.configuration = UIContentUnavailableConfiguration.loadState(
            state,
            palette: palette,
            background: UIColor(palette.bg)
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

    private func buttons(in view: UIView) -> [UIButton] {
        let own = (view as? UIButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    /// The buttons the person can see and press.
    private func visibleButtons(in screen: StateScreen) -> [UIButton] {
        screen.view.layoutIfNeeded()
        return buttons(in: screen.body).filter { !$0.isHidden && $0.window != nil && $0.alpha > 0 }
    }

    /// The state on screen, as the type that carries the words and the button.
    private func shown(_ screen: StateScreen) -> UIContentUnavailableConfiguration? {
        screen.body.configuration as? UIContentUnavailableConfiguration
    }

    /// Waits for the state's view to show `predicate`: the button arrives on a
    /// later layout pass, not in the same runloop turn as the configuration.
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
        await settle(screen) { self.visibleButtons(in: screen).count == 1 }

        let shown = visibleButtons(in: screen)
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
        await settle(screen) { self.shown(screen)?.text == "Unable to Load" }

        #expect(visibleButtons(in: screen).isEmpty, "a screen with no way to reload shows no button")
        #expect(shown(screen)?.text == "Unable to Load")
        #expect(shown(screen)?.secondaryText == "Server is offline")
    }

    @Test func aStateChangeReplacesTheConfigurationAndTheOldRetryNeverFires() async throws {
        let screen = StateScreen()
        let window = try mount(screen)
        defer { hideTestWindow(window) }
        var first = 0
        var second = 0
        screen.state = .failed(title: "Unable to Load", message: "one", retry: RetryAction { first += 1 })
        await settle(screen) { self.visibleButtons(in: screen).count == 1 }

        // A new failure: its Retry is the one that runs.
        screen.state = .failed(title: "Unable to Load", message: "two", retry: RetryAction(id: "again") { second += 1 })
        await settle(screen) {
            self.shown(screen)?.secondaryText == "two" && self.visibleButtons(in: screen).count == 1
        }
        #expect(shown(screen)?.secondaryText == "two")
        try #require(visibleButtons(in: screen).first).sendActions(for: .primaryActionTriggered)
        #expect((first, second) == (0, 1), "the Retry on screen belongs to the second state")

        // Loading again: the button goes with the state. (UIKit keeps the same
        // button instance inside the view and only hides it, so the check is what
        // the person can reach, not whether the object is still in the tree.)
        screen.state = .loading("Loading…")
        await settle(screen) {
            self.shown(screen)?.text == "Loading…" && self.visibleButtons(in: screen).isEmpty
        }
        #expect(visibleButtons(in: screen).isEmpty, "loading offers nothing to press")
        #expect((first, second) == (0, 1), "only the state on screen ran its Retry")
    }
}
