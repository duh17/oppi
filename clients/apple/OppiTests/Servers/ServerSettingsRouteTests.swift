import Foundation
import Testing
import UIKit
@testable import Oppi

/// Server Settings follows the visible server through its route screen: one page per
/// server, each pinned to the server it was made for.
@Suite("Server Settings route", .serialized)
@MainActor
struct ServerSettingsRouteTests {
    private struct Harness {
        var root: AppRootEnvironment
        var route: ServerSettingsRouteViewController
        var navigation: UINavigationController
        var window: UIWindow
    }

    private func makeServer(_ id: String, order: Int) throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: "\(id).held.test", port: 7749, token: "sk_test", name: id, scheme: .https, serverFingerprint: id),
            sortOrder: order
        ))
    }

    /// Two paired servers, `server-a` active, whose requests the test answers by host.
    private func makeHarness() throws -> Harness {
        let servers = [try makeServer("server-a", order: 0), try makeServer("server-b", order: 1)]
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldRequestProtocol.self]
        for server in servers {
            let client = APIClient(
                baseURL: try #require(URL(string: "https://\(server.id).held.test:7749")),
                token: "sk_test",
                configuration: configuration
            )
            coordinator.ensureConnection(for: server).setAPIClientForTesting(client)
        }
        #expect(coordinator.restoreActiveServer("server-a"))
        let root = makeTestAppRoot(coordinator: coordinator)
        let route = ServerSettingsRouteViewController(target: ServerDetailsNavTarget(serverId: "server-a"), root: root)
        let navigation = UINavigationController(rootViewController: route)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        HeldRequestProtocol.reset()
        return Harness(root: root, route: route, navigation: navigation, window: window)
    }

    private func hide(_ harness: Harness) {
        HeldRequestProtocol.reset()
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    @Test("Opens on the visible server, not the one the route was made for")
    func opensOnTheVisibleServer() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        _ = h.root.coordinator.restoreActiveServer("server-b")
        let route = ServerSettingsRouteViewController(target: ServerDetailsNavTarget(serverId: "server-a"), root: h.root)
        h.navigation.setViewControllers([route], animated: false)

        route.loadViewIfNeeded()

        #expect(route.pinnedServerId == "server-b")
        #expect(route.page?.server.id == "server-b")
        #expect(route.page?.model.serverId == "server-b")
    }

    @Test("A switch pops the pages pushed above the route and shows the new server's page")
    func switchPopsAndSwaps() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        #expect(first.server.id == "server-a")
        // About, Paired Devices and Badge are pinned to the server they were opened for.
        h.navigation.pushViewController(UIViewController(), animated: false)
        h.navigation.pushViewController(UIViewController(), animated: false)
        #expect(h.navigation.viewControllers.count == 3)

        _ = h.root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route])
        let second = try #require(h.route.page)
        #expect(second !== first)
        #expect(second.server.id == "server-b")
        #expect(second.model !== first.model)
        #expect(second.model.serverId == "server-b")
        #expect(first.parent == nil)
        #expect(h.route.children == [second])
        // The page's switcher is on the route's bar, and names the server the page is pinned to.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.route.navigationItem.rightBarButtonItems?.first?.accessibilityLabel == "Current server: server-b"
                || h.route.navigationItem.rightBarButtonItems?.first?.customView?.accessibilityLabel == "Current server: server-b"
        })
    }

    @Test("Nothing changes while the visible server stays the same")
    func sameServerKeepsThePage() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        h.navigation.pushViewController(UIViewController(), animated: false)

        // Re-selecting the active server is not a change.
        _ = h.root.coordinator.restoreActiveServer("server-a")
        h.route.setNeedsUpdateProperties()
        h.route.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.route.page === first)
        #expect(h.navigation.viewControllers.count == 2)
    }

    @Test("A route that is closing gives the server the removal makes active no page")
    func closingRouteDoesNotSwap() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)

        h.route.willFinish()
        _ = h.root.coordinator.restoreActiveServer("server-b")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.route.page === first)
        #expect(h.route.pinnedServerId == "server-a")
    }

    @Test("A load that settles after the switch lands in the page that asked, never the new one")
    func lateLoadSettlesIntoItsOwnModel() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let pageA = try #require(h.route.page)
        let modelA = pageA.model
        #expect(modelA.isLoading)

        _ = h.root.coordinator.restoreActiveServer("server-b")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        let pageB = try #require(h.route.page)
        let modelB = pageB.model
        // Both servers' requests are still out.
        #expect(modelA.isLoading)
        #expect(modelB.isLoading)

        HeldRequestProtocol.answer(host: "server-a.held.test")

        // A's answer arrives and settles A's model, which is no longer on screen.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !modelA.isLoading })
        #expect(modelA.error != nil)
        // B's model never heard of it: still loading, nothing of A's in it.
        #expect(modelB.isLoading)
        #expect(modelB.error == nil)
        #expect(modelB.info == nil)
        #expect(modelB.pairedDevices == nil)
        #expect(h.route.page === pageB)
    }
}

/// An HTTP route that keeps each request on the `*.held.test` hosts waiting until the
/// test answers that host (every request, queued or later, then fails with a 500).
private final class HeldRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [HeldRequestProtocol] = []
    nonisolated(unsafe) private static var answered: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".held.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let answerNow = Self.lock.withLock {
            if Self.answered.contains(host) { return true }
            Self.held.append(self)
            return false
        }
        if answerNow { fail() }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }

    private func fail() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 500,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(#"{"error":"held"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func answer(host: String) {
        let waiting = lock.withLock {
            answered.insert(host)
            let ready = held.filter { $0.request.url?.host == host }
            held.removeAll { $0.request.url?.host == host }
            return ready
        }
        for request in waiting { request.fail() }
    }

    static func reset() {
        lock.withLock {
            held = []
            answered = []
        }
    }
}
