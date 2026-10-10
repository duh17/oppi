import CryptoKit
import Foundation

/// Bytes the device key signs for `PUT /me/push-registration` (spec §5), so a proxy on the
/// paired channel cannot swap the push key or the send token.
enum PushRegistrationSignature {
    static func message(
        deviceId: String,
        serverFingerprint: String,
        keyId: String,
        publicKey: Data,
        sendToken: String,
        relay: String,
        issuedAt: Int64
    ) -> Data {
        let lines = [
            "oppi-push-registration-v1",
            deviceId,
            serverFingerprint,
            keyId,
            Data(SHA256.hash(data: publicKey)).base64URLEncodedPushString,
            Data(SHA256.hash(data: Data(sendToken.utf8))).base64URLEncodedPushString,
            relay,
            String(issuedAt),
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// `sha256:<base64url SHA-256(raw Ed25519 key)>`, the form the app pins at pairing.
    static func serverFingerprint(forPublicKey publicKey: Data) -> String {
        "sha256:\(Data(SHA256.hash(data: publicKey)).base64URLEncodedPushString)"
    }
}
