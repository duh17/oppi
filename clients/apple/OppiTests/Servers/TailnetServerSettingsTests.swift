import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tailscale's paired-peer row opens Server Settings for that peer's server.
@Suite("Tailscale peer opens its server's settings")
@MainActor
struct TailnetServerSettingsTests {
    private func makeServer(_ host: String, order: Int) throws -> PairedServer {
        try #require(PairedServer(
            from: ServerCredentials(host: host, port: 7749, token: "sk_test", name: host, scheme: .https, serverFingerprint: host),
            sortOrder: order
        ))
    }

    @Test("The peer's server becomes the active one before Server Settings opens, so it never shows the active server's")
    func opensThePeersServerNotTheActiveOne() async throws {
        let active = try makeServer("mac-a.tail1234.ts.net", order: 0)
        let peerServer = try makeServer("mac-b.tail1234.ts.net", order: 1)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([active, peerServer])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        for server in [active, peerServer] { await coordinator.ensureTestConnectionReady(for: server) }
        #expect(coordinator.restoreActiveServer(active.id))
        let root = makeTestAppRoot(coordinator: coordinator)
        let page = TailnetSettingsViewController(coordinator: coordinator)
        page.traitOverrides.appRootEnvironment = root
        let peer = TailnetPeer(
            id: "peer-b", hostName: "mac-b", dnsName: "mac-b.tail1234.ts.net", os: "macOS",
            tailscaleIPs: ["100.64.0.2"], isOnline: true
        )

        page.openServerSettings(for: peer)

        #expect(coordinator.activeServerId == peerServer.id)
        #expect(root.navigation.workspaceStackRouteElements.last == .serverDetails(ServerDetailsNavTarget(serverId: peerServer.id)))
    }

    @Test("From App Settings the Paired row opens Server Settings; in a sheet it is only a status")
    func pairedRowOpensOnlyOutsideASheet() async throws {
        let paired = try makeServer("mac-b.tail1234.ts.net", order: 0)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([paired])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        await coordinator.ensureTestConnectionReady(for: paired)
        let peer = TailnetPeer(
            id: "peer-b", hostName: "mac-b", dnsName: "mac-b.tail1234.ts.net", os: "macOS",
            tailscaleIPs: ["100.64.0.2"], isOnline: true
        )
        TailnetNodeController.shared.applyPreviewSnapshot(TailnetStatusSnapshot(
            backendState: .running, authURL: nil, selfDNSName: "oppi-ios.tail1234.ts.net", tailnetName: nil, peers: [peer]
        ))
        defer {
            TailnetNodeController.shared.applyPreviewSnapshot(TailnetStatusSnapshot(
                backendState: .noState, authURL: nil, selfDNSName: nil, tailnetName: nil, peers: []
            ))
        }

        let fromSettings = try show(TailnetSettingsViewController(coordinator: coordinator))
        defer { fromSettings.window.isHidden = true; fromSettings.window.rootViewController = nil }
        let inSheet = try show(TailnetSettingsViewController(coordinator: coordinator, onClose: {}))
        defer { inSheet.window.isHidden = true; inSheet.window.rootViewController = nil }

        // Both lists draw the peer's row; only the one outside a sheet makes it open something.
        for shown in [fromSettings, inSheet] {
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                shown.page.view.layoutIfNeeded()
                return Self.hasText("mac-b", in: shown.page.view)
            })
        }
        #expect(Self.pairedRowButton("tailnet.paired.peer-b", in: fromSettings.page.view) != nil)
        #expect(Self.pairedRowButton("tailnet.paired.peer-b", in: inSheet.page.view) == nil)
    }

    private func show(_ page: TailnetSettingsViewController) throws -> (page: TailnetSettingsViewController, window: UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        return (page, window)
    }

    /// The row's tap overlay, which only a row that opens something shows.
    private static func pairedRowButton(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier, !button.isHidden { return button }
        for subview in view.subviews {
            if let found = pairedRowButton(identifier, in: subview) { return found }
        }
        return nil
    }

    private static func hasText(_ text: String, in view: UIView) -> Bool {
        if (view as? UILabel)?.text == text { return true }
        return view.subviews.contains { hasText(text, in: $0) }
    }
}
