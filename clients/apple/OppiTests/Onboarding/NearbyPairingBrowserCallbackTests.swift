import Foundation
import MultipeerConnectivity
import Testing
@testable import Oppi

@MainActor
@Suite("NearbyPairingBrowser callbacks")
struct NearbyPairingBrowserCallbackTests {
    @Test func inactiveBrowserIgnoresLateInviteData() async throws {
        let browser = NearbyPairingBrowser()
        let staleSession = MCSession(peer: MCPeerID(displayName: "Phone"))
        let peer = MCPeerID(displayName: "Mac")
        let data = try NearbyPairingInviteCodec.encode(inviteURL: "oppi://pair?token=late")
        var receivedURLs: [URL] = []
        browser.onInviteURL = { receivedURLs.append($0) }

        browser.session(staleSession, didReceive: data, fromPeer: peer)
        await Task.yield()
        await Task.yield()

        #expect(receivedURLs.isEmpty)
        #expect(browser.state == .idle)
    }

    @Test func inactiveBrowserIgnoresLateInvalidInviteData() async {
        let browser = NearbyPairingBrowser()
        let staleSession = MCSession(peer: MCPeerID(displayName: "Phone"))
        let peer = MCPeerID(displayName: "Mac")

        browser.session(staleSession, didReceive: Data("not an invite".utf8), fromPeer: peer)
        await Task.yield()
        await Task.yield()

        #expect(browser.state == .idle)
    }
}
