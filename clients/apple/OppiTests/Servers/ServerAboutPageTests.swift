import Foundation
import Testing
import UIKit
@testable import Oppi

/// About This Server's update rows follow what the server reports.
@Suite("About This Server page", .serialized)
@MainActor
struct ServerAboutPageTests {
    // MARK: - About: which update rows show

    private typealias About = ServerAboutViewController

    private func update(
        kind: String = "npm-global",
        available: Bool = false,
        status: String = "idle",
        error: String? = nil,
        latest: String? = "9.9.9"
    ) -> ServerInfo.UpdateInfo {
        ServerInfo.UpdateInfo(
            installKind: kind,
            latestVersion: latest,
            available: available,
            manualCommand: "npm install -g oppi-server@latest",
            status: status,
            error: error,
            restartMode: "automatic"
        )
    }

    private func rows(
        _ update: ServerInfo.UpdateInfo?,
        belowMinimum: Bool = false,
        inFlight: Bool = false,
        didNotReturn: Bool = false
    ) -> [About.Item] {
        About.updateItems(update: update, belowMinimum: belowMinimum, inFlight: inFlight, didNotReturn: didNotReturn)
    }

    @Test("Nothing to say hides the Update section")
    func idleServerHidesTheSection() {
        #expect(rows(nil).isEmpty)
        #expect(rows(update()).isEmpty)
    }

    @Test("An update, or a rebuild of a linked checkout, offers its button under its headline")
    func availableUpdateOffersTheButton() {
        #expect(rows(update(available: true)) == [.updateAvailable, .updateButton])
        #expect(rows(update(kind: "source-link", available: true)) == [.updateAvailable, .updateButton])
        // Nothing newer is named, so there is no headline, only the button.
        #expect(rows(update(available: true, latest: nil)) == [.updateButton])
    }

    @Test("While the server installs or restarts only its progress shows; a started update leaves its button, which the page disables")
    func progressHidesTheButton() {
        #expect(rows(update(available: true, status: "installing")) == [.updateProgress])
        #expect(rows(update(available: true, status: "restarting")) == [.updateProgress])
        #expect(rows(update(available: true), inFlight: true) == [.updateProgress, .updateAvailable, .updateButton])
    }

    @Test("A restart the server needs, or a failure it reports, is said before the button")
    func restartAndFailure() {
        #expect(rows(update(available: true, status: "restart-needed")) == [.updateRestartNeeded])
        #expect(rows(update(available: true, status: "failed", error: "npm said no")) == [.updateError, .updateAvailable, .updateButton])
        // A failure with no message has nothing to show.
        #expect(rows(update(status: "failed")).isEmpty)
    }

    @Test("A server that did not come back says only that")
    func didNotReturnSaysOnlyThat() {
        #expect(rows(update(available: true), didNotReturn: true) == [.updateDidNotReturn])
        #expect(rows(nil, didNotReturn: true) == [.updateDidNotReturn])
    }

    @Test("An install the app cannot update shows the command to run by hand")
    func manualInstallShowsTheCommand() {
        #expect(rows(update(kind: "manual")) == [.manualCommand, .manualCopy])
        #expect(rows(update(kind: "managed", available: true)) == [.manualCommand, .manualCopy])
    }

    @Test("A server older than the app says so, with the way to fix it")
    func belowMinimum() {
        #expect(rows(nil, belowMinimum: true) == [.minimumVersion, .manualCommand, .manualCopy])
        #expect(rows(update(available: true), belowMinimum: true) == [.minimumVersion, .updateAvailable, .updateButton])
        // The notice waits while the update that would clear it runs.
        #expect(rows(update(available: true, status: "installing"), belowMinimum: true) == [.updateProgress])
    }

    // MARK: - About: the page

    private func present(_ page: UIViewController, height: CGFloat = 1600) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        return window
    }

    private func makeServer() throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: "about.test", port: 7749, token: "sk_test", name: "about", scheme: .https, serverFingerprint: "about-server"),
            sortOrder: 0
        ))
    }

    @Test("The page lists the server's facts and voice backends and, for an available update, its headline and button")
    func pageShowsFactsAndUpdate() async throws {
        let server = try makeServer()
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([server])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let root = makeTestAppRoot(coordinator: coordinator)
        let model = ServerSettingsModel.screenshotFixture(coordinator: coordinator, serverId: server.id, currentDeviceId: "dev", updateAvailable: true)
        let page = About(model: model, server: server, root: root)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }

        #expect(page.items(in: .status) == [.connection, .uptime, .piSDK, .piTUI, .oppiServer])
        #expect(page.items(in: .update) == [.updateAvailable, .updateButton])
        #expect(page.items(in: .voice) == [.voice("dictation"), .voice("readAloud"), .voice("liveVoice")])
        #expect(page.title == "About This Server")
        #expect(page.collectionView.accessibilityIdentifier == "server.about.list")
        // The "Server" row is "Oppi Server".
        #expect(Self.texts(in: page.view).contains("Oppi Server"))
        #expect(Self.texts(in: page.view).contains("Update available: 1.5.0"))
    }

    @Test("An update the server refuses to start says so in its own row, not the load's")
    func refusedUpdateShowsItsOwnRow() async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            if request.httpMethod == "POST", request.url?.path.hasSuffix("/server/update") == true {
                return try mockJSONResponse(status: 500, json: #"{"error":"npm is busy"}"#, for: request)
            }
            return nil
        })
        defer { routes.end() }
        let serverId = "about-update-server"
        let root = try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "about-update.test")
        )
        let server = try #require(root.coordinator.serverStore.server(for: serverId))
        let model = ServerSettingsModel.screenshotFixture(
            coordinator: root.coordinator, serverId: serverId, currentDeviceId: "dev", updateAvailable: true
        )
        let page = About(model: model, server: server, root: root)
        let window = try present(page)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(!page.items(in: .status).contains(.updateStartError))

        await model.startServerUpdate()

        // The page loaded fine: the refusal is the update's, and it has its own row.
        #expect(model.updateStartError == "npm is busy")
        #expect(model.loadError == nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.items(in: .status).first == .updateStartError
        }, "the refused update is the first thing the status section says")
        #expect(Self.texts(in: page.view).contains("Couldn't Start the Update"))
        #expect(!page.items(in: .update).contains(.updateProgress), "nothing says an update is running")
    }

    private static func texts(in view: UIView) -> [String] {
        var found: [String] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text { found.append(text) }
            if let content = (view as? UIContentView)?.configuration as? UIListContentConfiguration {
                found.append(contentsOf: [content.text, content.secondaryText].compactMap { $0 })
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}
