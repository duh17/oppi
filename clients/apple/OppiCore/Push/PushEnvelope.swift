import CryptoKit
import Foundation

/// Push envelope v1 (protocol/push/spec.md §2): HPKE ciphertext (DHKEM(X25519), HKDF-SHA256,
/// ChaCha20-Poly1305) signed by the paired
/// server's Ed25519 identity key. Opened only on this device, by the Notification Service
/// Extension; the relay and APNs carry it without the key.
enum PushEnvelope {
    static let version: UInt8 = 0x01
    static let keyIdLength = 16
    static let encapsulatedKeyLength = 32
    static let paddedPlaintextLength = 512
    static let ciphertextLength = paddedPlaintextLength + 16
    static let signatureLength = 64
    static let headerLength = 1 + keyIdLength
    static let signedLength = headerLength + encapsulatedKeyLength + ciphertextLength
    static let length = signedLength + signatureLength

    static let hpkeInfo = Data("oppi-push-envelope-v1".utf8)
    static let signatureLabel = Data("oppi-push-envelope-v1-sig".utf8) + Data([0])
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// Pushes older than the relay's longest TTL, plus clock skew, are stale.
    static let maxAge: TimeInterval = 3600 + 300
    static let maxClockSkew: TimeInterval = 300

    /// `kid`: the first 16 bytes of SHA-256 of the raw X25519 public key.
    static func keyId(forPublicKey publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(keyIdLength))
    }
}

/// Why a push showed the fallback text instead of its content. Names match the
/// `reason` values in protocol/push/vectors/server-envelopes.json.
enum PushEnvelopeRejection: String, Error, Equatable, Sendable {
    case size
    case version
    case unknownKey
    case signature
    case decrypt
    case plaintext
    case stale
    case replay
}

/// Decrypted push content (spec §2.4).
struct PushPlaintext: Decodable, Equatable, Sendable {
    enum Event: String, Decodable, Sendable {
        case blocked, done, error, ended
    }

    enum Kind: String, Decodable, Sendable {
        case permission, question, auth
    }

    let v: Int
    let seq: UInt64
    /// Unix milliseconds when the server sealed it.
    let ts: Int64
    let event: Event
    let kind: Kind?
    let sessionId: String
    let workspaceId: String?
    let incognito: Bool?
    let title: String
    let subtitle: String?
    let body: String
}

/// What the extension needs to open envelopes for one paired server's push key.
struct PushKeyMaterial: Sendable {
    /// 32-byte raw X25519 private key (`Curve25519.KeyAgreement.PrivateKey.rawRepresentation`).
    let privateKey: Data
    /// Raw Ed25519 identity public key of the server this key belongs to.
    let serverPublicKey: Data
    /// `PairedServer.id` (the server identity fingerprint).
    let serverId: String
}

struct OpenedPushEnvelope: Sendable {
    let keyId: Data
    let serverId: String
    let plaintext: PushPlaintext
}

enum PushEnvelopeOpener {
    /// Steps 1-6 of spec §2.5. Replay (step 7) is the caller's, against stored state.
    static func open(
        base64url envelope: String,
        now: Date,
        key: (Data) -> PushKeyMaterial?
    ) throws(PushEnvelopeRejection) -> OpenedPushEnvelope {
        guard let bytes = Data(base64URLEncodedPushString: envelope), bytes.count == PushEnvelope.length else {
            throw .size
        }
        guard bytes[bytes.startIndex] == PushEnvelope.version else { throw .version }

        let base = bytes.startIndex
        let header = bytes[base..<(base + PushEnvelope.headerLength)]
        let keyId = Data(bytes[(base + 1)..<(base + PushEnvelope.headerLength)])
        let encStart = base + PushEnvelope.headerLength
        let ctStart = encStart + PushEnvelope.encapsulatedKeyLength
        let sigStart = base + PushEnvelope.signedLength
        let encapsulatedKey = Data(bytes[encStart..<ctStart])
        let ciphertext = Data(bytes[ctStart..<sigStart])
        let signed = Data(bytes[base..<sigStart])
        let signature = Data(bytes[sigStart...])

        guard let material = key(keyId) else { throw .unknownKey }
        guard let serverKey = try? Curve25519.Signing.PublicKey(rawRepresentation: material.serverPublicKey),
              serverKey.isValidSignature(signature, for: PushEnvelope.signatureLabel + signed) else {
            throw .signature
        }

        let padded: Data
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.privateKey)
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: PushEnvelope.ciphersuite,
                info: PushEnvelope.hpkeInfo,
                encapsulatedKey: encapsulatedKey
            )
            padded = try recipient.open(ciphertext, authenticating: Data(header))
        } catch {
            throw .decrypt
        }

        let plaintext = try decodePadded(padded)
        let sealedAt = Date(timeIntervalSince1970: TimeInterval(plaintext.ts) / 1000)
        let age = now.timeIntervalSince(sealedAt)
        guard age <= PushEnvelope.maxAge, age >= -PushEnvelope.maxClockSkew else { throw .stale }
        return OpenedPushEnvelope(keyId: keyId, serverId: material.serverId, plaintext: plaintext)
    }

    /// `uint16 length || JSON || zero padding` (spec §2.3).
    static func decodePadded(_ padded: Data) throws(PushEnvelopeRejection) -> PushPlaintext {
        guard padded.count == PushEnvelope.paddedPlaintextLength else { throw .plaintext }
        let bytes = [UInt8](padded)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length <= PushEnvelope.paddedPlaintextLength - 2,
              bytes[(2 + length)...].allSatisfy({ $0 == 0 }),
              let plaintext = try? JSONDecoder().decode(PushPlaintext.self, from: Data(bytes[2..<(2 + length)])),
              plaintext.v == 1 else {
            throw .plaintext
        }
        return plaintext
    }
}

/// Replay state for one push key (spec §2.5 step 7): the highest sequence number seen and
/// which of the 64 below it arrived. APNs can reorder pushes, so a strictly increasing
/// check would drop real ones.
struct PushReplayWindow: Codable, Equatable, Sendable {
    static let size: UInt64 = 64

    private(set) var highest: UInt64 = 0
    /// Bit `i` set: `highest - i` was seen (bit 0 is `highest` itself).
    private(set) var seen: UInt64 = 0

    /// Records `seq` and returns true when it is new and inside the window.
    mutating func accept(_ seq: UInt64) -> Bool {
        guard seq > 0 else { return false }
        if seq > highest {
            let shift = seq - highest
            seen = shift >= Self.size ? 0 : seen << shift
            seen |= 1
            highest = seq
            return true
        }
        let offset = highest - seq
        guard offset < Self.size else { return false }
        let bit: UInt64 = 1 << offset
        guard seen & bit == 0 else { return false }
        seen |= bit
        return true
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5). Nil for any other alphabet.
    init?(base64URLEncodedPushString value: String) {
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: normalized)
    }

    var base64URLEncodedPushString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
