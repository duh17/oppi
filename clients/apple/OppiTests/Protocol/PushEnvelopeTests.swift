import CryptoKit
import Foundation
import Testing
@testable import Oppi

/// Push envelope v1 against the committed server vectors (protocol/push/vectors): the
/// Notification Service Extension's own decision path, with storage injected.
@Suite("Push envelope v1")
struct PushEnvelopeTests {
    /// OppiTests/Protocol/<file> → clients/apple → repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    struct ServerVectors: Decodable {
        struct Recipient: Decodable { let privateKey: String; let publicKey: String; let keyId: String }
        struct Server: Decodable { let publicKey: String; let fingerprint: String }
        struct Valid: Decodable { let name: String; let envelope: String }
        struct Invalid: Decodable { let name: String; let envelope: String; let reason: String }
        struct RegistrationSignature: Decodable {
            struct Input: Decodable {
                let deviceId: String
                let serverFingerprint: String
                let keyId: String
                let publicKey: String
                let sendToken: String
                let relay: String
                let issuedAt: Int64
            }
            let input: Input
            let message: String
        }

        let now: Double
        let recipient: Recipient
        let server: Server
        let valid: [Valid]
        let invalid: [Invalid]
        let registrationSignature: RegistrationSignature
    }

    static func vectors() throws -> ServerVectors {
        let url = repoRoot.appendingPathComponent("protocol/push/vectors/server-envelopes.json")
        return try JSONDecoder().decode(ServerVectors.self, from: Data(contentsOf: url))
    }

    /// Expected plaintext of a valid case, decoded from the vector's JSON.
    static func expectedPlaintext(_ name: String) throws -> PushPlaintext {
        let url = repoRoot.appendingPathComponent("protocol/push/vectors/server-envelopes.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let valid = try #require(root["valid"] as? [[String: Any]])
        let entry = try #require(valid.first { $0["name"] as? String == name })
        let json = try JSONSerialization.data(withJSONObject: try #require(entry["plaintext"]))
        return try JSONDecoder().decode(PushPlaintext.self, from: json)
    }

    static let serverId = "sha256:vector-server"

    static func keyLookup(_ vectors: ServerVectors) throws -> (Data) -> PushKeyMaterial? {
        let material = PushKeyMaterial(
            privateKey: try #require(Data(base64URLEncodedPushString: vectors.recipient.privateKey)),
            serverPublicKey: try #require(Data(base64URLEncodedPushString: vectors.server.publicKey)),
            serverId: serverId
        )
        let keyId = try #require(Data(base64URLEncodedPushString: vectors.recipient.keyId))
        return { $0 == keyId ? material : nil }
    }

    static func now(_ vectors: ServerVectors) -> Date {
        Date(timeIntervalSince1970: vectors.now / 1000)
    }

    @Test func opensEveryEnvelopeTheServerSealed() throws {
        let vectors = try Self.vectors()
        let key = try Self.keyLookup(vectors)
        #expect(!vectors.valid.isEmpty)
        for vector in vectors.valid {
            let opened = try PushEnvelopeOpener.open(base64url: vector.envelope, now: Self.now(vectors), key: key)
            #expect(opened.plaintext == (try Self.expectedPlaintext(vector.name)), "\(vector.name)")
            #expect(opened.serverId == Self.serverId)
        }
    }

    @Test func rejectsEveryInvalidEnvelopeForItsReason() throws {
        let vectors = try Self.vectors()
        let key = try Self.keyLookup(vectors)
        #expect(!vectors.invalid.isEmpty)
        for vector in vectors.invalid {
            do {
                _ = try PushEnvelopeOpener.open(base64url: vector.envelope, now: Self.now(vectors), key: key)
                Issue.record("\(vector.name) opened")
            } catch {
                #expect(error.rawValue == vector.reason, "\(vector.name)")
            }
        }
    }

    @Test func derivesTheServersKeyIdFromThePublicKey() throws {
        let vectors = try Self.vectors()
        let publicKey = try #require(Data(base64URLEncodedPushString: vectors.recipient.publicKey))
        let privateKey = try #require(Data(base64URLEncodedPushString: vectors.recipient.privateKey))
        let derived = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey
        #expect(derived.rawRepresentation == publicKey)
        #expect(PushEnvelope.keyId(forPublicKey: publicKey).base64URLEncodedPushString == vectors.recipient.keyId)
    }

    @Test func signsTheSameRegistrationBytesTheServerVerifies() throws {
        let vector = try Self.vectors().registrationSignature
        let message = PushRegistrationSignature.message(
            deviceId: vector.input.deviceId,
            serverFingerprint: vector.input.serverFingerprint,
            keyId: vector.input.keyId,
            publicKey: try #require(Data(base64URLEncodedPushString: vector.input.publicKey)),
            sendToken: vector.input.sendToken,
            relay: vector.input.relay,
            issuedAt: vector.input.issuedAt
        )
        #expect(message.base64URLEncodedPushString == vector.message)
        let serverKey = try #require(Data(base64URLEncodedPushString: try Self.vectors().server.publicKey))
        #expect(PushRegistrationSignature.serverFingerprint(forPublicKey: serverKey) == (try Self.vectors().server.fingerprint))
    }

    // MARK: - Replay

    @Test func acceptsReorderedPushesButNotReplaysOrOnesBelowTheWindow() {
        var window = PushReplayWindow()
        let results = [5, 3, 5, 3, 100, 37, 36, 0].map { window.accept(UInt64($0)) }
        // New, reordered, replay, replay, far ahead, oldest in window, below window, zero.
        #expect(results == [true, true, false, false, true, true, false, false])
    }

    @Test func aReplayedEnvelopeShowsTheFallback() throws {
        let vectors = try Self.vectors()
        let key = try Self.keyLookup(vectors)
        let envelope = try #require(vectors.valid.first).envelope
        var windows: [Data: PushReplayWindow] = [:]
        func present() -> PushAlertPresentation {
            PushNotificationOpening.presentation(
                userInfo: ["e": envelope],
                now: Self.now(vectors),
                key: key,
                acceptSequence: { seq, keyId in
                    var window = windows[keyId] ?? PushReplayWindow()
                    defer { windows[keyId] = window }
                    return window.accept(seq)
                },
                redaction: { PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []) }
            )
        }

        #expect(present().title == "Needs Approval")
        #expect(present() == .fallback)
    }

    // MARK: - Presentation

    private func present(
        _ name: String,
        redaction: PushRedactionSnapshot
    ) throws -> PushAlertPresentation {
        let vectors = try Self.vectors()
        let envelope = try #require(vectors.valid.first { $0.name == name }).envelope
        return PushNotificationOpening.presentation(
            userInfo: ["aps": ["alert": ["title": "Oppi"]], "e": envelope],
            now: Self.now(vectors),
            key: try Self.keyLookup(vectors),
            acceptSequence: { _, _ in true },
            redaction: { redaction }
        )
    }

    @Test func showsTheDecryptedAlertWhenNothingIsLocked() throws {
        let alert = try present("blocked-permission", redaction: PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []))
        #expect(alert.title == "Needs Approval")
        #expect(alert.subtitle == "Fix the flaky test")
        #expect(alert.body == "Waiting for your approval.")
        #expect(alert.categoryIdentifier == AttentionNotificationPolicy.sessionBlockedCategoryId)
        #expect(alert.threadIdentifier == "s_vector")
        #expect(alert.interruption == .timeSensitive)
        #expect(alert.playsSound)
        #expect(alert.userInfo == [
            "event": "blocked", "kind": "permission", "sessionId": "s_vector",
            "serverId": Self.serverId, "workspaceId": "w_vector",
        ])
        // Tapping routes to the session.
        #expect(AttentionNotificationPolicy.navigationSessionId(
            categoryIdentifier: alert.categoryIdentifier,
            userInfo: alert.userInfo
        ) == "s_vector")
    }

    static let redactingSnapshots: [PushRedactionSnapshot] = [
        PushRedactionSnapshot(appLockEnabled: true, lockedScopes: []),
        PushRedactionSnapshot.unknown,
        PushRedactionSnapshot(appLockEnabled: false, lockedScopes: [
            .init(serverId: Self.serverId, workspaceId: nil, sessionId: nil),
        ]),
        PushRedactionSnapshot(appLockEnabled: false, lockedScopes: [
            .init(serverId: Self.serverId, workspaceId: "w_vector", sessionId: nil),
        ]),
        PushRedactionSnapshot(appLockEnabled: false, lockedScopes: [
            .init(serverId: Self.serverId, workspaceId: nil, sessionId: "s_vector"),
        ]),
    ]

    @Test(arguments: redactingSnapshots)
    func appLockAndScopedLocksHideTheSessionName(redaction: PushRedactionSnapshot) throws {
        let alert = try present("long-subtitle-shortened", redaction: redaction)
        #expect(alert.title == String(localized: "Question"))
        #expect(alert.subtitle.isEmpty)
        #expect(alert.body == String(localized: "Waiting for your answer."))
    }

    @Test func aLockOnAnotherServerOrWorkspaceDoesNotHideIt() throws {
        let alert = try present("long-subtitle-shortened", redaction: PushRedactionSnapshot(
            appLockEnabled: false,
            lockedScopes: [
                .init(serverId: "sha256:other", workspaceId: nil, sessionId: nil),
                .init(serverId: Self.serverId, workspaceId: "w_other", sessionId: nil),
            ]
        ))
        #expect(alert.subtitle.hasPrefix("名"))
    }

    @Test func doneIsPassiveAndSilent() throws {
        let alert = try present("done-no-workspace", redaction: PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []))
        #expect(alert.interruption == .passive)
        #expect(!alert.playsSound)
        #expect(alert.categoryIdentifier == AttentionNotificationPolicy.sessionDoneCategoryId)
    }

    @Test func aPushWithoutAnEnvelopeShowsOnlyTheFixedText() {
        let alert = PushNotificationOpening.presentation(
            userInfo: ["aps": ["alert": ["title": "Leaked title", "body": "Leaked body"]]],
            now: Date(),
            key: { _ in nil },
            acceptSequence: { _, _ in true },
            redaction: { PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []) }
        )
        #expect(alert == .fallback)
        #expect(alert.title == "Oppi")
        #expect(alert.body == "You have a new notification.")
        #expect(alert.userInfo.isEmpty)
    }
}
