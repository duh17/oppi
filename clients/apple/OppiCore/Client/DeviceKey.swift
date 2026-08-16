import CryptoKit
import Foundation

/// Canonical P-256 device public key (JWK, RFC 7517 §6), matching the server's
/// `DevicePublicKey` encoding. `x`/`y` are unpadded base64url.
public struct DevicePublicKey: Codable, Sendable, Equatable, Hashable {
    public let kty: String
    public let crv: String
    public let x: String
    public let y: String

    public init(x: String, y: String) {
        self.kty = "EC"
        self.crv = "P-256"
        self.x = x
        self.y = y
    }

    /// Derive the JWK coordinates from a 65-byte x963 uncompressed point.
    /// Fails closed on malformed input rather than silently producing an
    /// invalid public key that would strand the server-side identity.
    public static func publicKey(fromRaw raw: Data) -> DevicePublicKey? {
        guard raw.count == 65, raw.first == 0x04 else { return nil }
        return DevicePublicKey(
            x: DeviceKeyBase64.encode(Data(raw[1..<33])),
            y: DeviceKeyBase64.encode(Data(raw[33..<65]))
        )
    }
}

/// A device signing key. Production uses Secure Enclave; tests and fallbacks use
/// an in-memory key. Signatures are raw 64-byte ECDSA P-256 `r || s`.
public protocol DeviceKey: Sendable {
    var publicKey: DevicePublicKey { get }
    func sign(_ data: Data) throws -> Data
}

/// In-memory P-256 key for tests and the non-Enclave fallback path.
public struct InMemoryP256DeviceKey: DeviceKey {
    private let privateKey: P256.Signing.PrivateKey
    public let publicKey: DevicePublicKey

    public init() {
        let key = P256.Signing.PrivateKey()
        self.privateKey = key
        guard let publicKey = DevicePublicKey.publicKey(fromRaw: key.publicKey.x963Representation) else {
            preconditionFailure("P-256 public key raw representation is always 65 bytes")
        }
        self.publicKey = publicKey
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}

enum DeviceKeyBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
