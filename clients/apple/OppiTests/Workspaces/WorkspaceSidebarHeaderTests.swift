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
    @Test func theSplitSidebarsColumnShowsNoBarAboveItsHeaderRow() async throws {
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
        // The stack hides its bar from its delegate's `willShow`, which UIKit sends as the
        // column appears. A window's appearance transition can land a turn after it is
        // visible, so wait for the bar instead of reading it right after layout.
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { primary.isNavigationBarHidden },
            "The sidebar's column reserved an empty bar above its header row"
        )
    }
}
