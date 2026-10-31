import Foundation
import Testing
import UIKit
@testable import Oppi

/// Server Settings' Durable Sessions switch writes the server's setting through its
/// `SettingsStore`: a fake route answers the save, and the connection's
/// `durableSessions` capability (which shows Quick Session's engine switch) follows what
/// the store settles to. Start Sessions as Durable is this device's, shown while it is on.
@Suite("Durable Sessions setting", .serialized)
@MainActor
struct DurableSessionsSettingTests {
    private let serverId = "durable-setting-server"

    @MainActor
    private struct Harness {
        var page: ServerSettingsViewController
        var transport: FakeSettingsTransport
        var root: AppRootEnvironment
        var defaults: UserDefaults
        var window: UIWindow

        var connection: ServerConnection? { root.coordinator.connection(for: page.server.id) }
        var store: SettingsStore { root.coordinator.settings(for: page.server.id) }
    }

    private func makeHarness() throws -> Harness {
        // The app's own refreshes once a server is connected are not what these tests are
        // about; they answer as an unreachable server does, and anything else fails.
        TestURLProtocol.handler = mockUnreachableBackgroundRoutes()
        let transport = FakeSettingsTransport(fields: ["enabled": false], revision: 4)
        let client = makeTestURLProtocolClient(host: "ready-server.test")
        let defaults = makeSettingsDefaults()
        let deviceStore = SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil })
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: client, settings: deviceStore)
        let coordinator = root.coordinator
        coordinator.makeServerSettings = { [unowned coordinator] id in
            SettingsStore(
                serverId: id,
                server: ServerAdapter { _ in transport },
                afterWrite: SettingsStore.liveServerAfterWrite(serverId: id, coordinator: coordinator)
            )
        }
        // The server's /server/info said it offers no durable sessions.
        try #require(coordinator.connection(for: serverId)).setSplitStreamCapabilitiesForTesting(durableSessions: false)

        let server = try #require(coordinator.serverStore.server(for: serverId))
        let page = ServerSettingsViewController(server: server, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3000)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return Harness(page: page, transport: transport, root: root, defaults: defaults, window: window)
    }

    private func hide(_ h: Harness) {
        h.window.isHidden = true
        h.window.rootViewController = nil
    }

    /// The switch on screen: a removed row's cell stays in the list as a hidden, reusable view.
    private static func toggle(_ id: String, in view: UIView) -> UISwitch? {
        guard !view.isHidden else { return nil }
        if let toggle = view as? UISwitch, toggle.accessibilityIdentifier == id { return toggle }
        for subview in view.subviews {
            if let found = toggle(id, in: subview) { return found }
        }
        return nil
    }

    private static func labels(in view: UIView) -> [String] {
        let own = (view as? UILabel)?.text.map { [$0] } ?? []
        return own + view.subviews.flatMap(labels)
    }

    /// Flips a switch as a finger would, once it is drawn and enabled.
    private func flip(_ id: String, on page: UIViewController, to isOn: Bool) async throws {
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.toggle(id, in: page.view)?.isEnabled == true
        })
        let toggle = try #require(Self.toggle(id, in: page.view))
        toggle.isOn = isOn
        toggle.sendActions(for: .valueChanged)
    }

    private let serverSwitch = SettingsCatalog.durableSessionsEnabled.id
    private let deviceSwitch = SettingsCatalog.startSessionsAsDurable.id

    @Test("Turning it on saves the server's setting, offers durable sessions, and shows this device's default")
    func turnOnWritesTheServerSetting() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(h.connection?.durableSessionsAvailable == false)

        try await flip(serverSwitch, on: h.page, to: true)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.connection?.durableSessionsAvailable == true })
        #expect(h.transport.saves == [.init(endpoint: .durableSessions, fields: ["enabled": true], baseRevision: 4)])
        #expect(h.store.read(SettingsCatalog.durableSessionsEnabled) == .value(true, revision: 5))

        // Start Sessions as Durable appears under it and saves on this device only.
        try await flip(deviceSwitch, on: h.page, to: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.defaults.bool(forKey: AppPreferenceStore.DurableSessions.startDurableKey)
        })
        #expect(h.transport.saves.count == 1)

        // Off again: the server stops offering durable sessions and the device row goes.
        try await flip(serverSwitch, on: h.page, to: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { h.connection?.durableSessionsAvailable == false })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.toggle(deviceSwitch, in: h.page.view) == nil
        })
        #expect(h.transport.saves.map(\.baseRevision) == [4, 5])
    }

    @Test("A failed save puts the switch back, says why, and leaves durable sessions off")
    func failedSaveRollsBack() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        h.transport.failNextSave(with: SettingsTestError())

        try await flip(serverSwitch, on: h.page, to: true)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.labels(in: h.page.view).contains("The server said no.")
        })
        #expect(Self.toggle(serverSwitch, in: h.page.view)?.isOn == false)
        // The device row showed while the save was in flight and leaves with the rollback.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.toggle(deviceSwitch, in: h.page.view) == nil
        })
        #expect(h.connection?.durableSessionsAvailable == false)
    }

    @Test("A 409 conflict reloads the server's value, says so, and the capability follows it")
    func conflictReloads() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        // Another device turns it on after this page loaded; this save is against the old revision.
        h.transport.beforeNextSave { h.transport.changeElsewhere(["enabled": true]) }

        try await flip(serverSwitch, on: h.page, to: true)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            h.page.view.layoutIfNeeded()
            return Self.labels(in: h.page.view).contains("Changed on another device; showing the latest.")
        })
        // The save itself was refused, so only the conflict's reload can have moved these.
        #expect(h.transport.saves.map(\.baseRevision) == [4])
        #expect(h.store.read(SettingsCatalog.durableSessionsEnabled).current == true)
        #expect(h.connection?.durableSessionsAvailable == true)
    }
}
