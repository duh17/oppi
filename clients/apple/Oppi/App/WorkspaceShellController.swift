import UIKit

// The workspace shell: what the window shows once the app is paired. UIKit
// owns its structure. `WorkspaceShellController` measures the window and
// mounts one of two layouts, the compact stack with its workspace drawer or
// the split view; the stacks inside follow `SceneNavigation` (`ShellRouter.swift`).
// In both, the session stack is the primary leaf of a `PaneHostController`,
// so a wide window shows a screen's attached leaf beside it; the sidebar is
// never a pane (a tiled sidebar in landscape, a drawer over the panes in
// portrait). The stack and its host are the window's one pane area: a change
// of layout (rotating the iPad mini flips split and stack) moves them, never
// rebuilds them, so the chat, its composer, typed text, a dictation in
// progress and the pane beside it carry on.

/// A layout that shows the window's pane area.
@MainActor
protocol WorkspacePaneLayout: UIViewController {
    /// Takes the pane area in, once the layout's view is in the window.
    func adopt(_ area: WorkspacePaneArea)
    /// Gives the pane area up, for the next layout to adopt.
    func release(_ area: WorkspacePaneArea)
}

/// The window's routed stack and the pane host around it.
@MainActor
struct WorkspacePaneArea {
    let stack: ShellNavigationController
    let host: PaneHostController
}

/// Measures the window, mounts the stack or split layout that shows
/// `SceneNavigation`'s stack, and covers everything while the active server is
/// locked.
final class WorkspaceShellController: UIViewController {
    private let root: AppRootEnvironment
    private var navigation: SceneNavigation { root.navigation }
    private var layout: (any WorkspacePaneLayout)?
    private var layoutPresentation: WorkspaceNavigationPresentation?
    /// Made with the first layout, kept across layouts, dropped under a lock
    /// cover so nothing of a locked server stays mounted.
    private var paneArea: WorkspacePaneArea?
    private var lockCover: UIViewController?
    private var lockedServerId: String?
    /// The last measured presentation. Nil until the first layout pass, so
    /// launch never mounts the wrong layout for a frame.
    private var measuredPresentation: WorkspaceNavigationPresentation?
    private var wasMediaOverlayActive = false
    /// The app's Live Voice call, over every screen but the call's own chat. It pushes the
    /// layout and the lock cover down rather than covering them.
    private let callStrip: LiveVoiceCallStripController

    init(root: AppRootEnvironment) {
        self.root = root
        callStrip = LiveVoiceCallStripController(root: root)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// The lock cover while it covers the layout, else the mounted layout.
    override var childForStatusBarStyle: UIViewController? { lockCover ?? layout }

    /// A pane playing full screen (`ScenePanes.fullScreenCell`) hides the
    /// status bar and the home indicator.
    override var prefersStatusBarHidden: Bool { lockCover == nil && navigation.panes.fullScreenCell != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { prefersStatusBarHidden }
    private var drawnFullScreen = false

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (shell: Self, _: UITraitCollection) in
            shell.view.setNeedsLayout()
        }
        addChild(callStrip)
        view.addSubview(callStrip.view)
        callStrip.didMove(toParent: self)
        callStrip.view.isHidden = true
        callStrip.onContentChange = { [weak self] cameOrWent in
            self?.callStripDidChange(animated: cameOrWent)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // UIKit bounds exclude nothing for the keyboard, so a docked keyboard
        // on a portrait window (Duo inner display, iPad) cannot flip the layout.
        measurePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCallStrip()
    }

    // MARK: Call strip

    /// The strip sits under the status bar, its backdrop behind it; what the shell shows under
    /// it starts below the strip through its safe area, so bars and content move down with it.
    private func layoutCallStrip() {
        let height = callStrip.contentHeight(fitting: view.bounds.width)
        let top = view.safeAreaInsets.top
        callStrip.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height > 0 ? top + height : 0)
        view.bringSubviewToFront(callStrip.view)
        for child in [layout, lockCover].compactMap(\.self) where child.additionalSafeAreaInsets.top != height {
            child.additionalSafeAreaInsets.top = height
        }
    }

    private func callStripDidChange(animated: Bool) {
        view.setNeedsLayout()
        guard animated, view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(springDuration: 0.3, bounce: 0) {
            self.view.layoutIfNeeded()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // AVKit fullscreen freezes the presentation inside SceneNavigation;
        // measure again once it ends.
        let mediaOverlayActive = navigation.isMediaOverlayActive
        if wasMediaOverlayActive, !mediaOverlayActive, measuredPresentation != nil {
            applyPresentation(measured: true)
        }
        wasMediaOverlayActive = mediaOverlayActive
        let fullScreen = navigation.panes.fullScreenCell != nil
        if fullScreen != drawnFullScreen {
            drawnFullScreen = fullScreen
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }

        // A locked active server covers everything under it: lists, sidebar,
        // pushed pages, and settings that follow the active host. The layout
        // is torn down, so nothing from the locked server stays mounted.
        let serverId = root.windowServerId
        let locked = serverId.map { ScopedLockService.shared.isLocked(.server($0)) } ?? false
        if locked, let serverId {
            showLockCover(serverId: serverId)
        } else {
            hideLockCover()
            if measuredPresentation != nil {
                mountLayout(for: navigation.workspaceNavigationPresentation)
            }
        }
    }

    private func measurePresentation() {
        let presentation = WorkspaceNavigationPresentation.resolve(
            horizontalSizeClass: traitCollection.horizontalSizeClass,
            verticalSizeClass: traitCollection.verticalSizeClass,
            size: view.bounds.size
        )
        guard presentation != measuredPresentation else { return }
        measuredPresentation = presentation
        applyPresentation(measured: true)
        // Mount before this layout pass, not a frame later.
        updatePropertiesIfNeeded()
    }

    /// Tells `SceneNavigation` the measured presentation; the matching layout
    /// mounts from it.
    private func applyPresentation(measured: Bool) {
        guard let presentation = measuredPresentation else { return }
        navigation.setWorkspaceNavigationPresentation(
            presentation,
            measurement: WorkspaceNavigationMeasurement(
                horizontalSizeClass: traitCollection.horizontalSizeClass,
                verticalSizeClass: traitCollection.verticalSizeClass,
                windowSize: view.bounds.size
            )
        )
        setNeedsUpdateProperties()
    }

    private func mountLayout(for presentation: WorkspaceNavigationPresentation) {
        guard layout == nil || layoutPresentation != presentation else { return }
        let next: any WorkspacePaneLayout = switch presentation {
        case .stack: WorkspaceDrawerController(root: root)
        case .split: WorkspaceSplitController(root: root)
        }
        replaceLayout(with: next)
        layoutPresentation = presentation
    }

    private func makePaneArea() -> WorkspacePaneArea {
        let stack = ShellNavigationController(root: root)
        let navigation = navigation
        stack.onRoutesPopped = { remaining in
            navigation.popShownStack(toDepth: remaining - 1)
        }
        let host = PaneHostController(primary: stack, panes: navigation.panes)
        navigation.paneArea = host
        return WorkspacePaneArea(stack: stack, host: host)
    }

    /// Shows `next` in place of the current layout. The pane area moves
    /// across in one pass, the old layout giving it up and the new one taking
    /// it, while the host keeps appearance from its screens
    /// (`movesBetweenLayouts`): they are never told they disappeared.
    private func replaceLayout(with next: (any WorkspacePaneLayout)?) {
        let old = layout
        layout = next
        if let next {
            let moving = paneArea
            let area = moving ?? makePaneArea()
            paneArea = area
            addChild(next)
            next.view.frame = view.bounds
            next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(next.view, at: 0)
            next.didMove(toParent: self)
            let adopt = {
                old?.release(area)
                next.adopt(area)
                next.updatePropertiesIfNeeded()
                next.view.layoutIfNeeded()
            }
            // A new area appears as any screen does; one already on screen moves.
            if moving != nil { area.host.movesBetweenLayouts(adopt) } else { adopt() }
        } else {
            paneArea = nil
        }
        if let old {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        view.setNeedsLayout()
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showLockCover(serverId: String) {
        if lockedServerId != serverId {
            lockCover.map(removeChild)
            let cover = ShellRouteScreens.serverLockCover(serverId: serverId, root: root)
            addChild(cover)
            cover.view.frame = view.bounds
            cover.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(cover.view, belowSubview: callStrip.view)
            cover.didMove(toParent: self)
            view.setNeedsLayout()
            lockCover = cover
            lockedServerId = serverId
            setNeedsStatusBarAppearanceUpdate()
        }
        replaceLayout(with: nil)
        layoutPresentation = nil
    }

    private func hideLockCover() {
        guard let lockCover else { return }
        removeChild(lockCover)
        self.lockCover = nil
        lockedServerId = nil
        setNeedsStatusBarAppearanceUpdate()
    }

    private func removeChild(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
}

// MARK: - Split

/// Regular width and height, landscape: the workspace list beside the
/// detail column. `SceneNavigation` picks the detail root and its pushes, and
/// the sidebar's visibility.
final class WorkspaceSplitController: UISplitViewController, UISplitViewControllerDelegate, WorkspacePaneLayout {
    private let root: AppRootEnvironment
    private var navigation: SceneNavigation { root.navigation }
    private let sidebarStack: ShellNavigationController
    /// The window's pane area, in the detail column once adopted.
    private var area: WorkspacePaneArea?
    private var appliedVisibility: SplitColumnVisibility?

    init(root: AppRootEnvironment) {
        self.root = root
        sidebarStack = ShellNavigationController(root: root)
        super.init(style: .doubleColumn)
        delegate = self
        preferredSplitBehavior = .tile
        // The main pane carries its own button (`MainPaneSidebarItem`): the
        // detail column is the pane host, whose bar is hidden.
        displayModeButtonVisibility = .never
        minimumPrimaryColumnWidth = 320
        preferredPrimaryColumnWidth = 380
        maximumPrimaryColumnWidth = 460
        // The sidebar column is never routed: one screen, no route.
        sidebarStack.setViewControllers([WorkspaceSidebarViewController(root: root)], animated: false)
        setViewController(sidebarStack, for: .primary)
    }

    func adopt(_ area: WorkspacePaneArea) {
        self.area = area
        let navigation = navigation
        area.stack.sidebar = ShellSidebar(
            identifier: "workspace.split.sidebarToggle",
            isShown: { navigation.splitColumnVisibility != .detailOnly },
            toggle: { navigation.toggleSplitSidebar() }
        )
        // As the drawer last drew it, maybe mid-slide.
        area.host.view.isUserInteractionEnabled = true
        area.host.view.layer.cornerRadius = 0
        // UIKit wraps a column's controller that is not a navigation
        // controller in one; its bar stays hidden (`PaneHostController`
        // hides the bar of a stack it is the root of).
        setViewController(area.host, for: .secondary)
        setNeedsUpdateProperties()
    }

    func release(_ area: WorkspacePaneArea) {
        // Through the split: the column's wrapper otherwise keeps the host on
        // its stack, and UIKit refuses it to another parent.
        setViewController(UIViewController(), for: .secondary)
        self.area = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// The detail column chooses the status bar only while it is the whole
    /// screen; with the sidebar showing, the bar sits over the app's own list.
    override var childForStatusBarStyle: UIViewController? {
        shownDisplayMode == .secondaryOnly ? area?.host : nil
    }

    /// The columns showing, as of the last change UIKit reported.
    private var shownDisplayMode = UISplitViewController.DisplayMode.automatic

    private func columnsShown(_ mode: UISplitViewController.DisplayMode) {
        guard mode != shownDisplayMode else { return }
        shownDisplayMode = mode
        setNeedsStatusBarAppearanceUpdate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        columnsShown(displayMode)
    }

    override func updateProperties() {
        super.updateProperties()
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        view.backgroundColor = root.themeStore.backgroundColor
        // A pane playing full screen takes the sidebar's room too; the
        // sidebar comes back as the person left it.
        // The columns move before the detail column's screens change. A
        // screen pushed first would start its push in the old column and
        // keep that frame while the columns move, leaving the sidebar's room
        // empty; a new root laid out inside the columns' animation would
        // grow out of a corner with them.
        applyColumnVisibility(navigation.panes.fullScreenCell != nil ? .detailOnly : navigation.splitColumnVisibility)
        area?.stack.setRoutes(navigation.mainPaneRoute.routes(split: true))
    }

    private func applyColumnVisibility(_ visibility: SplitColumnVisibility) {
        guard visibility != appliedVisibility else { return }
        let animated = appliedVisibility != nil && viewIfLoaded?.window != nil
        appliedVisibility = visibility
        let mode: UISplitViewController.DisplayMode = switch visibility {
        case .automatic: .automatic
        case .all: .oneBesideSecondary
        case .detailOnly: .secondaryOnly
        }
        guard preferredDisplayMode != mode else { return }
        if animated {
            // Only the columns move: what was already pending takes its
            // frames first, and the columns reach theirs inside the animation.
            view.layoutIfNeeded()
            UIView.animate(withDuration: 0.3) {
                self.preferredDisplayMode = mode
                self.view.layoutIfNeeded()
            }
        } else {
            preferredDisplayMode = mode
        }
    }

    // The system's sidebar gestures change the columns too.
    func splitViewController(
        _ svc: UISplitViewController,
        willChangeTo displayMode: UISplitViewController.DisplayMode
    ) {
        columnsShown(displayMode)
        let visibility: SplitColumnVisibility = displayMode == .secondaryOnly ? .detailOnly : .all
        guard visibility != appliedVisibility, visibility != navigation.splitColumnVisibility else { return }
        appliedVisibility = visibility
        navigation.splitColumnVisibility = visibility
    }
}

// MARK: - Compact stack and workspace drawer

/// The compact layout: the session stack slides right to reveal the
/// workspace list beneath it, tracks the drag 1:1, and settles with a spring.
/// The navigation bar, search, and bottom toolbar live in the sliding stack,
/// so they travel with the list as one surface. The reveal drag starts within
/// `edgePanWidth` of the leading edge, only at the stack's root, so it never
/// fights the interactive back swipe.
final class WorkspaceDrawerController: UIViewController, UIGestureRecognizerDelegate, WorkspacePaneLayout {
    private static let edgePanWidth: CGFloat = 32
    private static let foregroundCornerRadius: CGFloat = 40
    private static let foregroundShadowOpacity: Float = 0.14
    private static let foregroundShadowRadius: CGFloat = 22
    private static let foregroundShadowOffsetX: CGFloat = -5

    private let root: AppRootEnvironment
    private var navigation: SceneNavigation { root.navigation }
    /// The window's pane area, once adopted: in a wide portrait window a
    /// screen's attached leaf sits beside the stack, and the drawer slides
    /// over both.
    private var area: WorkspacePaneArea?
    private var stack: ShellNavigationController? { area?.stack }
    private let sidebar: UIViewController
    /// Carries the shadow; the pane host's view inside it carries the rounded mask.
    private let foreground = UIView()
    private let scrim = UIView()
    private let revealPan = UIPanGestureRecognizer()
    private let scrimPan = UIPanGestureRecognizer()
    private let scrimTap = UITapGestureRecognizer()

    private var isOpen = false
    /// Settled position, 0 closed to 1 open; a drag adds to it.
    private var restingProgress: CGFloat = 0
    private var dragProgress: CGFloat = 0

    init(root: AppRootEnvironment) {
        self.root = root
        let closeSidebar = DrawerAction()
        sidebar = ShellRouteScreens.drawerSidebar(root: root) { closeSidebar.perform?() }
        super.init(nibName: nil, bundle: nil)
        closeSidebar.perform = { [weak self] in self?.settle(open: false) }
    }

    func adopt(_ area: WorkspacePaneArea) {
        self.area = area
        // The drawer covers the button while it is open.
        area.stack.sidebar = ShellSidebar(
            identifier: "workspace.sidebar.open",
            isShown: { false },
            toggle: { [weak self] in self?.settle(open: true) }
        )
        let host = area.host
        addChild(host)
        foreground.addSubview(host.view)
        host.view.layer.cornerCurve = .continuous
        host.view.clipsToBounds = true
        host.didMove(toParent: self)
        view.setNeedsLayout()
        setNeedsUpdateProperties()
        setNeedsStatusBarAppearanceUpdate()
    }

    func release(_ area: WorkspacePaneArea) {
        let host = area.host
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        area.stack.sidebar = nil
        self.area = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// The session stack in front of the drawer; the sidebar owns the status
    /// bar while the drawer is open over it.
    override var childForStatusBarStyle: UIViewController? { isOpen ? nil : area?.host }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(sidebar)
        view.addSubview(sidebar.view)
        sidebar.didMove(toParent: self)
        sidebar.view.accessibilityElementsHidden = true
        sidebar.view.isUserInteractionEnabled = false
        sidebar.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Close workspaces")) { [weak self] _ in
                self?.settle(open: false)
                return true
            },
        ]

        view.addSubview(foreground)
        foreground.layer.shadowColor = UIColor.black.cgColor
        foreground.layer.shadowOpacity = 0

        scrim.backgroundColor = .clear
        scrim.isHidden = true
        scrim.accessibilityIdentifier = "workspace.sidebar.scrim"
        scrim.accessibilityElementsHidden = true
        view.addSubview(scrim)

        revealPan.addTarget(self, action: #selector(handleReveal(_:)))
        revealPan.delegate = self
        foreground.addGestureRecognizer(revealPan)
        scrimPan.addTarget(self, action: #selector(handleScrimPan(_:)))
        scrimPan.delegate = self
        scrim.addGestureRecognizer(scrimPan)
        scrimTap.addTarget(self, action: #selector(handleScrimTap))
        scrim.addGestureRecognizer(scrimTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDrawer()
    }

    override func updateProperties() {
        super.updateProperties()
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        // The corner cutouts the rounded foreground reveals show the theme,
        // never the bare window.
        view.backgroundColor = root.themeStore.backgroundColor
        stack?.setRoutes(navigation.mainPaneRoute.routes(split: false))
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isOpen else { return false }
        settle(open: false)
        return true
    }

    private var sidebarWidth: CGFloat {
        min(view.bounds.width * 0.8, 320)
    }

    private var progress: CGFloat {
        min(1, max(0, restingProgress + dragProgress))
    }

    private func layoutDrawer() {
        let bounds = view.bounds
        let width = sidebarWidth
        sidebar.view.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        let progress = progress
        let offset = width * progress
        foreground.frame = bounds.offsetBy(dx: offset, dy: 0)
        let host = area?.host.view
        host?.frame = foreground.bounds
        host?.layer.cornerRadius = Self.foregroundCornerRadius * progress
        foreground.layer.shadowOpacity = Self.foregroundShadowOpacity * Float(progress)
        foreground.layer.shadowRadius = Self.foregroundShadowRadius * progress
        foreground.layer.shadowOffset = CGSize(width: Self.foregroundShadowOffsetX * progress, height: 0)
        foreground.layer.shadowPath = UIBezierPath(
            roundedRect: foreground.bounds,
            cornerRadius: Self.foregroundCornerRadius * progress
        ).cgPath
        scrim.frame = foreground.frame
        // Only while the sidebar intercepts (open or mid-drag), so it never
        // steals taps from the session surface.
        scrim.isHidden = !(isOpen || progress > 0)
        // No list scroll or indicator on the peeking sliver.
        host?.isUserInteractionEnabled = progress == 0
    }

    /// The drawer opens wherever the sidebar button shows (every screen on a
    /// wide window, the root on a compact one) and closes from anywhere. Toggle
    /// Sidebar's availability and action. The edge drag stays at the root,
    /// clear of the back swipe.
    var canToggleSidebar: Bool { isOpen || stack?.showsSidebarButtonOnTop == true }
    var isSidebarOpen: Bool { isOpen }

    func toggleSidebar() {
        settle(open: !isOpen)
    }

    func closeSidebar() {
        guard isOpen else { return }
        settle(open: false)
    }

    private func settle(open: Bool) {
        // One light tap when the drawer lands open: edge swipe and the
        // toolbar button both settle here.
        if open, !isOpen {
            AppHaptics.impact(style: .light, intensity: 0.65)
        }
        isOpen = open
        setNeedsStatusBarAppearanceUpdate()
        sidebar.view.isUserInteractionEnabled = open
        sidebar.view.accessibilityElementsHidden = !open
        sidebar.view.accessibilityViewIsModal = open
        foreground.accessibilityElementsHidden = open
        restingProgress = open ? 1 : 0
        dragProgress = 0
        let animations = { self.layoutDrawer() }
        if UIAccessibility.isReduceMotionEnabled || view.window == nil {
            animations()
        } else {
            UIView.animate(springDuration: 0.28, bounce: 0.06, animations: animations)
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func track(_ pan: UIPanGestureRecognizer) {
        let width = sidebarWidth
        switch pan.state {
        case .changed:
            dragProgress = pan.translation(in: view).x / width
            layoutDrawer()
        case .ended:
            let projected = restingProgress + pan.translationProjected(in: view).x / width
            settle(open: projected >= 0.5)
        case .cancelled, .failed:
            settle(open: isOpen)
        default:
            break
        }
    }

    @objc private func handleReveal(_ pan: UIPanGestureRecognizer) {
        track(pan)
    }

    @objc private func handleScrimPan(_ pan: UIPanGestureRecognizer) {
        track(pan)
    }

    @objc private func handleScrimTap() {
        settle(open: false)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === revealPan else { return true }
        // Armed at the stack root only, from the leading edge.
        return !isOpen
            && stack?.viewControllers.count == 1
            && touch.location(in: foreground).x <= Self.edgePanWidth
    }

    /// Horizontal drags only: a vertical one never moves the drawer.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === revealPan || gestureRecognizer === scrimPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) >= abs(velocity.y)
    }

    // The list waits for an edge drag to decide; other touches never reach it.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === revealPan && otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// The sidebar's selection closes the drawer that hosts it; the drawer
/// exists only after the sidebar does.
@MainActor
private final class DrawerAction {
    var perform: (() -> Void)?
}

private extension UIPanGestureRecognizer {
    /// Where the drag would come to rest, like SwiftUI's `predictedEndTranslation`.
    func translationProjected(in view: UIView) -> CGPoint {
        let translation = translation(in: view)
        let velocity = velocity(in: view)
        // UIScrollView's normal deceleration.
        let decelerationRate = UIScrollView.DecelerationRate.normal.rawValue
        let factor = decelerationRate / (1 - decelerationRate) / 1000
        return CGPoint(x: translation.x + velocity.x * factor, y: translation.y + velocity.y * factor)
    }
}
