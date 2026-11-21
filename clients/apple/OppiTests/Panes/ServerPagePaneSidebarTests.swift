import Testing
import UIKit
@testable import Oppi

/// A server page (Server Metrics, Usage, Server Settings) picked from the
/// server switcher in the landscape split shell. Beside another pane it is
/// that pane's content: switching pages swaps it in place and the window's
/// sidebar stays hidden. With no other pane the page keeps its sidebar.
///
/// The main pane's sidebar button (`MainPaneSidebarItem`): on every screen of
/// the window's routed stack in a wide window, at its root alone in a compact
/// one, and on no side pane.
@MainActor
@Suite("Server pages in a pane", .serialized)
struct ServerPagePaneSidebarTests {
    @Test func switchingServerPagesBesideAnotherPaneKeepsTheSidebarHidden() async throws {
        let shell = try ShellWindow()
        defer { shell.hide() }
        let navigation = shell.root.navigation
        #expect(navigation.panes.split(navigation.panes.mainLeafID, axis: .row) != nil)
        // The routed pane shows a chat or file: the sidebar is hidden.
        navigation.splitColumnVisibility = .detailOnly
        #expect(await shell.settles { shell.split.displayMode == .secondaryOnly })

        for (destination, page) in [
            (HostSwitcherDestination.serverMetrics, ServerMetricsViewController.self as UIViewController.Type),
            (.usage, UsageRouteViewController.self),
            (.serverMetrics, ServerMetricsViewController.self),
        ] {
            navigation.open(.serverJob(destination, serverId: "server-a"))
            #expect(await shell.settles {
                shell.stack.viewControllers.count == 1 && type(of: shell.stack.viewControllers[0]) == page
            }, "\(destination) replaced the routed pane's page")
            #expect(navigation.splitColumnVisibility == .detailOnly, "\(destination) left the sidebar hidden")
            #expect(shell.split.displayMode == .secondaryOnly, "\(destination) left the sidebar hidden")
            #expect(shell.sidebarToggle != nil, "\(destination) keeps the toggle that shows the sidebar on request")
        }
    }

    @Test func theMainShellStillShowsItsSidebarBesideAServerPage() async throws {
        let shell = try ShellWindow()
        defer { shell.hide() }
        let navigation = shell.root.navigation
        navigation.splitColumnVisibility = .detailOnly
        #expect(await shell.settles { shell.split.displayMode == .secondaryOnly })

        navigation.open(.serverJob(.serverMetrics, serverId: "server-a"))
        #expect(await shell.settles {
            shell.stack.topViewController is ServerMetricsViewController
                && shell.split.displayMode == .oneBesideSecondary
        }, "the sidebar shows beside Server Metrics")
        #expect(navigation.splitColumnVisibility == .all)
        #expect(shell.sidebarToggle != nil)
    }

    @Test func theSplitViewsSidebarButtonIsOnEveryMainPaneScreenAndNoSidePane() async throws {
        let shell = try ShellWindow()
        defer { shell.hide() }
        let navigation = shell.root.navigation
        let page = UIViewController()
        shell.stack.pushViewController(page, animated: false)
        #expect(await shell.settles { shell.stack.topViewController === page })
        let item = try #require(page.navigationItem.mainPaneSidebarItem, "A pushed screen has the sidebar button")
        #expect(item.accessibilityIdentifier == "workspace.split.sidebarToggle")
        #expect(page.navigationItem.leftItemsSupplementBackButton, "Back stays beside it")

        // A screen's own leading items keep it: after its own Back, before the rest.
        let own = UIBarButtonItem(title: "Own")
        let back = UIBarButtonItem(title: "Back")
        page.navigationItem.setLeadingItems([own])
        #expect(page.navigationItem.leadingItemGroups.flatMap(\.barButtonItems) == [item, own])
        page.navigationItem.setLeadingItems([own], back: back)
        #expect(page.navigationItem.leadingItemGroups.flatMap(\.barButtonItems) == [back, item, own])

        let shown = navigation.splitColumnVisibility != .detailOnly
        item.toggle()
        #expect(await shell.settles { (navigation.splitColumnVisibility != .detailOnly) != shown }, "It shows or hides the sidebar")
        #expect(await shell.settles { item.title == (shown ? "Show Sidebar" : "Hide Sidebar") }, "Its title says what a tap does")

        #expect(navigation.panes.split(navigation.panes.mainLeafID, axis: .row) != nil)
        #expect(await shell.settles { !shell.sidePaneScreens.isEmpty }, "A side pane opened")
        for screen in shell.sidePaneScreens {
            #expect(screen.navigationItem.mainPaneSidebarItem == nil, "\(type(of: screen)) in a side pane has no sidebar button")
        }
    }

    @Test func aCompactWindowHasTheDrawerButtonAtItsRootAlone() async throws {
        let shell = try ShellWindow(size: CGSize(width: 402, height: 874), horizontalSizeClass: .compact)
        defer { shell.hide() }
        let rootScreen = try #require(shell.stack.viewControllers.first)
        #expect(await shell.settles { rootScreen.navigationItem.mainPaneSidebarItem != nil }, "All Sessions has the drawer button")
        #expect(rootScreen.navigationItem.mainPaneSidebarItem?.accessibilityIdentifier == "workspace.sidebar.open")

        let page = UIViewController()
        shell.stack.pushViewController(page, animated: false)
        #expect(await shell.settles { shell.stack.topViewController === page })
        #expect(page.navigationItem.mainPaneSidebarItem == nil, "A pushed screen on a phone has Back alone")
        #expect(!shell.drawer.canToggleSidebar, "⌃⌘S waits for the root, as the button does")
    }

    @Test func aWideStackOpensTheDrawerFromAPushedScreen() async throws {
        let shell = try ShellWindow(size: CGSize(width: 744, height: 1133), horizontalSizeClass: .regular)
        defer { shell.hide() }
        let page = UIViewController()
        shell.stack.pushViewController(page, animated: false)
        #expect(await shell.settles { shell.stack.topViewController === page })
        let item = try #require(page.navigationItem.mainPaneSidebarItem, "The iPad in portrait has it at any depth")
        #expect(item.accessibilityIdentifier == "workspace.sidebar.open")
        #expect(shell.drawer.canToggleSidebar)
        item.toggle()
        #expect(shell.drawer.isSidebarOpen, "It opens the drawer over the pushed screen")
    }
}

/// The real workspace shell in an iPad mini landscape window, so it mounts
/// the split layout.
@MainActor
private struct ShellWindow {
    let root = makeTestAppRoot()
    let window: UIWindow
    let controller: WorkspaceShellController

    init(size: CGSize = CGSize(width: 1133, height: 744), horizontalSizeClass: UIUserInterfaceSizeClass = .regular) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.horizontalSizeClass = horizontalSizeClass
        window.traitOverrides.verticalSizeClass = .regular
        controller = WorkspaceShellController(root: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    var split: UISplitViewController {
        guard let split = Self.first(UISplitViewController.self, in: controller) else {
            preconditionFailure("The shell mounted no split layout")
        }
        return split
    }

    /// The routed stack: the one inside the pane host, not the sidebar's.
    var stack: ShellNavigationController {
        guard let host = Self.first(PaneHostController.self, in: controller),
              let stack = Self.first(ShellNavigationController.self, in: host) else {
            preconditionFailure("The shell has no routed stack")
        }
        return stack
    }

    var drawer: WorkspaceDrawerController {
        guard let drawer = Self.first(WorkspaceDrawerController.self, in: controller) else {
            preconditionFailure("The shell mounted no drawer layout")
        }
        return drawer
    }

    /// The screens of every pane but the main one.
    var sidePaneScreens: [UIViewController] {
        guard let host = Self.first(PaneHostController.self, in: controller) else { return [] }
        return host.children.compactMap { $0 as? UINavigationController }
            .filter { $0 !== stack }
            .flatMap(\.viewControllers)
    }

    /// The routed page's sidebar button, if it shows the split view's.
    var sidebarToggle: UIBarButtonItem? {
        stack.viewControllers.first?.navigationItem.mainPaneSidebarItem
            .flatMap { $0.accessibilityIdentifier == "workspace.split.sidebarToggle" ? $0 : nil }
    }

    /// Lays the window out until `condition` holds, with no transition in flight.
    func settles(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(3)) {
            controller.updatePropertiesIfNeeded()
            window.layoutIfNeeded()
            return stack.transitionCoordinator == nil && condition()
        }
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func first<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.lazy.compactMap { first(type, in: $0) }.first
    }
}
