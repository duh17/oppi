import Foundation
import Testing
@testable import Oppi

@Suite("NearbyPairingInviteCodec")
struct NearbyPairingInviteCodecTests {
    @Test func roundTripsOppiInviteURL() throws {
        let inviteURL = "oppi://connect?v=3&invite=test-payload"

        let data = try NearbyPairingInviteCodec.encode(inviteURL: inviteURL)
        let decodedURL = try #require(NearbyPairingInviteCodec.decodeInviteURL(from: data))

        #expect(decodedURL.absoluteString == inviteURL)
    }

    @Test func rejectsNonOppiURL() {
        let data = Data(#"{"type":"invite-url","inviteURL":"https://example.com"}"#.utf8)

        #expect(NearbyPairingInviteCodec.decodeInviteURL(from: data) == nil)
    }

    @Test func rejectsUnknownMessageType() {
        let data = Data(#"{"type":"other","inviteURL":"oppi://connect?v=3&invite=test-payload"}"#.utf8)

        #expect(NearbyPairingInviteCodec.decodeInviteURL(from: data) == nil)
    }
}
