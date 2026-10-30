import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Shell route screens")
struct ShellRouteScreensTests {
    private func loadingConfiguration(in controller: UIViewController) -> UIContentUnavailableConfiguration? {
        if let configuration = controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration {
            return configuration
        }
        return controller.children.lazy.compactMap { loadingConfiguration(in: $0) }.first
    }

    @Test("a session route whose server is not up says Connecting… on the theme's background")
    func sessionRouteWaitsForItsServer() throws {
        let root = makeTestAppRoot()
        let route = ChatRouteViewController(
            target: WorkspaceSessionNavTarget(serverId: "sha256:not-connected", sessionId: "s1"),
            placement: .compactRoot,
            root: root
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: route)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        route.view.layoutIfNeeded()
        route.updatePropertiesIfNeeded()

        let configuration = try #require(loadingConfiguration(in: route))
        #expect(configuration.text == "Connecting\u{2026}")
        #expect(configuration.background.backgroundColor == root.themeStore.backgroundColor)
    }
}
