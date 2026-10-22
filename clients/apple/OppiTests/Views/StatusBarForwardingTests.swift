import Testing
import UIKit
@testable import Oppi

/// The status bar follows the screen in front, so a screen that paints its own
/// background (the SSH terminal) can choose the clock's color. Each container
/// on the way up hands the question to its visible child.
@MainActor
@Suite("Status bar forwarding")
struct StatusBarForwardingTests {
    @Test func theCompactDrawerFollowsItsSessionStack() throws {
        let drawer = WorkspaceDrawerController(root: makeTestAppRoot())
        drawer.loadViewIfNeeded()
        let stack = try #require(drawer.children.compactMap { $0 as? ShellNavigationController }.first)
        #expect(drawer.childForStatusBarStyle === stack)
    }

    @Test func theSplitFollowsItsDetailOnlyWhileTheSidebarIsHidden() throws {
        let split = WorkspaceSplitController(root: makeTestAppRoot())
        split.loadViewIfNeeded()
        let detail = try #require(split.viewController(for: .secondary) as? ShellNavigationController)
        #expect(split.childForStatusBarStyle == nil, "the sidebar is a list on the app's own surface")
        split.splitViewController(split, willChangeTo: .secondaryOnly)
        #expect(split.childForStatusBarStyle === detail)
        split.splitViewController(split, willChangeTo: .oneBesideSecondary)
        #expect(split.childForStatusBarStyle == nil)
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
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { !shell.children.isEmpty })
        let layout = try #require(shell.children.first)
        #expect(shell.childForStatusBarStyle === layout)
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
