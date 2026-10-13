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
        case pairingApproval = "pairing_approval"
        case deviceEnrolled = "device_enrolled"

        var isSessionEvent: Bool {
            switch self {
            case .blocked, .done, .error, .ended: true
            case .pairingApproval, .deviceEnrolled: false
            }
        }
    }

    enum Kind: String, Decodable, Sendable {
        case permission, question, auth
    }

    let v: Int
    /// Unix milliseconds when the server sealed it.
    let ts: Int64
    let event: Event
    let kind: Kind?
    /// Required for session events; omitted for pairing events.
    let sessionId: String?
    let workspaceId: String?
    let title: String
    let subtitle: String?
    let body: String
    let approvalId: String?
    let deviceId: String?

    init(
        v: Int,
        ts: Int64,
        event: Event,
        kind: Kind? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        title: String,
        subtitle: String? = nil,
        body: String,
        approvalId: String? = nil,
        deviceId: String? = nil
    ) {
        self.v = v
        self.ts = ts
        self.event = event
        self.kind = kind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.approvalId = approvalId
        self.deviceId = deviceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        ts = try c.decode(Int64.self, forKey: .ts)
        event = try c.decode(Event.self, forKey: .event)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        body = try c.decode(String.self, forKey: .body)

        if event.isSessionEvent {
            let sessionId = try c.decode(String.self, forKey: .sessionId)
            let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionId,
                    in: c,
                    debugDescription: "Session push events require sessionId"
                )
            }
            self.sessionId = trimmed
            approvalId = try c.decodeIfPresent(String.self, forKey: .approvalId)
            deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        } else {
            sessionId = try Self.decodeOptionalNonEmpty(c, key: .sessionId)
            switch event {
            case .pairingApproval:
                approvalId = try Self.decodeRequiredNonEmpty(c, key: .approvalId)
                deviceId = try Self.decodeOptionalNonEmpty(c, key: .deviceId)
            case .deviceEnrolled:
                deviceId = try Self.decodeRequiredNonEmpty(c, key: .deviceId)
                approvalId = try Self.decodeOptionalNonEmpty(c, key: .approvalId)
            case .blocked, .done, .error, .ended:
                approvalId = nil
                deviceId = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case v, ts, event, kind, sessionId, workspaceId, title, subtitle, body, approvalId, deviceId
    }

    private static func decodeRequiredNonEmpty(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String {
        let value = try c.decode(String.self, forKey: key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "\(key.stringValue) is required"
            )
        }
        return trimmed
    }

    private static func decodeOptionalNonEmpty(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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
    /// The HPKE `enc`: a fresh ephemeral X25519 public key per push, covered by the signature,
    /// so it identifies the push for replay checks (spec §2.5 step 7).
    let messageId: Data
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
        guard let bytes = Data(base64URLEncoded: envelope), bytes.count == PushEnvelope.length else {
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
        return OpenedPushEnvelope(
            keyId: keyId,
            messageId: encapsulatedKey,
            serverId: material.serverId,
            plaintext: plaintext
        )
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

/// Replay state (spec §2.5 step 7): per push key, the message id (HPKE `enc`) of every push
/// accepted within the freshness window, with when it was accepted. The server keeps no
/// replay state, so re-registering the same key, a restored server config, or a server
/// restart cannot collide with ids this phone has already seen, and APNs reordering is
/// harmless.
struct PushReplayLedger: Codable, Equatable, Sendable {
    /// How long an accepted push can still pass the freshness check: its `ts` may be up to
    /// `maxClockSkew` ahead of this phone's clock and stays fresh `maxAge` after `ts`.
    /// Entries older than this are pruned; freshness already rejects their replays.
    static let window: TimeInterval = PushEnvelope.maxAge + PushEnvelope.maxClockSkew

    /// kid (base64url) → message id (base64url) → accepted at (Unix seconds).
    private(set) var accepted: [String: [String: TimeInterval]] = [:]

    /// Records `messageId` for `keyId`; false when it was already accepted within the window.
    mutating func accept(messageId: Data, keyId: Data, now: Date) -> Bool {
        let cutoff = now.timeIntervalSince1970 - Self.window
        accepted = accepted.compactMapValues { ids in
            let kept = ids.filter { $0.value >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        let kid = keyId.base64URLEncodedString
        let id = messageId.base64URLEncodedString
        guard accepted[kid]?[id] == nil else { return false }
        accepted[kid, default: [:]][id] = now.timeIntervalSince1970
        return true
    }

    /// Drops entries for keys no longer on the phone.
    mutating func retainKeys(_ keyIds: Set<String>) {
        accepted = accepted.filter { keyIds.contains($0.key) }
    }
}
