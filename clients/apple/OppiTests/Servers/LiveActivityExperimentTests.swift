import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Live Activity experiment (Settings → Experiments) gates every server's card: while
/// it is off, Server Settings shows no card switch, each server's card reads off, and each
/// connected server with push on is registered again so it learns this phone shows none.
/// Turning it on brings each server's saved choice back. Runs on the app's own device
/// store over `UserDefaults.standard`, as the app does, and restores what it changed.
@Suite("Live Activity experiment", .serialized)
@MainActor
struct LiveActivityExperimentTests {
    private let pushServer = "sha256:live-activity-push"
    private let quietServer = "sha256:live-activity-quiet"
    private let relay = URL(string: "https://relay.example")!

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: AppPreferenceStore.Experiments.liveActivityKey)
        for id in [pushServer, quietServer] {
            LiveActivitySettings.setEnabled(false, serverId: id)
            PushRegistration.setEnabled(false, serverId: id)
        }
        PushRegistration.shared._onRegisterForTesting = nil
    }

    private func makeRoot() async throws -> AppRootEnvironment {
        // The app's own refreshes once a server is connected answer as an unreachable server does.
        try await makeTestAppRoot(readyServers: [
            TestReadyServer(id: pushServer, client: makeTestURLProtocolClient(host: "ready-server.test")),
            TestReadyServer(id: quietServer, name: "Quiet", host: "quiet.test", client: makeTestURLProtocolClient(host: "quiet.test")),
        ])
    }

    private func setExperiment(_ on: Bool, in root: AppRootEnvironment) async {
        _ = await root.coordinator.deviceSettings.set(SettingsCatalog.experimentLiveActivity, on).value
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

    private func show(_ server: String, root: AppRootEnvironment) throws -> (ServerSettingsViewController, UIWindow) {
        let page = ServerSettingsViewController(server: try #require(root.coordinator.serverStore.server(for: server)), root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3000)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return (page, window)
    }

    @Test("Server Settings shows the card switch only while the experiment is on, with the saved choice")
    func switchFollowsTheExperiment() async throws {
        cleanUp()
        defer { cleanUp() }
        // The page's own server settings answer as a server that refuses them: not this test's subject.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard let url = request.url,
                  ["/server/durable-sessions/settings", "/server/mobile-output-guide"].contains(url.path),
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
            else { return nil }
            return (Data(#"{"error":"not_found"}"#.utf8), response)
        })
        defer { routes.end() }
        let root = try await makeRoot()
        // Turned on before the experiment hid it.
        LiveActivitySettings.setEnabled(true, serverId: quietServer)
        let id = "server.liveActivity.enabled"

        let (hidden, hiddenWindow) = try show(quietServer, root: root)
        // Drawn: the Lock Server switch, a few rows below where the card's would be.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            hidden.view.layoutIfNeeded()
            return Self.toggle("server.lock", in: hidden.view) != nil
        })
        #expect(Self.toggle(id, in: hidden.view) == nil)
        hiddenWindow.isHidden = true
        hiddenWindow.rootViewController = nil

        await setExperiment(true, in: root)
        let (page, window) = try show(quietServer, root: root)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.toggle(id, in: page.view)?.isOn == true
        })

        // Off again with the page open: the switch goes at once, and the choice is kept.
        await setExperiment(false, in: root)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.toggle(id, in: page.view) == nil
        })
        #expect(!LiveActivitySettings.isEnabled(serverId: quietServer))
        await setExperiment(true, in: root)
        #expect(LiveActivitySettings.isEnabled(serverId: quietServer))
    }

    @Test("Flipping the experiment registers each connected server with push on again, with the card it now shows")
    func flipRegistersPushServersAgain() async throws {
        cleanUp()
        defer { cleanUp() }
        let root = try await makeRoot()
        for id in [pushServer, quietServer] {
            LiveActivitySettings.setEnabled(true, serverId: id)
            try #require(root.coordinator.connection(for: id)).setSplitStreamCapabilitiesForTesting(pushRelay: relay)
        }
        PushRegistration.setEnabled(true, serverId: pushServer)
        var registered: [(server: String?, card: Bool)] = []
        PushRegistration.shared._onRegisterForTesting = { id in
            // What `PushRegistration` sends the server as `liveActivity`.
            registered.append((id, id.map { LiveActivitySettings.isEnabled(serverId: $0) } ?? false))
        }

        await setExperiment(true, in: root)
        await setExperiment(false, in: root)
        await setExperiment(true, in: root)

        // The server with push off is never registered; the other hears each change.
        #expect(registered.map(\.server) == [pushServer, pushServer, pushServer])
        #expect(registered.map(\.card) == [true, false, true])
    }
}
