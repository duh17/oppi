import Foundation
import Testing
import UIKit
@testable import Oppi

/// Usage is pinned to one server and driven by its own controls; the route replaces the
/// page when the visible server changes.
@Suite("Usage page", .serialized)
@MainActor
struct UsagePageTests {
    private func makeServer(_ id: String, order: Int) throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: "\(id).usage.test", port: 7749, token: "sk_test", name: id, scheme: .https, serverFingerprint: id),
            sortOrder: order
        ))
    }

    private func makeRoot(servers: [PairedServer]) throws -> AppRootEnvironment {
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageRefusingProtocol.self]
        for server in servers {
            coordinator.ensureConnection(for: server).setAPIClientForTesting(APIClient(
                baseURL: try #require(URL(string: "https://\(server.id).usage.test:7749")),
                token: "sk_test",
                configuration: configuration
            ))
        }
        if let first = servers.first { #expect(coordinator.restoreActiveServer(first.id)) }
        return makeTestAppRoot(coordinator: coordinator)
    }

    private func present(_ screen: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        screen.view.layoutIfNeeded()
        return window
    }

    private static func control<T: UIView>(_ type: T.Type, id: String, in view: UIView) -> T? {
        if let match = view as? T, match.accessibilityIdentifier == id { return match }
        for subview in view.subviews {
            if let found = control(type, id: id, in: subview) { return found }
        }
        return nil
    }

    private func stats() -> ServerStats {
        ServerStats(
            memory: StatsMemory(heapUsed: 0, heapTotal: 0, rss: 0, external: 0),
            activeSessions: [],
            daily: [StatsDailyEntry(date: "2026-10-27", sessions: 4, cost: 2.5, tokens: 1_200, byModel: nil)],
            modelBreakdown: [],
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: 4, cost: 2.5, tokens: 1_200)
        )
    }

    @Test("The range control and the totals pick the range and the metric of the pinned model")
    func controlsDriveTheModel() async throws {
        let server = try makeServer("server-a", order: 0)
        let root = try makeRoot(servers: [server])
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(), .month: stats()]
        let model = UsageModel(serverId: server.id) { client }
        let page = UsageViewController(server: server, root: root, model: model)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.stats != nil })
        page.view.layoutIfNeeded()

        let range = try #require(Self.control(UISegmentedControl.self, id: "server.usage.range", in: page.view))
        #expect(range.selectedSegmentIndex == UsageRange.allCases.firstIndex(of: .week))
        range.selectedSegmentIndex = UsageRange.allCases.firstIndex(of: .month) ?? 0
        range.sendActions(for: .valueChanged)
        #expect(model.range == .month)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.stats != nil && !model.isLoading })

        page.view.layoutIfNeeded()
        let tokens = try #require(Self.control(UIControl.self, id: "server.usage.metric.tokens", in: page.view))
        tokens.sendActions(for: .touchUpInside)
        #expect(model.metric == .tokens)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.control(UIControl.self, id: "server.usage.metric.tokens", in: page.view)?
                .accessibilityTraits.contains(.selected) == true
        })
        #expect(client.requestedRanges == [.week, .month])
    }

    @Test("With no provider signed in the page offers setup, which opens Model Providers of its own server")
    func providerSetupOpensTheServersProviders() async throws {
        let server = try makeServer("server-a", order: 0)
        let other = try makeServer("server-b", order: 1)
        let root = try makeRoot(servers: [server, other])
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats()]
        client.providers = [
            ProviderAuthProviderStatus(
                id: "p", name: "p", supportsApiKey: true, oauth: nil, authenticated: false, credentialType: nil,
                expiresAt: nil, maskedKey: nil
            ),
        ]
        let model = UsageModel(serverId: server.id) { client }
        let page = UsageViewController(server: other, root: root, model: model)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.showsProviderSetup })
        page.view.layoutIfNeeded()

        let button = try #require(Self.control(UIButton.self, id: "server.providerSetup.open", in: page.view))
        button.sendActions(for: .touchUpInside)

        // The page is pinned to `other`: its setup opens that server's providers.
        let opened = root.navigation.workspaceStackRouteElements.last
        guard case .modelProviders(let target)? = opened else {
            Issue.record("Model Providers did not open: \(String(describing: opened))")
            return
        }
        #expect(target.serverId == other.id)
    }

    private func hourlyDetail(cost: Double) -> DailyDetail {
        DailyDetail(
            date: "2026-10-26",
            totals: StatsTotals(sessions: 1, cost: cost, tokens: 10),
            hourly: [StatsDailyHourlyEntry(
                hour: 9, sessions: 1, cost: cost, tokens: 10,
                byModel: ["anthropic/claude-sonnet-5-5": DailyModelEntry(sessions: 1, cost: cost, tokens: 10)]
            )],
            sessions: []
        )
    }

    @Test("A day reopened after a pull draws its hourly chart again, with the new spend")
    func hourlyChartRedrawsAfterAPull() async throws {
        let server = try makeServer("server-a", order: 0)
        let root = try makeRoot(servers: [server])
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats()]
        client.details = ["2026-10-26": hourlyDetail(cost: 1)]
        let model = UsageModel(serverId: server.id) { client }
        let page = UsageViewController(server: server, root: root, model: model)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.stats != nil })

        model.selectDay("2026-10-26")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.hourlyChartBuilds == 1 })

        // A pull forgets the open day; the server now has more spend in the hour already drawn.
        await model.refresh()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { model.detail == nil })
        client.details = ["2026-10-26": hourlyDetail(cost: 2.5)]
        model.selectDay("2026-10-26")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.hourlyChartBuilds == 2 })
    }

    @Test("The hourly chart's key changes with the spend in an hour already drawn, not only with the hour count")
    func hourlyKeyFollowsSpend() {
        let before = UsageViewController.hourlyChartKey(hourlyDetail(cost: 1), themeKey: "dark")
        #expect(before == UsageViewController.hourlyChartKey(hourlyDetail(cost: 1), themeKey: "dark"))
        #expect(before != UsageViewController.hourlyChartKey(hourlyDetail(cost: 2.5), themeKey: "dark"))
        #expect(before != UsageViewController.hourlyChartKey(hourlyDetail(cost: 1), themeKey: "light"))
    }

    @Test("A switch replaces the page with the new server's own, and the old page's late answer stays there")
    func routeReplacesThePage() async throws {
        let servers = [try makeServer("server-a", order: 0), try makeServer("server-b", order: 1)]
        let root = try makeRoot(servers: servers)
        let route = UsageRouteViewController(root: root)
        let window = try present(route)
        defer { window.isHidden = true; window.rootViewController = nil }

        let first = try #require(route.page)
        #expect(route.pinnedServerId == "server-a")
        #expect(first.model.serverId == "server-a")

        _ = root.coordinator.restoreActiveServer("server-b")

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { route.pinnedServerId == "server-b" })
        let second = try #require(route.page)
        #expect(second !== first)
        #expect(second.model !== first.model)
        #expect(second.model.serverId == "server-b")
        #expect(first.parent == nil)
        #expect(route.children == [second])
    }

    @Test("With no server paired the route offers Add Server instead of a page")
    func noServers() throws {
        let root = try makeRoot(servers: [])
        let route = UsageRouteViewController(root: root)
        let window = try present(route)
        defer { window.isHidden = true; window.rootViewController = nil }

        #expect(route.page == nil)
        #expect(route.contentUnavailableConfiguration != nil)
    }
}

/// Answers every request on a `*.usage.test` host with a refusal, so a page's own loads end.
private final class UsageRefusingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".usage.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(#"{"error":"refused"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
