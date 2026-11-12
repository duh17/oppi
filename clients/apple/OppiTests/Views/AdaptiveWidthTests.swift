import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Adaptive width")
struct AdaptiveWidthTests {
    /// A panel in an attached leaf reads compact through a trait override
    /// while its window is wide, and the search bar's Cancel follows the
    /// window. The override here flips the view away from the scene's width, so
    /// a read of the view's own traits would answer the wrong way round.
    @Test("system chrome follows the window's width, not a trait override on the view")
    func windowWidthIgnoresTraitOverride() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let sceneIsWide = AdaptiveWidth.isWide(scene.traitCollection)
        let host = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.traitOverrides.horizontalSizeClass = sceneIsWide ? .compact : .regular
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        host.view.layoutIfNeeded()
        #expect(AdaptiveWidth.isWide(host.view.traitCollection) != sceneIsWide, "the override must reach the view")

        #expect(AdaptiveWidth.windowIsWide(host.view) == sceneIsWide)

        let search = ScreenSearchController(prompt: "Search")
        host.view.addSubview(search.searchController.searchBar)
        search.keepsNavigationBarInWideWindow()
        search.willPresentSearchController(search.searchController)
        #expect(search.searchController.hidesNavigationBarDuringPresentation == !sceneIsWide)
    }
}
