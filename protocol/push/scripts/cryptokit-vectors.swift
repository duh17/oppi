// CryptoKit side of the push test vectors (protocol/push/spec.md §7).
// Seals HPKE messages with the envelope v1 parameters to a fixed test X-Wing key.
// The server suite must open them. Run through generate-vectors.sh; needs macOS 26+.
import CryptoKit
import Foundation

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// Test-only seeds. Never use these keys outside tests.
let recipientSeed = Data((0..<32).map { UInt8($0) })
let otherSeed = Data((0..<32).map { UInt8(0xff - $0) })
let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
let info = Data("oppi-push-envelope-v1".utf8)

func keyId(_ publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey).prefix(16)) }

let recipient = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: recipientSeed, publicKey: nil)
let other = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: otherSeed, publicKey: nil)
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
        "description": "HPKE X-Wing/HKDF-SHA256/AES-256-GCM messages sealed by CryptoKit with the push envelope v1 info. Test keys only.",
        "generator": "protocol/push/scripts/cryptokit-vectors.swift",
        "suite": "XWingMLKEM768X25519_SHA256_AES_GCM_256",
    ],
    "info": base64url(info),
    "recipient": [
        "seed": base64url(recipientSeed),
        "publicKey": base64url(publicKey),
        "keyId": base64url(kid),
    ],
    "other": [
        "seed": base64url(otherSeed),
        "publicKey": base64url(other.publicKey.rawRepresentation),
        "keyId": base64url(keyId(other.publicKey.rawRepresentation)),
    ],
    "cases": cases,
]
let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(decoding: json, as: UTF8.self))
