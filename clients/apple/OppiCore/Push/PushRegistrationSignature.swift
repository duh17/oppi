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
            Data(SHA256.hash(data: publicKey)).base64URLEncodedString,
            Data(SHA256.hash(data: Data(sendToken.utf8))).base64URLEncodedString,
            relay,
            String(issuedAt),
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }
}
