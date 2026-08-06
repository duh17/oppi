import Foundation

/// Transport lanes authorized by signed invite metadata.
struct SignedTransportAuthorization: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: UInt8

    static let https = Self(rawValue: 1 << 0)
    static let iroh = Self(rawValue: 1 << 1)
}

enum CredentialTransport: String, Codable, Sendable, Equatable, Hashable {
    case http
    case iroh
}

/// Server-confirmed lanes that one issued device token can authenticate over.
/// A missing persisted value means unknown, not unrestricted.
struct CredentialTransportGrant: OptionSet, Codable, Sendable, Equatable, Hashable {
    let rawValue: UInt8

    static let http = Self(rawValue: 1 << 0)
    static let iroh = Self(rawValue: 1 << 1)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ transports: [CredentialTransport]) {
        self = transports.reduce(into: Self()) { grant, transport in
            switch transport {
            case .http: grant.insert(.http)
            case .iroh: grant.insert(.iroh)
            }
        }
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([CredentialTransport].self))
    }

    func encode(to encoder: Encoder) throws {
        var transports: [CredentialTransport] = []
        if contains(.http) { transports.append(.http) }
        if contains(.iroh) { transports.append(.iroh) }
        var container = encoder.singleValueContainer()
        try container.encode(transports)
    }

    var signedAuthorization: SignedTransportAuthorization {
        var authorization: SignedTransportAuthorization = []
        if contains(.http) { authorization.insert(.https) }
        if contains(.iroh) { authorization.insert(.iroh) }
        return authorization
    }

    static func inferred(from authorization: SignedTransportAuthorization) -> Self {
        var grant: Self = []
        if authorization.contains(.https) { grant.insert(.http) }
        if authorization.contains(.iroh) { grant.insert(.iroh) }
        return grant
    }
}
