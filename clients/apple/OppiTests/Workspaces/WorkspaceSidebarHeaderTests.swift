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
            hideTestWindow(window)
            window.rootViewController = nil
        }

        let split = WorkspaceSplitController(root: root)
        let primary = try #require(split.viewController(for: .primary) as? UINavigationController)
        let sidebar = try #require(primary.viewControllers.first as? WorkspaceSidebarViewController)
        #expect(sidebar.hidesNavigationBar, "The sidebar brings its own header row")
        // The column's stack is never routed: it holds the sidebar from the
        // split's `init` and asks for its bar then. Read here, before a window
        // shows the column, a bar that waits for the appearance UIKit sends the
        // stack is a bar the column reserves for as long as that appearance takes.
        #expect(primary.isNavigationBarHidden, "The sidebar's column reserved an empty bar above its header row")

        window.rootViewController = split
        window.makeKeyAndVisible()
        split.view.layoutIfNeeded()
        #expect(primary.isNavigationBarHidden, "The column appeared and brought the bar back")
    }
}
