import Testing
import UIKit
@testable import Oppi

/// The responder chain decides which controller presents for a view, so these
/// run in a real, visible window: a view's `next` is its controller only once
/// the controller's view is installed there.
@Suite("UIResponder.nearestViewController")
@MainActor
struct NearestViewControllerTests {
    private func makeWindow(root: UIViewController? = nil) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @Test func aViewInsideAControllersViewFindsThatController() throws {
        let controller = UIViewController()
        let window = try makeWindow(root: controller)
        defer { hideTestWindow(window) }
        let container = UIView()
        let leaf = UIView()
        controller.view.addSubview(container)
        container.addSubview(leaf)

        #expect(leaf.nearestViewController === controller)
        #expect(container.nearestViewController === controller)
        #expect(controller.view.nearestViewController === controller)
        #expect(controller.nearestViewController === controller)
    }

    @Test func aViewInsideAChildControllerFindsTheChildNotItsParent() throws {
        let parent = UIViewController()
        let child = UIViewController()
        let window = try makeWindow(root: parent)
        defer { hideTestWindow(window) }
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        let insideChild = UIView()
        let insideParent = UIView()
        child.view.addSubview(insideChild)
        parent.view.addSubview(insideParent)

        #expect(insideChild.nearestViewController === child)
        #expect(insideParent.nearestViewController === parent)
    }

    @Test func aViewOutsideEveryControllerFindsNone() throws {
        let window = try makeWindow(root: UIViewController())
        defer { hideTestWindow(window) }
        let onWindow = UIView()
        window.addSubview(onWindow)
        let detached = UIView()
        detached.addSubview(UIView())

        #expect(onWindow.nearestViewController == nil)
        #expect(detached.nearestViewController == nil)
        #expect(detached.subviews[0].nearestViewController == nil)
    }
}
