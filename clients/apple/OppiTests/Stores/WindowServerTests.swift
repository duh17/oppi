import Testing
import UIKit
@testable import Oppi

/// V1: each window has its own server. Its lists and server pages follow it;
/// its leaves keep their route's server, and another window keeps its own.
@MainActor
@Suite("Each window's own server", .serialized)
struct WindowServerTests {
    private let firstId = "sha256:window-first"
    private let otherId = "sha256:window-other"

    @Test("one window's switch moves only its own server pages; a leaf bringing its server forward moves none")
    func switchingOneWindowLeavesItsLeavesAndOtherWindows() async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let root = try await makeTestTwoServerRoot(firstId: firstId, otherId: otherId)
        let second = Self.secondWindow(sharing: root)
        // Launch chooses a server for every window.
        root.navigation.recordChosenServer(firstId)
        second.navigation.recordChosenServer(firstId)
        let chat = WorkspaceSessionNavTarget(serverId: firstId, sessionId: "s-first", workspaceId: "w-first")
        root.navigation.openWorkspaceSession(chat)

        let screenA = ServerExtensionsViewController(root: root)
        let screenB = ServerExtensionsViewController(root: second)
        let windowA = try Self.show(UINavigationController(rootViewController: screenA), x: 0)
        let windowB = try Self.show(UINavigationController(rootViewController: screenB), x: 400)
        defer { Self.hide(windowA); Self.hide(windowB) }
        #expect(await Self.showsServer("Ready", on: screenA))
        #expect(await Self.showsServer("Ready", on: screenB))

        // Window A's host switcher picks the other server.
        #expect(root.navigation.chooseServer(otherId, coordinator: root.coordinator))
        #expect(await Self.showsServer("Other", on: screenA), "the switching window's page follows its server")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            screenB.view.layoutIfNeeded()
            return Self.serverLabel(on: screenB) == "Current server: Ready"
        }, "the other window keeps its own server")
        #expect(root.navigation.workspaceStackRouteElements == [.session(chat)], "the chat leaf stays")
        #expect(second.windowServerId == firstId)

        // A chat leaf on the first server opens its own connection (as
        // `ChatRouteViewController` does): no window moves.
        #expect(await root.coordinator.switchToServerReady(firstId))
        #expect(root.coordinator.activeServerId == firstId)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            screenA.view.layoutIfNeeded()
            return Self.serverLabel(on: screenA) == "Current server: Other"
        }, "a leaf's server is not the window's")
        #expect(root.windowServerId == otherId)
        #expect(await routes.settle(), "a request outlived the test that answered it")
    }

    @Test("a window that never chose follows the coordinator; one whose server is unpaired shows the first paired")
    func windowServerFallbacks() async throws {
        let root = try await makeTestTwoServerRoot(firstId: firstId, otherId: otherId)
        #expect(root.windowServerId == firstId, "before launch chooses, the transport focus")
        #expect(root.coordinator.restoreActiveServer(otherId))
        #expect(root.windowServerId == otherId)

        root.navigation.recordChosenServer("sha256:removed")
        #expect(root.windowServerId == firstId, "a removed server's window shows the first paired server")
    }

    // MARK: - Helpers

    /// Another window's services: the same app (coordinator, stores, app
    /// state), its own navigation.
    private static func secondWindow(sharing root: AppRootEnvironment) -> AppRootEnvironment {
        AppRootEnvironment(
            coordinator: root.coordinator,
            navigation: SceneNavigation(app: root.navigation.app),
            themeStore: root.themeStore,
            quickCommentTemplateStore: root.quickCommentTemplateStore,
            composerDraftStore: root.composerDraftStore,
            chatReaderPayloadStore: root.chatReaderPayloadStore,
            sessionRows: root.sessionRows,
            liveVoiceCalls: root.liveVoiceCalls
        )
    }

    private static func showsServer(_ name: String, on screen: UIViewController) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return serverLabel(on: screen) == "Current server: \(name)"
        }
    }

    private static func serverLabel(on screen: UIViewController) -> String? {
        button(withIdentifier: "serverCatalog.server.menu", in: screen.view)?.accessibilityLabel
    }

    private static func show(_ controller: UIViewController, x: CGFloat) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: x, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private static func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }
}
