import Testing
import UIKit
@testable import Oppi

/// The sidebar's own header row: the app icon and Edit Sidebar stand where a
/// navigation bar's title would be, so the column draws no bar above them.
@Suite("Workspace sidebar header")
@MainActor
struct WorkspaceSidebarHeaderTests {
    /// The split wraps the sidebar in a navigation stack. That stack's bar had
    /// nothing in it and still took a bar's height, which left a band between the
    /// status bar and the header row.
    @Test func theSplitSidebarsColumnShowsNoBarAboveItsHeaderRow() throws {
        let root = makeTestAppRoot()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.appRootEnvironment = root
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let split = WorkspaceSplitController(root: root)
        window.rootViewController = split
        window.makeKeyAndVisible()
        split.view.layoutIfNeeded()

        let primary = try #require(split.viewController(for: .primary) as? UINavigationController)
        primary.loadViewIfNeeded()
        let sidebar = try #require(primary.viewControllers.first as? WorkspaceSidebarViewController)
        sidebar.loadViewIfNeeded()
        #expect(sidebar.hidesNavigationBar, "The sidebar brings its own header row")
        #expect(primary.isNavigationBarHidden, "The sidebar's column reserved an empty bar above its header row")
    }
}
