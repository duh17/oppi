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
        let serverId = serverId
        let client = APIClient(baseURL: try #require(URL(string: "https://ready-server.test:7749")), token: "sk_test")
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: client, serverSettings: { id in
            SettingsStore(serverId: id, server: ServerAdapter { _ in transport })
        })
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
        #expect(h.root.coordinator.settings(for: serverId).read(SettingsCatalog.serverMetricsEnabled) == .value(true, revision: 5))
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
        #expect(h.root.coordinator.settings(for: serverId).read(SettingsCatalog.serverMetricsEnabled).current == false)
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
        _ = await h.root.coordinator.settings(for: serverId).reload(SettingsCatalog.serverMetricsEnabled)
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

    // MARK: - Two servers, and the stores' lifecycle

    private struct TwoServers {
        var coordinator: ConnectionCoordinator
        var a: FakeSettingsTransport
        var b: FakeSettingsTransport
    }

    private func makeTwoServers() throws -> TwoServers {
        func server(_ id: String, order: Int) throws -> PairedServer {
            try #require(PairedServer(
                from: ServerCredentials(host: "\(id).test", port: 7749, token: "sk_test", name: id, scheme: .https, serverFingerprint: id),
                sortOrder: order
            ))
        }
        let (serverA, serverB) = (try server("server-a", order: 0), try server("server-b", order: 1))
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([serverA, serverB])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        for paired in [serverA, serverB] {
            coordinator.ensureConnection(for: paired).setAPIClientForTesting(
                APIClient(baseURL: try #require(URL(string: "https://\(paired.id).test:7749")), token: "sk_test")
            )
        }
        let a = FakeSettingsTransport(fields: ["enabled": false], revision: 1)
        let b = FakeSettingsTransport(fields: ["enabled": false], revision: 10)
        coordinator.makeServerSettings = { id in
            SettingsStore(serverId: id, server: ServerAdapter { _ in id == "server-a" ? a : b })
        }
        return TwoServers(coordinator: coordinator, a: a, b: b)
    }

    @Test("Two servers' Server Settings at once: B's save in flight while A loads and saves; each pill cache is its own")
    func twoServersAtOnce() async throws {
        let two = try makeTwoServers()
        let coordinator = two.coordinator
        let modelA = ServerSettingsModel()
        modelA.attach(coordinator: coordinator, serverId: "server-a")
        let modelB = ServerSettingsModel()
        modelB.attach(coordinator: coordinator, serverId: "server-b")
        await modelA.load()
        await modelB.load()
        #expect(modelA.serverMetricsEnabled == false)
        #expect(modelB.serverMetricsEnabled == false)

        let gate = SettingsGate()
        two.b.holdSaves(gate)
        let writeB = Task { await modelB.setServerMetrics(true) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !two.b.saves.isEmpty })

        await modelA.setServerMetrics(true)
        #expect(modelA.serverMetricsEnabled == true)
        #expect(modelA.serverMetricsError == nil)
        #expect(coordinator.connection(for: "server-a")?.serverMetricsEnabled == true)
        // B has not finished: its cache and model still say off.
        #expect(coordinator.connection(for: "server-b")?.serverMetricsEnabled == false)
        #expect(modelB.serverMetricsEnabled == false)

        await gate.open()
        await writeB.value
        #expect(modelB.serverMetricsEnabled == true)
        #expect(modelB.serverMetricsError == nil)
        #expect(coordinator.connection(for: "server-b")?.serverMetricsEnabled == true)
        #expect(coordinator.connection(for: "server-a")?.serverMetricsEnabled == true)

        #expect(two.a.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 1)])
        #expect(two.b.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 10)])
        // Each store holds its own server's document.
        let metrics = SettingsCatalog.serverMetricsEnabled
        #expect(await coordinator.settings(for: "server-a").reload(metrics) == .value(true, revision: 2))
        #expect(await coordinator.settings(for: "server-b").reload(metrics) == .value(true, revision: 11))
    }

    @Test("A server's store is made once, is its own, and is dropped when the server is removed")
    func storeLifecycle() async throws {
        let two = try makeTwoServers()
        let coordinator = two.coordinator
        #expect(!coordinator.hasSettings(for: "server-a"))

        let first = coordinator.settings(for: "server-a")
        #expect(coordinator.settings(for: "server-a") === first)
        #expect(coordinator.settings(for: "server-b") !== first)
        #expect(first.serverId == "server-a")
        #expect(coordinator.deviceSettings.serverId == nil)

        await coordinator.removeServer(id: "server-a")

        #expect(!coordinator.hasSettings(for: "server-a"))
        #expect(coordinator.hasSettings(for: "server-b"))
        #expect(coordinator.settings(for: "server-a") !== first)
    }
}
