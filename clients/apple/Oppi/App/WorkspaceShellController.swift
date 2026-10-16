import UIKit

// The workspace shell: what the window shows once the app is paired. UIKit
// owns its structure. `WorkspaceShellController` measures the window and
// mounts one of two layouts, the compact stack with its workspace drawer or
// the split view; the stacks inside follow `AppNavigation` (`ShellRouter.swift`).

/// Measures the window, mounts the stack or split layout `AppNavigation`
/// converted its routes for, and covers everything while the active server
/// is locked.
final class WorkspaceShellController: UIViewController {
    private let root: AppRootEnvironment
    private var navigation: AppNavigation { root.navigation }
    private var layout: UIViewController?
    private var layoutPresentation: WorkspaceNavigationPresentation?
    private var lockCover: UIViewController?
    private var lockedServerId: String?
    /// The last measured presentation. Nil until the first layout pass, so
    /// launch never mounts the wrong layout for a frame.
    private var measuredPresentation: WorkspaceNavigationPresentation?
    private var wasMediaOverlayActive = false

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (shell: Self, _: UITraitCollection) in
            shell.view.setNeedsLayout()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // UIKit bounds exclude nothing for the keyboard, so a docked keyboard
        // on a portrait window (Duo inner display, iPad) cannot flip the layout.
        measurePresentation()
    }

    override func updateProperties() {
        super.updateProperties()
        // AVKit fullscreen freezes the presentation inside AppNavigation;
        // measure again once it ends.
        let mediaOverlayActive = navigation.isMediaOverlayActive
        if wasMediaOverlayActive, !mediaOverlayActive, measuredPresentation != nil {
            applyPresentation(measured: true)
        }
        wasMediaOverlayActive = mediaOverlayActive

        // A locked active server covers everything under it: lists, sidebar,
        // pushed pages, and settings that follow the active host. The layout
        // is torn down, so nothing from the locked server stays mounted.
        let serverId = root.coordinator.activeServerId
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

    /// Converts `AppNavigation`'s routes for the measured presentation in one
    /// mutation; the matching layout mounts from the converted state.
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
        navigation.routeLegacySelectedTabIfNeeded()
        setNeedsUpdateProperties()
    }

    private func mountLayout(for presentation: WorkspaceNavigationPresentation) {
        guard layout == nil || layoutPresentation != presentation else { return }
        let next: UIViewController = switch presentation {
        case .stack: WorkspaceDrawerController(root: root)
        case .split: WorkspaceSplitController(root: root)
        }
        replaceLayout(with: next)
        layoutPresentation = presentation
    }

    private func replaceLayout(with next: UIViewController?) {
        if let layout {
            layout.willMove(toParent: nil)
            layout.view.removeFromSuperview()
            layout.removeFromParent()
        }
        layout = next
        guard let next else { return }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(next.view, at: 0)
        next.didMove(toParent: self)
    }

    private func showLockCover(serverId: String) {
        if lockedServerId != serverId {
            lockCover.map(removeChild)
            let cover = ShellRouteScreens.serverLockCover(serverId: serverId, root: root)
            addChild(cover)
            cover.view.frame = view.bounds
            cover.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(cover.view)
            cover.didMove(toParent: self)
            lockCover = cover
            lockedServerId = serverId
        }
        replaceLayout(with: nil)
        layoutPresentation = nil
    }

    private func hideLockCover() {
        guard let lockCover else { return }
        removeChild(lockCover)
        self.lockCover = nil
        lockedServerId = nil
    }

    private func removeChild(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
}

// MARK: - Split

/// Regular width and height, landscape: the workspace list beside the
/// detail column. `AppNavigation` picks the detail root and its pushes, and
/// the sidebar's visibility.
final class WorkspaceSplitController: UISplitViewController, UISplitViewControllerDelegate {
    private let root: AppRootEnvironment
    private var navigation: AppNavigation { root.navigation }
    private let sidebarStack: ShellNavigationController
    private let detailStack: ShellNavigationController
    private var appliedVisibility: SplitColumnVisibility?

    init(root: AppRootEnvironment) {
        self.root = root
        sidebarStack = ShellNavigationController(root: root, rootPlacement: .splitSidebar)
        detailStack = ShellNavigationController(root: root, rootPlacement: .splitDetailRoot)
        super.init(style: .doubleColumn)
        delegate = self
        preferredSplitBehavior = .tile
        // The detail root carries its own toggle (`workspace.split.sidebarToggle`).
        displayModeButtonVisibility = .never
        minimumPrimaryColumnWidth = 320
        preferredPrimaryColumnWidth = 380
        maximumPrimaryColumnWidth = 460
        sidebarStack.setRoutes([.sidebar])
        let navigation = root.navigation
        detailStack.onRoutesPopped = { remaining in
            navigation.popSplitDetail(toDepth: remaining - 1)
        }
        detailStack.onCloseRoot = {
            navigation.showSessionInboxInSplit()
        }
        setViewController(sidebarStack, for: .primary)
        setViewController(detailStack, for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func updateProperties() {
        super.updateProperties()
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        view.backgroundColor = root.themeStore.backgroundColor
        detailStack.setRoutes(
            [ShellRoute.splitDetailRoot(
                target: navigation.splitDetailTarget,
                selectedWorkspace: navigation.splitSelectedWorkspace
            )] + navigation.splitDetailPathElements.map(ShellRoute.init)
        )
        applyColumnVisibility(navigation.splitColumnVisibility)
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
            UIView.animate(withDuration: 0.3) { self.preferredDisplayMode = mode }
        } else {
            preferredDisplayMode = mode
        }
    }

    // The system's sidebar gestures change the columns too.
    func splitViewController(
        _ svc: UISplitViewController,
        willChangeTo displayMode: UISplitViewController.DisplayMode
    ) {
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
final class WorkspaceDrawerController: UIViewController, UIGestureRecognizerDelegate {
    private static let edgePanWidth: CGFloat = 32
    private static let foregroundCornerRadius: CGFloat = 40
    private static let foregroundShadowOpacity: Float = 0.14
    private static let foregroundShadowRadius: CGFloat = 22
    private static let foregroundShadowOffsetX: CGFloat = -5

    private let root: AppRootEnvironment
    private var navigation: AppNavigation { root.navigation }
    private let stack: ShellNavigationController
    private let sidebar: UIViewController
    /// Carries the shadow; `stack.view` inside it carries the rounded mask.
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
        stack = ShellNavigationController(root: root, rootPlacement: .compactRoot)
        let closeSidebar = DrawerAction()
        sidebar = ShellRouteScreens.drawerSidebar(root: root) { closeSidebar.perform?() }
        super.init(nibName: nil, bundle: nil)
        closeSidebar.perform = { [weak self] in self?.settle(open: false) }
        let navigation = root.navigation
        stack.onRoutesPopped = { remaining in
            navigation.popWorkspaceStack(toDepth: remaining - 1)
        }
        stack.openSidebar = { [weak self] in self?.settle(open: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

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
        addChild(stack)
        foreground.addSubview(stack.view)
        stack.view.layer.cornerCurve = .continuous
        stack.view.clipsToBounds = true
        stack.didMove(toParent: self)
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
        stack.setRoutes([.inbox] + navigation.workspaceStackRouteElements.compactMap { element in
            let route = ShellRoute(element)
            assert(route != nil, "A workspace path value was pushed without its route")
            return route
        })
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
        stack.view.frame = foreground.bounds
        stack.view.layer.cornerRadius = Self.foregroundCornerRadius * progress
        foreground.layer.shadowOpacity = Self.foregroundShadowOpacity * Float(progress)
        foreground.layer.shadowRadius = Self.foregroundShadowRadius * progress
        foreground.layer.shadowOffset = CGSize(width: Self.foregroundShadowOffsetX * progress, height: 0)
        foreground.layer.shadowPath = UIBezierPath(
            roundedRect: foreground.bounds,
            cornerRadius: stack.view.layer.cornerRadius
        ).cgPath
        scrim.frame = foreground.frame
        // Only while the sidebar intercepts (open or mid-drag), so it never
        // steals taps from the session surface.
        scrim.isHidden = !(isOpen || progress > 0)
        // No list scroll or indicator on the peeking sliver.
        stack.view.isUserInteractionEnabled = progress == 0
    }

    private func settle(open: Bool) {
        // One light tap when the drawer lands open: edge swipe and the
        // toolbar button both settle here.
        if open, !isOpen {
            AppHaptics.impact(style: .light, intensity: 0.65)
        }
        isOpen = open
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
            && stack.viewControllers.count == 1
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
