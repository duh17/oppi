import CryptoKit
import Foundation

// The one base64url and `sha256:` fingerprint encoding for Apple code. Pairing pins the
// server identity fingerprint and push registration re-derives it to check the server's key,
// so both must come from the same function. The share and notification extensions compile
// this file directly (project.yml).
extension Data {
    /// Base64url without padding (RFC 4648 §5).
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url without padding (RFC 4648 §5). Nil for any other alphabet.
    init?(base64URLEncoded value: String) {
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: normalized)
    }

    /// `sha256:<base64url SHA-256>`: the server identity fingerprint (over the raw Ed25519
    /// public key) and the TLS leaf fingerprint (over the certificate DER).
    var sha256Fingerprint: String {
        "sha256:\(Data(SHA256.hash(data: self)).base64URLEncodedString)"
    }
}
