import UIKit

// The workspace shell's stacks. `AppNavigation` is the single source of truth
// for which screens are open: the compact stack (`workspaceStackRouteElements`),
// the split detail column (`splitDetailTarget` and `splitDetailPathElements`),
// and the split selection. The shell controllers (`WorkspaceShellController.swift`)
// read that state in `updateProperties()` and give each stack the routes it
// shows. `ShellNavigationController` turns routes into hosted screens, and
// when the user leaves one (Back, swipe, a screen's own `finish()` or
// `dismiss()`) it reports the pop so `AppNavigation` follows.
//
// Each route's SwiftUI content is `ShellRouteView` (`WorkspaceShellRoutes.swift`).

/// One screen of the workspace shell.
enum ShellRoute: Hashable {
    /// All Sessions: the compact stack's root, or the split detail root with
    /// nothing selected.
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
    case serverSkillBrowser(ServerSkillBrowserNavTarget)
    case serverSkillFile(ServerSkillFileNavTarget)
    case sessionThread(SessionThreadNavTarget)

    /// Bars the router applies. App Settings, the root of its pages, has a
    /// large title.
    var bars: ScreenBars {
        ScreenBars(largeTitle: self == .utility(.appSettings), showsToolbar: true)
    }

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

    /// A compact-stack element. Nil for a value pushed onto `workspacePath`
    /// without its route, which nothing in the app does.
    init?(_ element: WorkspaceStackRouteElement) {
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
        case .serverSkillBrowser(let target): self = .serverSkillBrowser(target)
        case .serverSkillFile(let target): self = .serverSkillFile(target)
        case .sessionThread(let target): self = .sessionThread(target)
        case .unknown: return nil
        }
    }

    /// A screen pushed onto the split detail column.
    init(_ element: WorkspaceSplitDetailPathElement) {
        switch element {
        case .session(let target): self = .session(target)
        case .fileBrowser(let target): self = .fileBrowser(target)
        case .linkedFile(let target): self = .linkedFile(target)
        case .chatReader(let target): self = .chatReader(target)
        case .serverResourceDetail(let target): self = .serverResourceDetail(target)
        case .serverSkillBrowser(let target): self = .serverSkillBrowser(target)
        case .serverSkillFile(let target): self = .serverSkillFile(target)
        case .serverDetails(let target): self = .serverDetails(target)
        case .modelProviders(let target): self = .modelProviders(target)
        case .sessionThread(let target): self = .sessionThread(target)
        }
    }

    /// The split detail column's root: the selected detail, else the selected
    /// workspace's sessions, else All Sessions.
    static func splitDetailRoot(
        target: WorkspaceSplitDetailTarget?,
        selectedWorkspace: WorkspaceNavTarget?
    ) -> Self {
        switch target {
        case .session(let target): .session(target)
        case .fileBrowser(let target): .fileBrowser(target)
        case .linkedFile(let target): .linkedFile(target)
        case .workspaceConfiguration(let target): .workspaceConfiguration(target)
        case .utility(let target): .utility(target)
        case nil: selectedWorkspace.map(Self.workspace) ?? .inbox
        }
    }
}

/// Where a route's screen sits, for the chrome the shell adds to it.
enum ShellRoutePlacement: Equatable {
    /// The compact stack's root, beside the workspace drawer.
    case compactRoot
    /// The split shell's primary column.
    case splitSidebar
    /// The split detail column's root, which carries the sidebar toggle.
    case splitDetailRoot
    /// Pushed onto either stack.
    case pushed
}

/// One UIKit stack of the workspace shell.
///
/// `setRoutes` shows exactly these routes, the first as the root, and keeps
/// every screen whose route stays. A page a hosted screen pushed itself
/// (`ScreenNavigator.push`) stays above it until a route below it changes.
final class ShellNavigationController: UINavigationController, UINavigationControllerDelegate,
    RouterRootClosing {
    private let root: AppRootEnvironment
    private let rootPlacement: ShellRoutePlacement
    /// The user left routed screens; the argument is how many routes, root
    /// included, are still on the stack.
    var onRoutesPopped: ((Int) -> Void)?
    /// What `finish()` on the root screen does. Nil: the root stays.
    var onCloseRoot: (() -> Void)?
    /// Opens the workspace drawer from the compact root.
    var openSidebar: (() -> Void)?

    /// The routes the stack last showed, and the ones it should show.
    private var shownRoutes: [ShellRoute] = []
    private var routes: [ShellRoute] = []
    private var routeByScreen: [ObjectIdentifier: ShellRoute] = [:]

    init(root: AppRootEnvironment, rootPlacement: ShellRoutePlacement) {
        self.root = root
        self.rootPlacement = rootPlacement
        super.init(nibName: nil, bundle: nil)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        view.backgroundColor = root.themeStore.backgroundColor
    }

    func setRoutes(_ routes: [ShellRoute]) {
        precondition(!routes.isEmpty, "A shell stack needs a root route")
        self.routes = routes
        // A transition in flight (a push, the interactive back swipe) ends in
        // `didShow`, which applies the routes then.
        guard transitionCoordinator == nil else { return }
        applyRoutes()
    }

    func closeRoot() {
        onCloseRoot?()
    }

    private var routedScreens: [(route: ShellRoute, screen: UIViewController)] {
        viewControllers.compactMap { screen in
            routeByScreen[ObjectIdentifier(screen)].map { ($0, screen) }
        }
    }

    private func placement(at index: Int) -> ShellRoutePlacement {
        index == 0 ? rootPlacement : .pushed
    }

    private func applyRoutes() {
        let current = routedScreens
        var kept = 0
        while kept < min(current.count, routes.count),
              current[kept].route.screenIdentity == routes[kept].screenIdentity {
            kept += 1
        }
        for index in 0..<kept where current[index].route != routes[index] {
            routeByScreen[ObjectIdentifier(current[index].screen)] = routes[index]
            if let screen = current[index].screen as? HostedScreenController {
                ShellRouteScreens.update(screen, route: routes[index], placement: placement(at: index), openSidebar: openSidebar)
            }
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
        for index in kept..<routes.count {
            let screen = ShellRouteScreens.make(
                routes[index],
                placement: placement(at: index),
                root: root,
                openSidebar: openSidebar
            )
            // A chevron alone, so a pushed screen's title and items keep their room.
            screen.navigationItem.backButtonDisplayMode = .minimal
            routeByScreen[ObjectIdentifier(screen)] = routes[index]
            stack.append(screen)
        }
        forgetScreens(notIn: stack)
        // A new root replaces the column, as selecting another detail does.
        setViewControllers(stack, animated: kept > 0 && viewIfLoaded?.window != nil)
    }

    private func forgetScreens(notIn stack: [UIViewController]) {
        let live = Set(stack.map(ObjectIdentifier.init))
        routeByScreen = routeByScreen.filter { live.contains($0.key) }
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
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
    }
}
