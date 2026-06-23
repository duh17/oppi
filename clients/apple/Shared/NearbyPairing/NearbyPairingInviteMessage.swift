import Foundation

private enum NearbyPairingMessageType {
    static let inviteURL = "invite-url"
    static let inviteReceived = "invite-received"
}

struct NearbyPairingInviteMessage: Codable, Sendable, Equatable {
    let type: String
    let inviteURL: String

    init(inviteURL: String) {
        self.type = NearbyPairingMessageType.inviteURL
        self.inviteURL = inviteURL
    }
}

struct NearbyPairingAckMessage: Codable, Sendable, Equatable {
    let type: String

    init() {
        self.type = NearbyPairingMessageType.inviteReceived
    }
}

enum NearbyPairingInviteCodec {
    static func encode(inviteURL: String) throws -> Data {
        try JSONEncoder().encode(NearbyPairingInviteMessage(inviteURL: inviteURL))
    }

    static func encodeInviteReceivedAck() throws -> Data {
        try JSONEncoder().encode(NearbyPairingAckMessage())
    }

    static func decodeInviteURL(from data: Data) -> URL? {
        guard let message = try? JSONDecoder().decode(NearbyPairingInviteMessage.self, from: data),
              message.type == NearbyPairingMessageType.inviteURL else {
            return nil
        }

        guard let url = URL(string: message.inviteURL),
              url.scheme?.lowercased() == "oppi" else {
            return nil
        }

        return url
    }

    static func isInviteReceivedAck(_ data: Data) -> Bool {
        guard let message = try? JSONDecoder().decode(NearbyPairingAckMessage.self, from: data) else {
            return false
        }
        return message.type == NearbyPairingMessageType.inviteReceived
    }
}
