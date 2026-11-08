import Testing
import UIKit
@testable import Oppi

/// The session lists keep their Message capsule and Now Playing pill installed
/// in the navigation toolbar under a pushed chat, so the capsule can slide in
/// with the pop. Over a chat those controls sit where the chat's composer does:
/// a tap meant for the composer reached the capsule and opened Quick Session.
/// Their actions run only while the list is the top of its stack.
@MainActor
@Suite("Session list bars under a pushed chat", .serialized)
struct SessionListUnderChatTests {
    /// A chat's screen as far as the bars are concerned: it hides the shared
    /// toolbar as it appears.
    private final class ChatStandIn: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.setToolbarHidden(true, animated: animated)
        }
    }

    private struct Fixture {
        let root: AppRootEnvironment
        let window: UIWindow
        let navigation: UINavigationController
        let list: SessionInboxViewController
    }

    private func makeFixture(root: AppRootEnvironment = makeTestAppRoot()) async throws -> Fixture {
        let list = SessionInboxViewController(root: root)
        let navigation = UINavigationController(rootViewController: list)
        let window = makeSceneWindow()
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let hasCapsule = await waitForMainActorCondition(timeout: .seconds(5)) {
            list.bottomBar.messageCapsule?.window != nil
        }
        try #require(hasCapsule, "the list never installed its Message capsule in the toolbar")
        return Fixture(root: root, window: window, navigation: navigation, list: list)
    }

    private func dictateButton(in capsule: SessionInboxMessageCapsule) throws -> UIButton {
        try #require(capsule.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "workspace.quickSession.dictate" })
    }

    @Test("a covered list's Message capsule and mic start nothing; its own tap starts Quick Session")
    func coveredListMessageActionsDoNothing() async throws {
        let fixture = try await makeFixture()
        defer { hideTestWindow(fixture.window) }
        let capsule = try #require(fixture.list.bottomBar.messageCapsule)
        let mic = try dictateButton(in: capsule)
        let navigation = fixture.navigation
        let root = fixture.root

        // The control: in front, the capsule starts Quick Session.
        capsule.sendActions(for: .touchUpInside)
        #expect(root.navigation.showQuickSession, "the list's own Message capsule must start Quick Session")
        root.navigation.showQuickSession = false

        // Mid-push: the chat is already the top screen, its transition still running.
        navigation.pushViewController(ChatStandIn(), animated: true)
        capsule.sendActions(for: .touchUpInside)
        mic.sendActions(for: .touchUpInside)
        #expect(!root.navigation.showQuickSession, "a capsule tap during the push opened Quick Session over the chat")

        // After the push.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { navigation.transitionCoordinator == nil })
        capsule.sendActions(for: .touchUpInside)
        mic.sendActions(for: .touchUpInside)
        #expect(!root.navigation.showQuickSession, "a capsule tap under the chat opened Quick Session")

        // Back in front, the capsule works again.
        navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            navigation.topViewController === fixture.list && navigation.transitionCoordinator == nil
        })
        capsule.sendActions(for: .touchUpInside)
        #expect(root.navigation.showQuickSession, "the capsule must work again once the list is back in front")
        root.navigation.showQuickSession = false
    }

    @Test("a covered workspace list starts no Quick Session")
    func coveredWorkspaceListDoesNothing() async throws {
        let root = makeTestAppRoot()
        let workspace = makeTestWorkspace(id: "w1", name: "Notes")
        let list = WorkspaceDetailViewController(
            root: root, target: WorkspaceNavTarget(serverId: "no-such-server", workspace: workspace)
        )
        let navigation = UINavigationController(rootViewController: list)
        let window = makeSceneWindow()
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { hideTestWindow(window) }

        list.startQuickSession(dictate: false)
        #expect(root.navigation.showQuickSession, "the control: the list in front starts Quick Session")
        root.navigation.showQuickSession = false

        navigation.pushViewController(ChatStandIn(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { navigation.transitionCoordinator == nil })
        list.startQuickSession(dictate: false)
        list.startQuickSession(dictate: true)
        #expect(!root.navigation.showQuickSession, "a workspace list under a chat started Quick Session")
    }

    @Test("a covered All Sessions list opens no file browser over the chat")
    func coveredListOpensNoFiles() async throws {
        let serverId = "sha256:list-under-chat-\(UUID().uuidString)"
        // The list's own refreshes fail as an unreachable server's do.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            if ["/workspaces", "/skills", "/sessions/recent"].contains(request.url?.path ?? "") {
                throw URLError(.cannotConnectToHost)
            }
            return nil
        })
        let root = try await makeTestAppRoot(
            readyServerId: serverId, apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let fixture = try await makeFixture(root: root)
        let list = fixture.list
        func tapFiles() throws {
            let files = try #require(list.toolbarItems?.first { $0.accessibilityIdentifier == "workspace.files.open" })
            try #require(files.primaryAction).performWithSender(files, target: nil)
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            list.toolbarItems?.contains { $0.accessibilityIdentifier == "workspace.files.open" && $0.isEnabled } == true
        })

        fixture.navigation.pushViewController(ChatStandIn(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fixture.navigation.transitionCoordinator == nil })
        try tapFiles()
        #expect(root.navigation.workspaceStackRouteElements.isEmpty, "Files under the chat opened the file browser over it")

        // The control: back in front, Files opens the server's files.
        fixture.navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            fixture.navigation.topViewController === list && fixture.navigation.transitionCoordinator == nil
        })
        try tapFiles()
        #expect(
            root.navigation.workspaceStackRouteElements == [.fileBrowser(.hostHome(serverId: serverId))],
            "the control: the list in front must open the server's files"
        )
        // Leaving the screen starts refreshes of its own: let them ask before the handler goes.
        hideTestWindow(fixture.window)
        _ = await routes.settle(quiet: .seconds(1.5))
        routes.end()
    }

    @Test("a covered All Sessions list opens no player over the chat")
    func coveredListOpensNoPlayer() async throws {
        let serverId = "sha256:list-under-chat-\(UUID().uuidString)"
        // The list's own refreshes fail as an unreachable server's do.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            if ["/workspaces", "/skills", "/sessions/recent"].contains(request.url?.path ?? "") {
                throw URLError(.cannotConnectToHost)
            }
            return nil
        })
        let root = try await makeTestAppRoot(
            readyServerId: serverId, apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let fixture = try await makeFixture(root: root)

        fixture.navigation.pushViewController(ChatStandIn(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fixture.navigation.transitionCoordinator == nil })
        fixture.list.openNowPlaying()
        #expect(
            await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
                fixture.window.rootViewController?.presentedViewController == nil
                    && fixture.navigation.presentedViewController == nil
            },
            "the Now Playing player opened over the chat"
        )

        // The control: back in front, the same call opens the player.
        fixture.navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            fixture.navigation.topViewController === fixture.list && fixture.navigation.transitionCoordinator == nil
        })
        fixture.list.openNowPlaying()
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) {
                fixture.window.rootViewController?.presentedViewController != nil
                    || fixture.navigation.presentedViewController != nil
            },
            "the control: the list in front must open the player"
        )
        // Leaving the screen starts refreshes of its own: let them ask before the handler goes.
        fixture.navigation.dismiss(animated: false)
        hideTestWindow(fixture.window)
        _ = await routes.settle(quiet: .seconds(1.5))
        routes.end()
    }
}
