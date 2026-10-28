import Foundation
import Testing
import UIKit
@testable import Oppi

/// Turning Server Metrics on from its page goes through `SettingsStore`: a fake
/// server route answers the save, and the page and the connection's cached flag
/// follow what the store settles to.
@Suite("Server Metrics enable", .serialized)
@MainActor
struct ServerMetricsEnableTests {
    private let serverId = "metrics-enable-server"

    private struct Harness {
        var page: ServerMetricsViewController
        var transport: FakeSettingsTransport
        var root: AppRootEnvironment
        var window: UIWindow
    }

    private func makeHarness(revision: Int? = 4) throws -> Harness {
        let transport = FakeSettingsTransport(fields: ["enabled": false], revision: revision)
        let store = SettingsStore(
            device: DeviceAdapter(defaults: makeSettingsDefaults()),
            server: ServerAdapter { _ in transport }
        )
        let client = APIClient(baseURL: try #require(URL(string: "https://ready-server.test:7749")), token: "sk_test")
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: client, settings: store)
        // Known off: the page shows its Turn On state without asking for history.
        root.coordinator.setServerMetricsEnabledCache(false, for: serverId)
        let page = ServerMetricsViewController(root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return Harness(page: page, transport: transport, root: root, window: window)
    }

    private func hide(_ harness: Harness) {
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    private static func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }

    private static func labels(in view: UIView) -> [String] {
        let own = (view as? UILabel)?.text.map { [$0] } ?? []
        return own + view.subviews.flatMap(labels)
    }

    private func turnOn(_ h: Harness) async throws {
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.button(withIdentifier: "server.metrics.turnOn", in: h.page.view) != nil
        })
        try #require(Self.button(withIdentifier: "server.metrics.turnOn", in: h.page.view)).sendActions(for: .primaryActionTriggered)
    }

    @Test("Turning on saves through the store against the loaded revision and updates the cached flag")
    func turnOnSucceeds() async throws {
        let h = try makeHarness()
        defer { hide(h) }

        try await turnOn(h)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == true })
        #expect(h.transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 4)])
        #expect(h.root.settings.read(SettingsCatalog.serverMetricsEnabled) == .value(true, revision: 5))
    }

    @Test("A failed save rolls back: the flag stays off and the page says why")
    func turnOnFailureRollsBack() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.transport.failNextSave(with: SettingsTestError())

        try await turnOn(h)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.labels(in: h.page.view).contains("The server said no.")
        })
        #expect(h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == false)
        #expect(h.root.settings.read(SettingsCatalog.serverMetricsEnabled).current == false)
    }

    @Test("A revision conflict reloads the server's value, which the page then shows")
    func turnOnConflictReloads() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        // The store already holds the document the page's save will be based on.
        h.root.settings.attach(serverId: serverId)
        _ = await h.root.settings.settled(SettingsCatalog.serverMetricsEnabled)
        // Another device saved (and left it off) after this page loaded.
        h.transport.changeElsewhere([:])

        try await turnOn(h)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.labels(in: h.page.view).contains("Changed on another device; showing the latest.")
        })
        #expect(h.transport.saves.map(\.baseRevision) == [4])
        #expect(h.transport.loads == 2)
        #expect(h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == false)
    }
}
