import Testing
import UIKit
@testable import Oppi

/// The status bar follows the screen in front, so a screen that paints its own
/// background (the SSH terminal) can choose the clock's color. Each container
/// on the way up hands the question to its visible child.
@MainActor
@Suite("Status bar forwarding")
struct StatusBarForwardingTests {
    /// The session stack's front screen chooses the bar, through whatever
    /// containers (the pane host) sit between it and the drawer.
    @Test func theCompactDrawerFollowsItsSessionStack() throws {
        let drawer = WorkspaceDrawerController(root: makeTestAppRoot())
        drawer.loadViewIfNeeded()
        let stack = try #require(shellStack(in: drawer))
        let front = StyledScreen()
        stack.setViewControllers([front], animated: false)
        #expect(statusBarScreen(of: drawer) === front)
        #expect(statusBarScreen(of: drawer).preferredStatusBarStyle == .lightContent)
    }

    @Test func theSplitFollowsItsDetailOnlyWhileTheSidebarIsHidden() throws {
        let split = WorkspaceSplitController(root: makeTestAppRoot())
        split.loadViewIfNeeded()
        // The detail column's own containers mount their children with their views.
        split.viewController(for: .secondary)?.loadViewIfNeeded()
        let detail = try #require(split.viewController(for: .secondary).flatMap(shellStack(in:)))
        let front = StyledScreen()
        detail.setViewControllers([front], animated: false)
        #expect(split.childForStatusBarStyle == nil, "the sidebar is a list on the app's own surface")
        split.splitViewController(split, willChangeTo: .secondaryOnly)
        #expect(statusBarScreen(of: split) === front)
        split.splitViewController(split, willChangeTo: .oneBesideSecondary)
        #expect(split.childForStatusBarStyle == nil)
    }

    /// The controller UIKit asks for the style: `childForStatusBarStyle` followed to its end.
    private func statusBarScreen(of controller: UIViewController) -> UIViewController {
        var screen = controller
        while let child = screen.childForStatusBarStyle { screen = child }
        return screen
    }

    /// The first shell stack in `controller` or under it.
    private func shellStack(in controller: UIViewController) -> ShellNavigationController? {
        if let stack = controller as? ShellNavigationController { return stack }
        return controller.children.lazy.compactMap { shellStack(in: $0) }.first
    }

    @Test func theShellFollowsTheLayoutItMounted() async throws {
        let shell = WorkspaceShellController(root: makeTestAppRoot())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = shell
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        shell.view.layoutIfNeeded()
        // The shell also holds the Live Voice call strip; the layout is the stack or the split.
        func mountedLayout() -> UIViewController? {
            shell.children.first { $0 is WorkspaceDrawerController || $0 is WorkspaceSplitController }
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { mountedLayout() != nil })
        let layout = try #require(mountedLayout())
        #expect(shell.childForStatusBarStyle === layout)
    }

    private final class StyledScreen: UIViewController {
        override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    }

    @Test func aShellStackFollowsItsTopScreen() {
        let stack = ShellNavigationController(root: makeTestAppRoot(), rootPlacement: .compactRoot)
        let first = UIViewController()
        let second = UIViewController()
        stack.setViewControllers([first], animated: false)
        #expect(stack.childForStatusBarStyle === first)
        stack.setViewControllers([first, second], animated: false)
        #expect(stack.childForStatusBarStyle === second)
    }
}
