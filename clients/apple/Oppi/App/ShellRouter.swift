import UIKit

// The workspace shell's stacks. `SceneNavigation` is the single source of truth
// for which screens are open: one place and the stack over it
// (`PaneStack`), which the split shell shows from the place and the compact
// stack over All Sessions (`PaneStack.shellRoutes(split:)`).
// The shell controllers (`WorkspaceShellController.swift`) read that state in
// `updateProperties()` and give each stack the routes it shows.
// `ShellNavigationController` turns routes into hosted screens, and
// when the user leaves one (Back, swipe, a screen's own `finish()` or
// `dismiss()`) it reports the pop so `SceneNavigation` follows.
//
// Each route's screen is a UIKit controller built by `ShellRouteScreens` (`ShellRouteScreens.swift`).

/// One screen of the workspace shell.
enum ShellRoute: Hashable {
    /// All Sessions: the compact stack's root, and the split detail column's
    /// when it is the place.
    case inbox
    /// The workspace list in the split shell's primary column.
    case sidebar
    case workspace(WorkspaceNavTarget)
    case session(WorkspaceSessionNavTarget)
    case fileBrowser(FileBrowserNavTarget)
    case linkedFile(WorkspaceLinkedFileNavTarget)
    case chatReader(ChatReaderNavTarget)
    case workspaceConfiguration(WorkspaceNavTarget)
    case utility(WorkspaceUtilityNavTarget)
    case serverDetails(ServerDetailsNavTarget)
    case modelProviders(ModelProvidersNavTarget)
    case serverResourceDetail(ServerResourceDetailNavTarget)
    /// A restored or linked pane entry, shown through its leaf state until
    /// its content can open (`PaneLeafStateViewController`).
    case paneEntry(PaneStackEntry)
    /// A terminal its opener made (`TerminalNavTarget`).
    case terminal(TerminalNavTarget)

    /// The screen a route shows. A workspace route whose workspace was
    /// refreshed is the same screen with newer content.
    fileprivate var screenIdentity: AnyHashable {
        switch self {
        case .workspace(let target):
            AnyHashable(["workspace", target.serverId, target.workspace.id])
        case .workspaceConfiguration(let target):
            AnyHashable(["workspaceConfiguration", target.serverId, target.workspace.id])
        default:
            AnyHashable(self)
        }
    }

    /// A place's screen: All Sessions, a workspace's sessions, a utility.
    init(_ place: NavigationPlace) {
        switch place {
        case .sessions(let workspace): self = workspace.map { .workspace($0) } ?? .inbox
        case .utility(let utility): self = .utility(utility)
        }
    }

    /// A screen of the window's stack.
    init(_ element: WorkspaceStackRouteElement) {
        switch element {
        case .workspace(let target): self = .workspace(target)
        case .session(let target): self = .session(target)
        case .fileBrowser(let target): self = .fileBrowser(target)
        case .linkedFile(let target): self = .linkedFile(target)
        case .chatReader(let target): self = .chatReader(target)
        case .workspaceConfiguration(let target): self = .workspaceConfiguration(target)
        case .utility(let target): self = .utility(target)
        case .serverDetails(let target): self = .serverDetails(target)
        case .modelProviders(let target): self = .modelProviders(target)
        case .serverResourceDetail(let target): self = .serverResourceDetail(target)
        case .paneEntry(let entry): self = .paneEntry(entry)
        case .terminal(let target): self = .terminal(target)
        }
    }

}

/// One UIKit stack of the workspace shell.
///
/// A stack that knows which of its screens a route made, as against a page a screen
/// pushed itself (`Router.push`).
@MainActor
protocol RoutedScreenStack: UINavigationController {
    func isRouted(_ screen: UIViewController) -> Bool
}

/// `setRoutes` shows exactly these routes, the first as the root, and keeps
/// every screen whose route stays. A page a screen pushed itself
/// (`Router.push`) stays above it until a route below it changes.
final class ShellNavigationController: UINavigationController, UINavigationControllerDelegate,
    RoutedScreenStack {
    private let root: AppRootEnvironment
    /// The user left routed screens; the argument is how many routes, root
    /// included, are still on the stack.
    var onRoutesPopped: ((Int) -> Void)?
    /// The sidebar the main pane's sidebar button reaches (`MainPaneSidebarItem`),
    /// set by the layout holding this stack. Nil for the split view's own
    /// sidebar stack, which has no button.
    var sidebar: ShellSidebar? {
        didSet { setNeedsUpdateProperties() }
    }

    /// The routes the stack last showed, and the ones it should show.
    private var shownRoutes: [ShellRoute] = []
    private var routes: [ShellRoute] = []
    private var routeByScreen: [ObjectIdentifier: ShellRoute] = [:]
    /// This stack's own push, pop, or interactive back swipe is in flight; its
    /// `didShow` applies the routes set meanwhile, and nothing else may.
    private var ownTransitionPending = false

    init(root: AppRootEnvironment) {
        self.root = root
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

    /// Shows `routes`, the first as the root.
    func setRoutes(_ routes: [ShellRoute]) {
        precondition(!routes.isEmpty, "A shell stack needs a root route")
        self.routes = routes
        // A push, a pop, or the interactive back swipe of this stack ends in
        // `didShow`, which applies the routes then; leave those to it so a
        // pending pop is not raced.
        guard let transition = transitionCoordinator else {
            applyRoutes()
            return
        }
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

    /// Applies the routes a transition deferred, if they are still owed.
    private func applyPendingRoutes() {
        guard routes != shownRoutes else { return }
        applyRoutes()
    }

    func isRouted(_ screen: UIViewController) -> Bool {
        routeByScreen[ObjectIdentifier(screen)] != nil
    }

    private var routedScreens: [(route: ShellRoute, screen: UIViewController)] {
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
            let screen = ShellRouteScreens.make(routes[index], root: root)
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
        PaneHostController.containing(self)?.mainLeafWillShowScreen()
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
            // The user popped. Their stack wins over routes set meanwhile.
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
