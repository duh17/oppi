import UIKit

// The workspace shell's stacks. `SceneNavigation` is the single source of truth
// for which screens are open: one place and the stack over it (`PaneStack`)
// for the main leaf, and the screens over its content for a side leaf, which
// the shell shows from the place and the compact stack over All Sessions
// (`PaneStack.routes(split:)`).
// The shell controllers (`WorkspaceShellController.swift`) read the main leaf's
// state in `updateProperties()` and give its stack the routes it shows; the
// pane host does the same for each side leaf (`PaneHostController+Tree`).
// `ShellNavigationController` turns routes into hosted screens, and
// when the user leaves one (Back, swipe, a screen's own `finish()` or
// `dismiss()`) it reports the pop so the leaf's route follows.
//
// Each route's screen is a UIKit controller built by `ShellRouteScreens` (`ShellRouteScreens.swift`).

/// One UIKit stack of a leaf's route.
///
/// A stack that knows which of its screens a route made, as against a page a screen
/// pushed itself (`Router.push`).
@MainActor
protocol RoutedScreenStack: UINavigationController {
    /// The leaf whose route this stack draws; nil for the window's own stacks
    /// (the main pane, the split detail, the sidebar).
    var leaf: PaneID? { get }
    func isRouted(_ screen: UIViewController) -> Bool
}

extension WorkspaceStackRouteElement {
    /// The screen a route shows. A workspace route whose workspace was
    /// refreshed is the same screen with newer content.
    var screenIdentity: AnyHashable {
        switch self {
        case .workspace(let target):
            AnyHashable(["workspace", target.serverId, target.workspace.id])
        case .workspaceConfiguration(let target):
            AnyHashable(["workspaceConfiguration", target.serverId, target.workspace.id])
        case .entry(let entry):
            AnyHashable(["entry", entry.screenIdentity])
        default:
            AnyHashable(self)
        }
    }
}

extension PaneStackEntry {
    /// Which screen an `.entry` route shows. A web page keeps its screen for
    /// every address it loads, so a link that loads in place does not rebuild
    /// it; anything else is its own screen.
    var screenIdentity: AnyHashable {
        switch route {
        case .browser: AnyHashable(["webPage", serverId])
        case .local(let token) where PaneLocalScreen(token) == .browser: AnyHashable(["webPage", serverId])
        default: AnyHashable(self)
        }
    }
}

/// `setRoutes` shows exactly these routes, the first as the root, and keeps
/// every screen whose route stays. A page a screen pushed itself
/// (`Router.push`) stays above it until a route below it changes.
final class ShellNavigationController: UINavigationController, UINavigationControllerDelegate,
    RoutedScreenStack {
    private let root: AppRootEnvironment
    let leaf: PaneID?
    /// The user left routed screens; the argument is how many routes, root
    /// included, are still on the stack.
    var onRoutesPopped: ((Int) -> Void)?
    /// A side leaf's root screen closed (Close Pane, a terminal's Back).
    var onCloseRoot: (() -> Void)?

    func closeRoot() {
        guard let onCloseRoot else {
            assertionFailure("Router.finish on the root of a stack that cannot close it")
            return
        }
        onCloseRoot()
    }
    /// What a side leaf's own screens report into its route; nil for the
    /// window's own stacks, whose screens are the shell's.
    var sideActions: PaneSplitScreens.Actions?
    /// The sidebar the main pane's sidebar button reaches (`MainPaneSidebarItem`),
    /// set by the layout holding this stack. Nil for the split view's own
    /// sidebar stack, which has no button.
    var sidebar: ShellSidebar? {
        didSet { setNeedsUpdateProperties() }
    }

    /// The routes the stack last showed, and the ones it should show.
    private var shownRoutes: [WorkspaceStackRouteElement] = []
    private var routes: [WorkspaceStackRouteElement] = []
    private var routeByScreen: [ObjectIdentifier: WorkspaceStackRouteElement] = [:]
    /// This stack's own push, pop, or interactive back swipe is in flight; its
    /// `didShow` applies the routes set meanwhile, and nothing else may.
    private var ownTransitionPending = false

    init(root: AppRootEnvironment, leaf: PaneID? = nil) {
        self.root = root
        self.leaf = leaf
        super.init(nibName: nil, bundle: nil)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    /// The screen in front chooses the status bar, as in a stack with no bar.
    override var childForStatusBarStyle: UIViewController? { topViewController }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The window's width decides how deep the sidebar button goes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (stack: Self, _: UITraitCollection) in
            stack.setNeedsUpdateProperties()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        view.backgroundColor = root.themeStore.backgroundColor
        for (index, screen) in viewControllers.enumerated() {
            applySidebarButton(to: screen, at: index)
        }
    }

    // MARK: Sidebar button

    /// Whether the screen at `index` shows the sidebar button: every screen in
    /// a wide window, the root alone in a compact one. It follows the window,
    /// not a trait a pane overrides.
    private func showsSidebarButton(at index: Int) -> Bool {
        sidebar != nil && (index == 0 || AdaptiveWidth.isWide(view.window?.traitCollection ?? traitCollection))
    }

    /// Whether the screen in front shows the sidebar button: ⌃⌘S works where it does.
    var showsSidebarButtonOnTop: Bool {
        showsSidebarButton(at: viewControllers.count - 1)
    }

    private func applySidebarButton(to screen: UIViewController, at index: Int) {
        let navigationItem = screen.navigationItem
        guard let sidebar, showsSidebarButton(at: index) else {
            guard navigationItem.mainPaneSidebarItem != nil else { return }
            navigationItem.setMainPaneSidebarItem(nil)
            screen.setNeedsUpdatePropertiesInTree()
            return
        }
        let existing = navigationItem.mainPaneSidebarItem
        let item = existing ?? MainPaneSidebarItem { [weak self] in self?.sidebar?.toggle() }
        let palette = root.themeStore.activeThemeID.palette
        let tint = SystemVerticalBar.traitIsActive(traitCollection) ? SessionListBarItems.railTint(palette) : palette.ui.fg
        let changed = item.apply(sidebar, tint: tint)
        navigationItem.setMainPaneSidebarItem(item)
        if existing == nil || changed {
            screen.setNeedsUpdatePropertiesInTree()
        }
    }

    /// A stack is handed its screens before it is on screen: the split builds
    /// its sidebar column with the sidebar in `init`, and a pane leaf is built
    /// with its routes. The bar those screens ask for is decided now. Left to
    /// the delegate's `willShow`, it waits for the appearance UIKit sends the
    /// stack, which is a turn away at best: until it comes, the column reserves
    /// the bar its screen says it never draws.
    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        super.setViewControllers(viewControllers, animated: animated)
        // A stack on screen keeps its own transitions: its delegate applies the
        // bar as each screen comes forward and the animation carries it.
        guard viewIfLoaded?.window == nil, let top = topViewController else { return }
        applyNavigationBar(forIncoming: top, animated: false)
    }

    /// Shows `routes`, the first as the root.
    func setRoutes(_ routes: [WorkspaceStackRouteElement]) {
        precondition(!routes.isEmpty, "A shell stack needs a root route")
        self.routes = routes
        // A push, a pop, or the interactive back swipe of this stack ends in
        // `didShow`, which applies the routes then; leave those to it so a
        // pending pop is not raced.
        guard let transition = transitionCoordinator else {
            applyRoutes()
            return
        }
        // The routes are kept for `didShow`, which decides whether the person
        // popped or the leaf moved on.
        guard !ownTransitionPending else { return }
        // A transition that is not this stack's own — a window-covering modal
        // closing over it, whose dismissal never reports a `didShow` here —
        // would strand the routes, so apply when it ends. A coordinator that
        // cannot queue the completion returns false; apply now instead.
        if !transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            self?.applyPendingRoutes()
        }) {
            applyRoutes()
        }
    }

    /// Shows `routes` now, even while a transition runs: a route the app
    /// replaced as a whole (a pane moving up a folder) is not the person's push
    /// or pop, so it does not wait for a transition to report.
    func replaceRoutes(_ routes: [WorkspaceStackRouteElement]) {
        precondition(!routes.isEmpty, "A shell stack needs a root route")
        self.routes = routes
        ownTransitionPending = false
        applyRoutes()
    }

    /// Applies the routes a transition deferred, if they are still owed.
    private func applyPendingRoutes() {
        guard routes != shownRoutes else { return }
        applyRoutes()
    }

    func isRouted(_ screen: UIViewController) -> Bool {
        routeByScreen[ObjectIdentifier(screen)] != nil
    }

    private var routedScreens: [(route: WorkspaceStackRouteElement, screen: UIViewController)] {
        viewControllers.compactMap { screen in
            routeByScreen[ObjectIdentifier(screen)].map { ($0, screen) }
        }
    }

    private func applyRoutes() {
        let current = routedScreens
        var kept = 0
        while kept < min(current.count, routes.count),
              current[kept].route.screenIdentity == routes[kept].screenIdentity {
            kept += 1
        }
        for index in 0..<kept where current[index].route != routes[index] {
            reuse(current[index].screen, as: index)
        }
        shownRoutes = routes
        guard kept < current.count || kept < routes.count else { return }

        var stack: [UIViewController]
        if kept == current.count {
            // Only additions: pages a screen pushed itself stay below them.
            stack = viewControllers
        } else if kept > 0, let anchor = viewControllers.firstIndex(of: current[kept - 1].screen) {
            stack = Array(viewControllers[...anchor])
        } else {
            stack = []
        }
        // A screen whose route moved within the stack is the same screen, so
        // the chat, its composer, typed text and dictation carry on. A rotation
        // moves it: the compact stack keeps All Sessions under a place and the
        // split detail column starts at the place. A route removed below it (a
        // removed session's chat) moves it too. The pages it pushed itself come
        // along when it stays on top, or when the route it pushed them under
        // moves with it (a host's form under the terminal it opened).
        var movable: [AnyHashable: (screen: UIViewController, pages: [UIViewController], next: AnyHashable?)] = [:]
        for (offset, entry) in current.enumerated().dropFirst(kept) {
            guard movable[entry.route.screenIdentity] == nil,
                  let start = viewControllers.firstIndex(of: entry.screen) else { continue }
            let next = current.dropFirst(offset + 1).first
            let end = next.flatMap { viewControllers.firstIndex(of: $0.screen) } ?? viewControllers.endIndex
            movable[entry.route.screenIdentity] = (entry.screen, Array(viewControllers[(start + 1)..<end]), next?.route.screenIdentity)
        }
        for index in kept..<routes.count {
            if let moved = movable.removeValue(forKey: routes[index].screenIdentity) {
                reuse(moved.screen, as: index)
                stack.append(moved.screen)
                let isTop = index == routes.count - 1
                if isTop || (moved.next != nil && moved.next == routes[index + 1].screenIdentity) {
                    stack.append(contentsOf: moved.pages)
                }
                continue
            }
            let screen = ShellRouteScreens.make(routes[index], root: root, side: sideActions)
            // A chevron alone, so a pushed screen's title and items keep their room.
            screen.navigationItem.backButtonDisplayMode = .minimal
            routeByScreen[ObjectIdentifier(screen)] = routes[index]
            stack.append(screen)
        }
        forgetScreens(notIn: stack)
        guard stack != viewControllers else { return }
        // A new root (another place, or the other shell's) replaces the
        // stack at once; screens over a kept root push and pop.
        setViewControllers(stack, animated: kept > 0 && viewIfLoaded?.window != nil)
    }

    /// Gives a kept screen the route it has now.
    private func reuse(_ screen: UIViewController, as index: Int) {
        routeByScreen[ObjectIdentifier(screen)] = routes[index]
        ShellRouteScreens.update(screen, route: routes[index])
        screen.navigationItem.backButtonDisplayMode = .minimal
    }

    private func forgetScreens(notIn stack: [UIViewController]) {
        let live = Set(stack.map(ObjectIdentifier.init))
        routeByScreen = routeByScreen.filter { live.contains($0.key) }
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        // A skill or workspace file reader hid the bar, and the screen it
        // popped back to lost its Back button.
        //
        // This stack's own push, pop, or interactive back swipe starts here;
        // its `didShow` applies the routes set meanwhile, and nothing else may.
        // `didShow` reports only a screen that was *displayed*, so a cancelled
        // back swipe never sends it: the transition's own completion ends the
        // window whether it completes or cancels, and the flag is set only when
        // that completion is queued. With no coordinator there is no transition
        // to defer to, and `setRoutes` applies at once.
        if let transition = navigationController.transitionCoordinator {
            ownTransitionPending = true
            // A coordinator that cannot queue the completion has already ended
            // its transition, so the window is over and the flag must not stay.
            if !transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                self?.ownTransitionPending = false
            }) {
                ownTransitionPending = false
            }
        }
        applyNavigationBar(forIncoming: viewController, animated: animated)
        // In the bar the screen comes in with, not a pass later.
        applySidebarButton(to: viewController, at: viewControllers.firstIndex(of: viewController) ?? viewControllers.count)
        // The main leaf comes back into sight only for its own screens: a page
        // opening in a side pane leaves the window's focus where the person put it.
        if leaf == nil {
            PaneHostController.containing(self)?.mainLeafWillShowScreen()
        } else {
            PaneHostController.containing(self)?.leafWillShowScreen()
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        ownTransitionPending = false
        let remaining = routedScreens.map(\.route)
        forgetScreens(notIn: viewControllers)
        if remaining.count < shownRoutes.count, Array(shownRoutes.prefix(remaining.count)) == remaining {
            // Routes the leaf was given during the transition that differ from
            // what the stack showed are newer than the pop (a breadcrumb, a key
            // right after Back, a link): the stack shows them, and nothing was
            // popped. Routes it was given that are what it already showed are
            // the shell's own update ticks, and the pop stands.
            let identities = routes.map(\.screenIdentity)
            if identities != shownRoutes.map(\.screenIdentity) {
                shownRoutes = remaining
                applyRoutes()
                return
            }
            // The user popped. Their stack wins over what it showed.
            shownRoutes = remaining
            routes = remaining
            onRoutesPopped?(remaining.count)
        }
        if routes != shownRoutes {
            applyRoutes()
        }
        PaneHostController.containing(self)?.leafDidShowScreen()
    }
}
