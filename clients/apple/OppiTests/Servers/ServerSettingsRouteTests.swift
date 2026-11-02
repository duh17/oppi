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
        var navigation: RoutedStack
        var window: UIWindow
    }

    /// A stack that, like the shell's, knows which screens a route made.
    private final class RoutedStack: UINavigationController, RoutedScreenStack {
        var routed: [UIViewController] = []

        func isRouted(_ screen: UIViewController) -> Bool {
            routed.contains { $0 === screen }
        }
    }

    private func makeServer(_ id: String, order: Int) throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: "\(id).held.test", port: 7749, token: "sk_test", name: id, scheme: .https, serverFingerprint: id),
            sortOrder: order
        ))
    }

    /// Two paired servers, `server-a` active, whose requests the test answers by host.
    private func makeHarness() async throws -> Harness {
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
            await coordinator.ensureTestConnectionReady(for: server).setAPIClientForTesting(client)
        }
        #expect(coordinator.restoreActiveServer("server-a"))
        let root = makeTestAppRoot(coordinator: coordinator)
        let route = ServerSettingsRouteViewController(target: ServerDetailsNavTarget(serverId: "server-a"), root: root)
        let navigation = RoutedStack(rootViewController: route)
        navigation.routed = [route]
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = navigation
        // Nothing answers before the pages ask: a host decided held or answered by an
        // earlier test must not decide this one's requests.
        HeldRequestProtocol.reset()
        // The route builds its page as it loads, so the window shows that page: its
        // appearance — and the load the kit starts there — begins with the route's.
        route.loadViewIfNeeded()
        window.makeKeyAndVisible()
        return Harness(root: root, route: route, navigation: navigation, window: window)
    }

    private func hide(_ harness: Harness) {
        HeldRequestProtocol.reset()
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    @Test("Opens on the visible server, not the one the route was made for")
    func opensOnTheVisibleServer() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        _ = h.root.coordinator.restoreActiveServer("server-b")
        let route = ServerSettingsRouteViewController(target: ServerDetailsNavTarget(serverId: "server-a"), root: h.root)
        h.navigation.setViewControllers([route], animated: false)
        h.navigation.routed = [route]

        route.loadViewIfNeeded()

        #expect(route.pinnedServerId == "server-b")
        #expect(route.page?.server.id == "server-b")
        #expect(route.page?.model.serverId == "server-b")
    }

    /// A page the Server Settings page pushed (About, Paired Devices, Badge Icon): pinned to its server.
    private func pushPageOwnedBy(_ page: ServerSettingsViewController, in navigation: UINavigationController, title: String) -> UIViewController {
        let screen = UIViewController()
        screen.title = title
        navigation.pushViewController(screen, animated: false)
        page.track(screen)
        return screen
    }

    /// A screen the shell routed above Server Settings, as Model Providers is.
    private func pushRoutedScreen(in navigation: RoutedStack) -> UIViewController {
        let screen = UIViewController()
        screen.title = "Model Providers"
        navigation.pushViewController(screen, animated: false)
        navigation.routed.append(screen)
        return screen
    }

    /// A page one of the page's own pages pushed, which nothing tracks (a workspace's settings
    /// opened from Workspaces).
    private func pushUntrackedPage(in navigation: UINavigationController, title: String) -> UIViewController {
        let screen = UIViewController()
        screen.title = title
        navigation.pushViewController(screen, animated: false)
        return screen
    }

    @Test("A switch closes the pages Server Settings pushed and shows the new server's page")
    func switchClosesItsPushedPagesAndSwaps() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        #expect(first.server.id == "server-a")
        let about = pushPageOwnedBy(first, in: h.navigation, title: "About This Server")
        let devices = pushPageOwnedBy(first, in: h.navigation, title: "Paired Devices")
        #expect(h.navigation.viewControllers == [h.route, about, devices])

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

    @Test("The pages the page itself opens are tracked, pinned to its server, and closed by a switch")
    func openedPagesAreTrackedAndClosed() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)

        first.select(.about)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.navigation.viewControllers.count == 2 })
        let about = try #require(h.navigation.viewControllers.last as? ServerAboutViewController)
        #expect(about.server.id == "server-a")
        #expect(about.model === first.model)

        // The next page is pushed once the previous push settles (as a person would).
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.navigation.transitionCoordinator == nil })
        first.select(.pairedDevices)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.navigation.viewControllers.last is ServerPairedDevicesViewController })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.navigation.transitionCoordinator == nil })
        first.select(.badge)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.navigation.viewControllers.last is ServerBadgeViewController })
        #expect(first.pushedScreens.count == 3)

        _ = h.root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route])
    }

    @Test("A routed screen above Server Settings survives a switch, with or without a pushed page below it")
    func routedScreenSurvivesASwitch() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        // Model Providers has its own switcher and keeps a provider sign-in alive across a switch.
        let about = pushPageOwnedBy(first, in: h.navigation, title: "About This Server")
        let providers = pushRoutedScreen(in: h.navigation)
        #expect(h.navigation.viewControllers == [h.route, about, providers])

        _ = h.root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route, providers])
        #expect(h.route.page?.server.id == "server-b")

        // And with nothing of the old page's above it.
        _ = h.root.coordinator.restoreActiveServer("server-a")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-a" })
        #expect(h.navigation.viewControllers == [h.route, providers])
    }

    @Test("What a pushed page pushed in turn closes with it, up to the next routed screen")
    func pagesPushedByPushedPagesCloseToo() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        // Workspaces, then a workspace's settings from it, then Model Providers routed above both.
        let workspaces = pushPageOwnedBy(first, in: h.navigation, title: "Workspaces")
        let workspaceSettings = pushUntrackedPage(in: h.navigation, title: "Workspace Settings")
        let providers = pushRoutedScreen(in: h.navigation)
        #expect(h.navigation.viewControllers == [h.route, workspaces, workspaceSettings, providers])

        _ = h.root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route, providers])
    }

    @Test("A page nobody asked about stays when nothing of Server Settings' is below it")
    func unrelatedPushedPageStays() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let other = pushUntrackedPage(in: h.navigation, title: "Something else")

        _ = h.root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route, other])
    }

    @Test("In a split view, a switch made from the primary column closes About in the detail and shows the new server")
    func switchFromThePrimaryColumnClosesAboutInTheDetail() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        // The detail column is the harness's stack; the primary column is another one, as on iPad.
        // Its switch runs `HostSwitcherModel.switchHost`, the activation every server menu ends in.
        let primary = UINavigationController(rootViewController: UIViewController())
        let split = UISplitViewController(style: .doubleColumn)
        split.setViewController(primary, for: .primary)
        split.setViewController(h.navigation, for: .secondary)
        h.window.rootViewController = split
        h.window.makeKeyAndVisible()
        h.route.loadViewIfNeeded()
        let page = try #require(h.route.page)
        let about = pushPageOwnedBy(page, in: h.navigation, title: "About This Server")
        #expect(h.navigation.viewControllers == [h.route, about])

        let coordinator = h.root.coordinator
        let model = HostSwitcherModel(
            coordinator: coordinator,
            serverStore: coordinator.serverStore,
            navigation: h.root.navigation,
            current: try #require(coordinator.serverStore.server(for: "server-a")),
            destination: .serverSettings
        )
        model.switchHost(try #require(coordinator.serverStore.server(for: "server-b")))

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        #expect(h.navigation.viewControllers == [h.route])
        #expect(h.route.page?.server.id == "server-b")
        #expect(about.parent == nil)
    }

    @Test("Nothing changes while the visible server stays the same")
    func sameServerKeepsThePage() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)
        _ = pushPageOwnedBy(first, in: h.navigation, title: "About This Server")

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
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let first = try #require(h.route.page)

        h.route.willFinish()
        _ = h.root.coordinator.restoreActiveServer("server-b")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.route.page === first)
        #expect(h.route.pinnedServerId == "server-a")
    }

    @Test("A switch cancels the page it replaced, and the new page's load is its own")
    func switchCancelsTheReplacedPagesLoad() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let pageA = try #require(h.route.page)
        let modelA = pageA.model
        // The page the route shows is the page that appears, so it is the page whose
        // load the kit starts.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { pageA.isShowing })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            HeldRequestProtocol.heldHosts.contains("server-a.held.test")
        }, "the page's load asked A")

        _ = h.root.coordinator.restoreActiveServer("server-b")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.route.pinnedServerId == "server-b" })
        let pageB = try #require(h.route.page)
        let modelB = pageB.model
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { pageB.isShowing })

        // A left with the switch, so the kit cancelled its load: a cancel is not the
        // model's failure, and A's facts stay as they were.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !pageA.isLoading })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            modelA.updateStartError == nil && modelA.loadError == nil
        }, "a cancelled load is not a failure")

        // B asked for its own facts; answering A changes nothing in B.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            HeldRequestProtocol.heldHosts.contains("server-b.held.test")
        }, "the new page's load asked B")
        HeldRequestProtocol.answer(host: "server-a.held.test")
        HeldRequestProtocol.answer(host: "server-b.held.test")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !pageB.isLoading })
        #expect(h.route.page === pageB)
        #expect(modelB.updateStartError != nil || modelB.loadError != nil, "B settled on its own answer")
    }

    @Test("A load the page left while it waited asks nothing when the answer lands")
    func leavingStopsALoadThatIsWaiting() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let page = try #require(h.route.page)
        let model = page.model
        // The page's load asked for the server's facts, and that request is waiting.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isShowing })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            HeldRequestProtocol.heldHosts.contains("server-a.held.test")
        })
        let asked = HeldRequestProtocol.startedPaths

        // The page leaves while the load waits, then the server answers what it waited on.
        h.navigation.setViewControllers([UIViewController()], animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })
        HeldRequestProtocol.answer(host: "server-a.held.test")

        // A load whose page is gone asks nothing more, and writes nothing: the answer it was
        // given after the page left is nobody's, and the facts it would have asked for next
        // (the providers, the devices) are not asked for.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            HeldRequestProtocol.startedPaths == asked
        }, "a load the page left asked the server for more")
        #expect(!HeldRequestProtocol.startedPaths.contains("/provider-auth/status"))
        #expect(!HeldRequestProtocol.startedPaths.contains("/auth/devices"))
        #expect(model.info == nil, "a load the page left kept the info it was answered with")
        #expect(model.providerSetupState == .unknown)
        #expect(model.pairedDevices == nil)
        #expect(model.loadError == nil, "a cancelled load is not a failure")
    }

    @Test("A load the page cancelled before it asked starts no request and writes nothing")
    func cancelledLoadBeforeItAsksStartsNothing() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let page = try #require(h.route.page)
        let model = page.model
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isShowing })
        // The page's own load is out and held, so what this test cancels is a load of its own.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            HeldRequestProtocol.heldHosts.contains("server-a.held.test")
        })
        h.navigation.setViewControllers([UIViewController()], animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })

        // A load cancelled while it waits for its client (the page left during a connection
        // preparation, say) asks for nothing when that wait ends: there is no page to answer.
        let asked = HeldRequestProtocol.startedPaths
        let load = Task { await model.load() }
        load.cancel()
        await load.value

        #expect(HeldRequestProtocol.startedPaths == asked, "a cancelled load asked the server")
        #expect(model.info == nil, "a cancelled load kept the info it was answered with")
        #expect(model.providerSetupState == .unknown)
        #expect(model.pairedDevices == nil)
        #expect(model.loadError == nil, "a cancelled load is not a failure")
    }

    @Test("A load the page cancels on its way out leaves the model's facts alone")
    func cancelledLoadLeavesTheModelsOwnFactsAlone() async throws {
        let h = try await makeHarness()
        defer { hide(h) }
        h.route.loadViewIfNeeded()
        let page = try #require(h.route.page)
        let model = page.model
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.isShowing })

        // About This Server loads the same model; every request is held, so its load
        // is in flight when the page is popped.
        let about = ServerAboutViewController(model: model, server: page.server, root: h.root)
        h.navigation.pushViewController(about, animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { about.isShowing })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            HeldRequestProtocol.heldHosts.contains("server-a.held.test")
        })
        h.navigation.popViewController(animated: false)

        // Leaving cancels its load: no error is written, and what the model had stays.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !about.isShowing })
        // The page's own load is still out (every request is held), so what this
        // asks is what the cancel wrote, not whether a page has stopped waiting.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            model.loadError == nil && model.updateStartError == nil
                && model.providerSetupState == .unknown
        }, "a cancelled load wrote nothing")
    }
}

/// An HTTP route that keeps each request on the `*.held.test` hosts waiting until the
/// test answers that host (every request, queued or later, then fails with a 500).
private final class HeldRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [HeldRequestProtocol] = []
    nonisolated(unsafe) private static var answered: Set<String> = []
    nonisolated(unsafe) private static var started: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".held.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let answerNow = Self.lock.withLock {
            Self.started.append(path)
            if Self.answered.contains(host) { return true }
            Self.held.append(self)
            return false
        }
        if answerNow { fail() }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }

    /// Every path a request started for since `reset()`, in order, held or not: a test that
    /// cancels a load can tell one it stopped from one that asked anyway.
    static var startedPaths: [String] {
        lock.withLock { started }
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

    /// The hosts whose requests are waiting now, so a test can tell a load that
    /// asked from one that did not.
    static var heldHosts: Set<String> {
        lock.withLock { Set(held.compactMap { $0.request.url?.host }) }
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
            started = []
        }
    }
}
