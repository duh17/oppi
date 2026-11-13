import UIKit
@testable import Oppi

/// A pane host in a real window whose primary leaf is `PaneLeafScreen`
/// (optionally in a navigation controller), the way the shell mounts its
/// stack. Its helpers drive the divider through the closures a live pan
/// calls.
@MainActor
struct PaneTestHost {
    let screen: PaneLeafScreen
    let panes: PaneHostController
    /// The window's pane state; a host of its own starts with no remembered width.
    let scenePanes: ScenePanes
    let window: UIWindow
    let root = makeTestAppRoot()

    init(
        width: CGFloat,
        height: CGFloat = 900,
        inNavigation: Bool = false,
        parkedViewLifetime: TimeInterval = 10,
        scenePanes: ScenePanes = ScenePanes()
    ) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { fatalError("Missing UIWindowScene for a pane test host") }
        let screen = PaneLeafScreen()
        let primary: UIViewController = inNavigation ? UINavigationController(rootViewController: screen) : screen
        let panes = PaneHostController(primary: primary, panes: scenePanes, parkedViewLifetime: parkedViewLifetime)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = panes
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.screen = screen
        self.panes = panes
        self.scenePanes = scenePanes
        self.window = window
    }

    /// The leaf's own width beside the companion.
    var screenWidth: CGFloat { panes.primary.view.frame.width }

    func showPanel(
        minWidth: CGFloat = 320,
        idealWidth: CGFloat = 400,
        maxWidth: CGFloat? = 640,
        settles: Bool = true,
        makeScreen: @escaping () -> UIViewController = { UIViewController() }
    ) {
        let show = {
            screen.showPanel(
                root: root, minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth, makeScreen: makeScreen
            )
        }
        if settles { act(show) } else { show() }
    }

    /// Runs `body` with UIKit animations off, so the host's springs land
    /// at once (`PaneHostController` honours `areAnimationsEnabled`).
    func act(_ body: () -> Void) {
        UIView.performWithoutAnimation(body)
        window.layoutIfNeeded()
    }

    /// One whole drag of the divider, released with no velocity, landed.
    func drag(by translationX: CGFloat) {
        let divider = divider
        divider.onBegan?()
        divider.onChanged?(translationX)
        act { divider.onEnded?(CGPoint(x: translationX, y: 0), .zero) }
    }

    func settle() {
        settlePaneMotion(in: window)
    }

    var divider: PaneDividerView { panes.divider }
    /// The companion's drawn width; nil with none shown.
    var companionWidth: CGFloat? { panes.shownCompanion?.view.frame.width }
    var companion: UIViewController? { panes.shownCompanion }
    var cover: UIView {
        guard let cover = panes.view.subviews.first(where: { $0.accessibilityIdentifier == "pane.cover" }) else {
            preconditionFailure("The pane host has no cover")
        }
        return cover
    }

    func resize(width: CGFloat) {
        window.frame.size.width = width
        window.layoutIfNeeded()
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// Runs the main run loop until the window's pane host has no spring in
/// flight (an open, snap or close moves its leaves' frames), then once more
/// so completions run. Only the host's own children count: a caret's blink
/// inside a leaf never ends.
@MainActor
func settlePaneMotion(in window: UIWindow, timeout: TimeInterval = 2) {
    func animating() -> Bool {
        let host = window.rootViewController.flatMap { root in
            root as? PaneHostController ?? root.children.lazy.compactMap { $0 as? PaneHostController }.first
        }
        return host?.view.subviews.contains { !($0.layer.animationKeys() ?? []).isEmpty } ?? false
    }
    // A close starts after the leaf's search has ended, a turn later.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let deadline = Date().addingTimeInterval(timeout)
    while animating(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    window.layoutIfNeeded()
}

extension PaneHostController {
    /// The host's divider, found as VoiceOver and UI tests find it.
    var divider: PaneDividerView {
        guard let divider = view.subviews.lazy.compactMap({ $0 as? PaneDividerView }).first else {
            preconditionFailure("The pane host has no divider")
        }
        return divider
    }

    /// The companion on screen: the host's child beside its primary.
    var shownCompanion: UIViewController? {
        children.first { $0 !== primary && !$0.view.isHidden }
    }
}

extension AttachedLeafController {
    /// The panel's own screen while the leaf is mounted: the root of the
    /// leaf's navigation controller.
    var mountedScreen: UIViewController? { mountedStack?.first }
    /// Every screen of the mounted leaf, root first.
    var mountedStack: [UIViewController]? { frontScreen?.navigationController?.viewControllers }
}

/// A bare screen with an attached leaf, the way the chat and the review
/// screens mount one. Its content counts its own layout passes (a reflow of
/// the leaf beside), follows the keyboard as the chat does, and records the
/// visibility its leaf reports and the holds and settles of a resize.
@MainActor
final class PaneLeafScreen: UIViewController, PaneKeyboardFollowing, PaneVisibilityObserving, PaneLiveResizing {
    enum LiveResize: Equatable {
        case held
        case settled(final: Bool)
    }

    lazy var leaf = AttachedLeafController(screen: self)
    let field = UITextField()
    var followsKeyboard = true
    private(set) var visibilities: [PaneVisibility] = []
    private(set) var liveResize: [LiveResize] = []
    private let content = LayoutCountingView()
    var layoutCount: Int { content.layoutCount }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.frame = view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content)
        view.addSubview(field)
        addChild(leaf)
        leaf.view.frame = .zero
        view.addSubview(leaf.view)
        leaf.didMove(toParent: self)
    }

    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        visibilities.append(visibility)
    }

    func paneWillBeginLiveResize() {
        liveResize.append(.held)
    }

    func paneSettleLiveResize(to size: CGSize, final: Bool) {
        liveResize.append(.settled(final: final))
    }

    func showPanel(
        root: AppRootEnvironment,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat?,
        makeScreen: @escaping () -> UIViewController
    ) {
        leaf.show(
            AttachedLeafController.Panel(
                id: "panel", minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                makeScreen: makeScreen
            ),
            root: root
        )
    }

    func hidePanel() {
        leaf.show(nil, root: nil)
    }
}

/// Counts its own layout passes and the visibility its leaf reports.
final class LayoutCountingView: UIView {
    private(set) var layoutCount = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCount += 1
    }
}

/// A companion screen that records the visibility its leaf reports and
/// counts its layout passes.
@MainActor
final class PaneCompanionScreen: UIViewController, PaneVisibilityObserving {
    private(set) var visibilities: [PaneVisibility] = []
    let field = UITextField()
    private let content = LayoutCountingView()
    var layoutCount: Int { content.layoutCount }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.frame = view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content)
        view.addSubview(field)
    }

    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        visibilities.append(visibility)
    }
}
