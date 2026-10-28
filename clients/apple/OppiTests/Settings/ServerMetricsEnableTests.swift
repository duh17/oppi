import Foundation
import Testing
import UIKit
@testable import Oppi

/// Server Metrics is saved only through `SettingsStore`, from the Metrics page and
/// from Server Settings alike: a fake server route answers the save, and the page,
/// the model, and the connection's cached flag follow what the store settles to.
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

    private func makePage(_ root: AppRootEnvironment) throws -> (ServerMetricsViewController, UIWindow) {
        let page = ServerMetricsViewController(root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return (page, window)
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
        let (page, window) = try makePage(root)
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
        try await turnOn(on: h.page)
    }

    private func turnOn(on page: ServerMetricsViewController) async throws {
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.button(withIdentifier: "server.metrics.turnOn", in: page.view) != nil
        })
        try #require(Self.button(withIdentifier: "server.metrics.turnOn", in: page.view)).sendActions(for: .primaryActionTriggered)
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

    @Test("A change that lands between the page's read and its save is a conflict: reloaded, and the page says so")
    func turnOnConflictReloads() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        // Another device saves (and leaves it off) after the page fetched the document.
        h.transport.beforeNextSave { h.transport.changeElsewhere([:]) }

        try await turnOn(h)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.labels(in: h.page.view).contains("Changed on another device; showing the latest.")
        })
        #expect(h.transport.saves.map(\.baseRevision) == [4])
        #expect(h.transport.loads == 2)
        #expect(h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == false)
    }

    @Test("A change made elsewhere before the tap is fetched first, so the save is not a false conflict")
    func turnOnAfterAChangeElsewhere() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        _ = await h.root.settings.reload(SettingsCatalog.serverMetricsEnabled)
        h.transport.changeElsewhere([:])

        try await turnOn(h)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == true })
        #expect(h.transport.saves.map(\.baseRevision) == [5])
        #expect(!Self.labels(in: h.page.view).contains("Changed on another device; showing the latest."))
    }

    @Test("Turn On from Metrics, off from Server Settings, Turn On from Metrics again: no conflict")
    func metricsThenServerSettingsThenMetrics() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        let coordinator = h.root.coordinator

        try await turnOn(h)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { coordinator.connection(for: serverId)?.serverMetricsEnabled == true })

        // The Server Settings toggle, on the model the SwiftUI view owns.
        let model = ServerSettingsModel()
        model.attach(coordinator: coordinator, serverId: serverId)
        await model.load()
        #expect(model.serverMetricsEnabled == true)
        await model.setServerMetrics(false)
        #expect(model.serverMetricsEnabled == false)
        #expect(model.serverMetricsError == nil)
        #expect(coordinator.connection(for: serverId)?.serverMetricsEnabled == false)

        // Back on the Metrics page, which finds sampling off and turns it on.
        let (again, window) = try makePage(h.root)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await turnOn(on: again)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { coordinator.connection(for: serverId)?.serverMetricsEnabled == true })

        #expect(h.transport.saves.map(\.fields) == [["enabled": true], ["enabled": false], ["enabled": true]])
        #expect(h.transport.saves.map(\.baseRevision) == [4, 5, 6])
        #expect(!Self.labels(in: again.view).contains("Changed on another device; showing the latest."))
    }

    @Test("Server Settings' toggle saves through the store too: a failure rolls back and says why")
    func serverSettingsFailureRollsBack() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        let model = ServerSettingsModel()
        model.attach(coordinator: h.root.coordinator, serverId: serverId)
        await model.load()
        #expect(model.serverMetricsEnabled == false)

        h.transport.failNextSave(with: SettingsTestError())
        await model.setServerMetrics(true)

        #expect(model.serverMetricsEnabled == false)
        #expect(model.serverMetricsError == "The server said no.")
        #expect(h.root.coordinator.connection(for: serverId)?.serverMetricsEnabled == false)
    }
}
