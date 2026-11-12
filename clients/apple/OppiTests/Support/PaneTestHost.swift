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
        screen.showPanel(
            root: root, minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth, makeScreen: makeScreen
        )
        if settles { settle() }
    }

    /// One whole drag of the divider, released with no velocity, landed.
    func drag(by translationX: CGFloat) {
        let divider = panes.dividerForTesting
        divider.onBegan?()
        divider.onChanged?(translationX)
        divider.onEnded?(translationX, 0)
        settle()
    }

    func settle() {
        panes.finishSettleForTesting()
        window.layoutIfNeeded()
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

/// A bare screen with an attached leaf, the way the chat and the review
/// screens mount one. Its content counts its own layout passes (a reflow of
/// the leaf beside), follows the keyboard as the chat does, and records the
/// visibility its leaf reports.
@MainActor
final class PaneLeafScreen: UIViewController, PaneKeyboardFollowing, PaneVisibilityObserving {
    lazy var leaf = AttachedLeafController(screen: self)
    let field = UITextField()
    var followsKeyboard = true
    private(set) var visibilities: [PaneVisibility] = []
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
