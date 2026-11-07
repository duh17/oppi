import Foundation

/// The live-stream renewal exchange (`capabilities.streamAuthRenewal`): `auth_renew` replaces a
/// socket's access token before the server closes it with `4001 auth_expired`. It runs on the
/// app-event, focused session, and dictation streams, outside each stream's own message set.
enum StreamAuthRenewal {
    /// The `auth_renew` text frame carrying `token`.
    static func requestFrame(token: String) throws -> String {
        let data = try JSONEncoder().encode(Request(token: token))
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(token, .init(codingPath: [], debugDescription: "auth_renew is not UTF-8"))
        }
        return text
    }

    private struct Request: Encodable {
        let type = "auth_renew"
        let token: String
    }
}

/// `auth_renew_result`: the server's answer to this socket's `auth_renew`.
enum StreamAuthRenewResult: Sendable, Equatable {
    /// The socket now runs until this token expiry; the server closes it 30 s after.
    case renewed(expiresAt: Date)
    /// Nothing changed: the socket still closes at its old deadline.
    case refused(reason: String)

    /// Refusals a newer token cannot fix: the socket is not a renewable device socket, or it is
    /// already past its deadline. Its own close handling takes over.
    var isFinal: Bool {
        guard case .refused(let reason) = self else { return false }
        return reason == "not_renewable" || reason == "past_deadline"
    }
}

extension StreamAuthRenewResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case ok, expiresAt, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(Bool.self, forKey: .ok) {
            let expiresAtMs = try c.decode(Int64.self, forKey: .expiresAt)
            self = .renewed(expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1_000))
        } else {
            self = .refused(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}
