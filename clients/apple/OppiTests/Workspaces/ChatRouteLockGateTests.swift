import Testing
import UIKit
@testable import Oppi

/// The chat route's lock gate reads the session's workspace from the store,
/// live. A refreshed record can move a session into a locked workspace after
/// its route was pushed; what is on screen must follow the store, not the
/// workspace the route was pushed with.
@MainActor
@Suite("Chat route lock gate")
struct ChatRouteLockGateTests {
    private struct Fixture {
        let serverId: String
        let root: AppRootEnvironment
        let connection: ServerConnection
        let window: UIWindow
        let navigation: UINavigationController
        let locks: ScopedLockService
        let restoreLookup: @MainActor (_ serverId: String, _ sessionId: String) -> Session?
        /// The chat route's own refreshes (git status, the file index, the trace page), answered
        /// for this test only.
        let routes: TestURLProtocol.RouteScope
    }

    private func makeFixture() async throws -> Fixture {
        let serverId = "sha256:chat-route-lock-\(UUID().uuidString)"
        // The chat route starts the app's own refreshes (git status, the file index, the
        // session's trace page); they answer as an unreachable server does, and a route the
        // test did not plan fails it.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        let client = makeTestURLProtocolClient(host: "ready-server.test")
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(root.coordinator.connection(for: serverId))
        let locks = ScopedLockService.shared
        let restoreLookup = locks.sessionLookup
        locks.sessionLookup = { [coordinator = root.coordinator] serverId, sessionId in
            coordinator.connection(for: serverId)?.sessionStore.session(id: sessionId)
        }
        let window = makeSceneWindow()
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        return Fixture(
            serverId: serverId,
            root: root,
            connection: connection,
            window: window,
            navigation: navigation,
            locks: locks,
            restoreLookup: restoreLookup,
            routes: routes
        )
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.window.rootViewController = UIViewController()
        fixture.window.isHidden = true
        fixture.locks.sessionLookup = fixture.restoreLookup
        fixture.locks.forgetServer(fixture.serverId)
        fixture.routes.end()
    }

    private func push(_ sessionId: String, workspaceId: String, in fixture: Fixture) -> ChatRouteViewController {
        let session = fixture.connection.sessionStore.session(id: sessionId)
        let route = ChatRouteViewController(
            target: WorkspaceSessionNavTarget(
                serverId: fixture.serverId,
                sessionId: sessionId,
                workspaceId: workspaceId,
                routeScope: session?.routeScope
            ),
            placement: .compactRoot,
            root: fixture.root
        )
        fixture.navigation.pushViewController(route, animated: false)
        fixture.navigation.view.layoutIfNeeded()
        route.updatePropertiesIfNeeded()
        return route
    }

    private func hasLockCover(_ route: ChatRouteViewController) -> Bool {
        route.children.contains { $0 is ScopedLockCoverViewController }
    }

    @Test("a session that moves into a locked workspace after its route is up is covered at once")
    func movedSessionIsCoveredAtOnce() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w1", status: .stopped))
        let route = push("child", workspaceId: "w1", in: fixture)
        let chat = try #require(route.chat, "an unlocked session shows its chat")
        #expect(!hasLockCover(route))

        // The refreshed record puts the session in w2, which is locked. The route was pushed with w1.
        fixture.locks.lock(.workspace(serverId: fixture.serverId, workspaceId: "w2"))
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w2", status: .stopped))

        let covered = await waitForMainActorCondition(timeout: .seconds(3)) {
            fixture.navigation.view.layoutIfNeeded()
            return route.chat == nil && hasLockCover(route)
        }
        #expect(covered, "the chat stayed up (or no cover showed) for a session in a locked workspace")
        #expect(chat.viewIfLoaded?.superview == nil, "the chat's content is still in the hierarchy")
        // A mounted chat retries its own loads; releasing it first means the requests it still
        // had running end with this test, not after the handler that answers them.
        fixture.navigation.setViewControllers([], animated: false)
        #expect(await fixture.routes.settle(), "a request outlived the test that answered it")
    }

    /// The route under a newer one (the open was superseded, or the person pushed another screen)
    /// never updated while hidden. Back must not show the chat: it comes up covered.
    @Test("Back to a route whose session moved into a locked workspace shows the cover, not the chat")
    func backDoesNotRevealAMovedSession() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w1", status: .stopped))
        fixture.connection.sessionStore.upsert(makeTestSession(id: "other", workspaceId: "w1", status: .stopped))
        let moved = push("child", workspaceId: "w1", in: fixture)
        #expect(moved.chat != nil)
        _ = push("other", workspaceId: "w1", in: fixture)

        fixture.locks.lock(.workspace(serverId: fixture.serverId, workspaceId: "w2"))
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w2", status: .stopped))
        fixture.navigation.popViewController(animated: false)
        fixture.navigation.view.layoutIfNeeded()

        #expect(fixture.navigation.topViewController === moved)
        let covered = await waitForMainActorCondition(timeout: .seconds(3)) {
            fixture.navigation.view.layoutIfNeeded()
            return moved.chat == nil && hasLockCover(moved)
        }
        #expect(covered, "Back revealed the chat of a session in a locked workspace")
        fixture.navigation.setViewControllers([], animated: false)
        #expect(await fixture.routes.settle(), "a request outlived the test that answered it")
    }

    @Test("a covered moved session shows its chat again once the new workspace is unlocked")
    func unlockingTheNewWorkspaceRevealsTheChat() async throws {
        let fixture = try await makeFixture()
        defer { tearDown(fixture) }
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w1", status: .stopped))
        let route = push("child", workspaceId: "w1", in: fixture)
        fixture.locks.lock(.workspace(serverId: fixture.serverId, workspaceId: "w2"))
        fixture.connection.sessionStore.upsert(makeTestSession(id: "child", workspaceId: "w2", status: .stopped))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            fixture.navigation.view.layoutIfNeeded()
            return route.chat == nil
        }

        fixture.locks.noteCreated(.workspace(serverId: fixture.serverId, workspaceId: "w2"))
        let revealed = await waitForMainActorCondition(timeout: .seconds(3)) {
            fixture.navigation.view.layoutIfNeeded()
            return route.chat != nil && !hasLockCover(route)
        }
        #expect(revealed, "unlocking the new workspace did not bring the chat back")
        fixture.navigation.setViewControllers([], animated: false)
        #expect(await fixture.routes.settle(), "a request outlived the test that answered it")
    }
}
