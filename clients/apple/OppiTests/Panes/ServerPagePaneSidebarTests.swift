import Testing
import UIKit
@testable import Oppi

/// A server page (Server Metrics, Usage, Server Settings) picked from the
/// server switcher in the landscape split shell. Beside another pane it is
/// that pane's content: switching pages swaps it in place and the window's
/// sidebar stays hidden. With no other pane the page keeps its sidebar.
@MainActor
@Suite("Server pages in a pane", .serialized)
struct ServerPagePaneSidebarTests {
    @Test func switchingServerPagesBesideAnotherPaneKeepsTheSidebarHidden() async throws {
        let shell = try ShellWindow()
        defer { shell.hide() }
        let navigation = shell.root.navigation
        navigation.panes.splitsEnabled = true
        #expect(navigation.panes.split(navigation.panes.routedLeafID, axis: .row) != nil)
        // The routed pane shows a chat or file: the sidebar is hidden.
        navigation.splitColumnVisibility = .detailOnly
        #expect(await shell.settles { shell.split.displayMode == .secondaryOnly })

        for (destination, page) in [
            (HostSwitcherDestination.serverMetrics, ServerMetricsViewController.self as UIViewController.Type),
            (.usage, UsageRouteViewController.self),
            (.serverMetrics, ServerMetricsViewController.self),
        ] {
            navigation.openHostSwitcherDestination(destination, serverId: "server-a")
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
        navigation.panes.splitsEnabled = true
        navigation.splitColumnVisibility = .detailOnly
        #expect(await shell.settles { shell.split.displayMode == .secondaryOnly })

        navigation.openHostSwitcherDestination(.serverMetrics, serverId: "server-a")
        #expect(await shell.settles {
            shell.stack.topViewController is ServerMetricsViewController
                && shell.split.displayMode == .oneBesideSecondary
        }, "the sidebar shows beside Server Metrics")
        #expect(navigation.splitColumnVisibility == .all)
        #expect(shell.sidebarToggle != nil)
    }
}

/// The real workspace shell in an iPad mini landscape window, so it mounts
/// the split layout.
@MainActor
private struct ShellWindow {
    let root = makeTestAppRoot()
    let window: UIWindow
    let controller: WorkspaceShellController

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
        window.traitOverrides.horizontalSizeClass = .regular
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

    /// The routed page's sidebar toggle, if it shows one.
    var sidebarToggle: UIBarButtonItem? {
        stack.viewControllers.first?.navigationItem.leftBarButtonItems?
            .first { $0.accessibilityIdentifier == "workspace.split.sidebarToggle" }
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
