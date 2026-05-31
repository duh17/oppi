import Foundation

struct NearbyPairingInviteMessage: Codable, Sendable, Equatable {
    let type: String
    let inviteURL: String

    init(inviteURL: String) {
        self.type = "invite-url"
        self.inviteURL = inviteURL
    }
}

enum NearbyPairingInviteCodec {
    static func encode(inviteURL: String) throws -> Data {
        try JSONEncoder().encode(NearbyPairingInviteMessage(inviteURL: inviteURL))
    }

    static func decodeInviteURL(from data: Data) -> URL? {
        guard let message = try? JSONDecoder().decode(NearbyPairingInviteMessage.self, from: data),
              message.type == "invite-url" else {
            return nil
        }

        guard let url = URL(string: message.inviteURL),
              url.scheme?.lowercased() == "oppi" else {
            return nil
        }

        return url
    }
}
