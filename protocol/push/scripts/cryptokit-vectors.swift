// CryptoKit side of the push test vectors (protocol/push/spec.md §7).
// Seals HPKE messages with the envelope v1 parameters to a fixed test X25519 key.
// The server suite must open them. Run through generate-vectors.sh.
import CryptoKit
import Foundation

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// Test-only private keys. Never use these keys outside tests.
let recipientRaw = Data((0..<32).map { UInt8($0) })
let otherRaw = Data((0..<32).map { UInt8(0xff - $0) })
let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
let info = Data("oppi-push-envelope-v1".utf8)

func keyId(_ publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey).prefix(16)) }

let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientRaw)
let other = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: otherRaw)
let publicKey = recipient.publicKey.rawRepresentation
let kid = keyId(publicKey)

var cases: [[String: String]] = []
for message in ["{\"v\":1,\"note\":\"sealed by CryptoKit\"}", "short", String(repeating: "x", count: 512)] {
    let aad = Data([0x01]) + kid
    var sender = try HPKE.Sender(recipientKey: recipient.publicKey, ciphersuite: suite, info: info)
    let ciphertext = try sender.seal(Data(message.utf8), authenticating: aad)
    cases.append([
        "plaintext": base64url(Data(message.utf8)),
        "aad": base64url(aad),
        "enc": base64url(sender.encapsulatedKey),
        "ciphertext": base64url(ciphertext),
    ])
}

let output: [String: Any] = [
    "_meta": [
        "description": "HPKE DHKEM(X25519)/HKDF-SHA256/ChaCha20-Poly1305 messages sealed by CryptoKit with the push envelope v1 info. Test keys only.",
        "generator": "protocol/push/scripts/cryptokit-vectors.swift",
        "suite": "Curve25519_SHA256_ChachaPoly",
    ],
    "info": base64url(info),
    "recipient": [
        "privateKey": base64url(recipientRaw),
        "publicKey": base64url(publicKey),
        "keyId": base64url(kid),
    ],
    "other": [
        "privateKey": base64url(otherRaw),
        "publicKey": base64url(other.publicKey.rawRepresentation),
        "keyId": base64url(keyId(other.publicKey.rawRepresentation)),
    ],
    "cases": cases,
]
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(decoding: json, as: UTF8.self))
