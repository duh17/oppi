import MultipeerConnectivity
import Testing
@testable import Oppi

@MainActor
@Suite("NearbyPairingAdvertiser callbacks")
struct NearbyPairingAdvertiserCallbackTests {
    @Test func releasedAdvertiserRejectsLateInvitations() async {
        var advertiser: NearbyPairingAdvertiser? = NearbyPairingAdvertiser()
        let serviceAdvertiser = MCNearbyServiceAdvertiser(
            peer: MCPeerID(displayName: "Mac"),
            discoveryInfo: nil,
            serviceType: NearbyPairingConstants.serviceType
        )
        let peer = MCPeerID(displayName: "Phone")
        var decisions: [Bool] = []
        var returnedSessions: [MCSession?] = []

        advertiser?.advertiser(
            serviceAdvertiser,
            didReceiveInvitationFromPeer: peer,
            withContext: nil
        ) { accepted, session in
            decisions.append(accepted)
            returnedSessions.append(session)
        }
        advertiser = nil
        await Task.yield()
        await Task.yield()

        #expect(decisions == [false])
        #expect(returnedSessions.count == 1)
        #expect((returnedSessions.first ?? nil) == nil)
    }

    @Test func inactiveAdvertiserRejectsLateInvitations() async {
        let advertiser = NearbyPairingAdvertiser()
        let serviceAdvertiser = MCNearbyServiceAdvertiser(
            peer: MCPeerID(displayName: "Mac"),
            discoveryInfo: nil,
            serviceType: NearbyPairingConstants.serviceType
        )
        let peer = MCPeerID(displayName: "Phone")
        var decisions: [Bool] = []
        var returnedSessions: [MCSession?] = []

        advertiser.advertiser(
            serviceAdvertiser,
            didReceiveInvitationFromPeer: peer,
            withContext: nil
        ) { accepted, session in
            decisions.append(accepted)
            returnedSessions.append(session)
        }
        await Task.yield()
        await Task.yield()

        #expect(decisions == [false])
        #expect(returnedSessions.count == 1)
        #expect((returnedSessions.first ?? nil) == nil)
        #expect(advertiser.approvalRequest == nil)
        #expect(advertiser.state == .inactive)
    }
}
