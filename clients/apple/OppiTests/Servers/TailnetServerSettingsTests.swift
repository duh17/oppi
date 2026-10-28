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
    func opensThePeersServerNotTheActiveOne() throws {
        let active = try makeServer("mac-a.tail1234.ts.net", order: 0)
        let peerServer = try makeServer("mac-b.tail1234.ts.net", order: 1)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([active, peerServer])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        for server in [active, peerServer] { coordinator.ensureConnection(for: server) }
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

    @Test("In a sheet the Paired row is only a status: it switches nothing and opens nothing")
    func pairedRowInASheetHasNoAction() throws {
        let paired = try makeServer("mac-b.tail1234.ts.net", order: 0)
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([paired])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        coordinator.ensureConnection(for: paired)
        let peer = TailnetPeer(
            id: "peer-b", hostName: "mac-b", dnsName: "mac-b.tail1234.ts.net", os: "macOS",
            tailscaleIPs: ["100.64.0.2"], isOnline: true
        )

        let inSheet = TailnetSettingsViewController(coordinator: coordinator, onClose: {})
        let inStack = TailnetSettingsViewController(coordinator: coordinator)

        #expect(inSheet.peerRow(peer).rowAction == nil)
        #expect(inStack.peerRow(peer).rowAction?.0 == "tailnet.paired.peer-b")
    }
}
