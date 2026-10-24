import CryptoKit
import Foundation
import Testing
@testable import Oppi

/// Push envelope v1 against the committed server vectors (protocol/push/vectors): the
/// Notification Service Extension's own decision path, with storage injected.
@Suite("Push envelope v1")
struct PushEnvelopeTests {
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
        try JSONDecoder().decode(ServerVectors.self, from: ProtocolFixtures.data("push/vectors/server-envelopes.json"))
    }

    /// Expected plaintext of a valid case, decoded from the vector's JSON.
    static func expectedPlaintext(_ name: String) throws -> PushPlaintext {
        let root = try #require(JSONSerialization.jsonObject(with: ProtocolFixtures.data("push/vectors/server-envelopes.json")) as? [String: Any])
        let valid = try #require(root["valid"] as? [[String: Any]])
        let entry = try #require(valid.first { $0["name"] as? String == name })
        let json = try JSONSerialization.data(withJSONObject: try #require(entry["plaintext"]))
        return try JSONDecoder().decode(PushPlaintext.self, from: json)
    }

    static let serverId = "sha256:vector-server"

    static func keyLookup(_ vectors: ServerVectors) throws -> (Data) -> PushKeyMaterial? {
        let material = PushKeyMaterial(
            privateKey: try #require(Data(base64URLEncoded: vectors.recipient.privateKey)),
            serverPublicKey: try #require(Data(base64URLEncoded: vectors.server.publicKey)),
            serverId: serverId
        )
        let keyId = try #require(Data(base64URLEncoded: vectors.recipient.keyId))
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
        let publicKey = try #require(Data(base64URLEncoded: vectors.recipient.publicKey))
        let privateKey = try #require(Data(base64URLEncoded: vectors.recipient.privateKey))
        let derived = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey
        #expect(derived.rawRepresentation == publicKey)
        #expect(PushEnvelope.keyId(forPublicKey: publicKey).base64URLEncodedString == vectors.recipient.keyId)
    }

    @Test func signsTheSameRegistrationBytesTheServerVerifies() throws {
        let vector = try Self.vectors().registrationSignature
        let message = PushRegistrationSignature.message(
            deviceId: vector.input.deviceId,
            serverFingerprint: vector.input.serverFingerprint,
            keyId: vector.input.keyId,
            publicKey: try #require(Data(base64URLEncoded: vector.input.publicKey)),
            sendToken: vector.input.sendToken,
            relay: vector.input.relay,
            issuedAt: vector.input.issuedAt
        )
        #expect(message.base64URLEncodedString == vector.message)
        let serverKey = try #require(Data(base64URLEncoded: try Self.vectors().server.publicKey))
        #expect(serverKey.sha256Fingerprint == (try Self.vectors().server.fingerprint))
    }

    // MARK: - Replay

    /// Opens envelopes against one in-memory replay ledger, like the extension's stored one.
    private static func ledgerOpener(
        _ vectors: ServerVectors
    ) throws -> (_ envelope: String, _ now: Date) -> Result<OpenedPushEnvelope, PushEnvelopeRejection> {
        let key = try keyLookup(vectors)
        var ledger = PushReplayLedger()
        return { envelope, now in
            PushNotificationOpening.open(
                userInfo: ["e": envelope],
                now: now,
                key: key,
                acceptMessage: { ledger.accept(messageId: $0, keyId: $1, now: now) }
            )
        }
    }

    private static func rejection(_ result: Result<OpenedPushEnvelope, PushEnvelopeRejection>) -> PushEnvelopeRejection? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    @Test func distinctPushesOpenInAnyOrder() throws {
        let vectors = try Self.vectors()
        let open = try Self.ledgerOpener(vectors)
        for vector in vectors.valid.reversed() {
            #expect(Self.rejection(open(vector.envelope, Self.now(vectors))) == nil, "\(vector.name)")
        }
    }

    @Test func aReplayIsRejectedForAsLongAsTheEnvelopeIsFresh() throws {
        let vectors = try Self.vectors()
        let open = try Self.ledgerOpener(vectors)
        // Sealed 5 s before `now`.
        let envelope = try #require(vectors.valid.first { $0.name == "blocked-permission" }).envelope
        let now = Self.now(vectors)

        #expect(Self.rejection(open(envelope, now)) == nil)
        #expect(Self.rejection(open(envelope, now)) == .replay)
        // Its last fresh second: the ledger still remembers it.
        #expect(Self.rejection(open(envelope, now.addingTimeInterval(PushEnvelope.maxAge - 5))) == .replay)
        #expect(Self.rejection(open(envelope, now.addingTimeInterval(PushEnvelope.maxAge - 4))) == .stale)
    }

    @Test func theLedgerOutlivesAPushSealedAtTheClockSkewLimit() {
        // A push whose `ts` is maxClockSkew ahead stays fresh maxAge + maxClockSkew after it is
        // accepted; the ledger must not forget it sooner.
        var ledger = PushReplayLedger()
        let keyId = Data(repeating: 1, count: 16)
        let messageId = Data(repeating: 2, count: 32)
        let acceptedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let first = ledger.accept(messageId: messageId, keyId: keyId, now: acceptedAt)
        let lastFresh = acceptedAt.addingTimeInterval(PushEnvelope.maxClockSkew + PushEnvelope.maxAge)
        let replayAtLastFreshSecond = ledger.accept(messageId: messageId, keyId: keyId, now: lastFresh)
        #expect(first)
        #expect(!replayAtLastFreshSecond)
    }

    // MARK: - Replay ledger file

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aCorruptReplayLedgerIsResetInsteadOfRejectingEveryPush() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replay.json")
        try Data("{\"not\": \"a ledger\"".utf8).write(to: url)
        let keyId = Data(repeating: 1, count: 16)
        let now = Date()
        func accept(_ byte: UInt8) -> Bool {
            PushSharedStore.acceptMessage(
                Data(repeating: byte, count: 32),
                keyId: keyId,
                now: now,
                ledgerURL: url,
                liveKeyIds: { [keyId.base64URLEncodedString] }
            )
        }

        #expect(accept(1))
        // The reset ledger is saved and enforced again.
        #expect(!accept(1))
        #expect(accept(2))
        #expect((try? JSONDecoder().decode(PushReplayLedger.self, from: Data(contentsOf: url))) != nil)
    }

    @Test func aReplayLedgerThatCannotBeSavedRejectsThePush() throws {
        let directory = try Self.temporaryDirectory()
        let url = directory.appendingPathComponent("replay.json")
        try Data("corrupt".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let accepted = PushSharedStore.acceptMessage(
            Data(repeating: 1, count: 32),
            keyId: Data(repeating: 1, count: 16),
            now: Date(),
            ledgerURL: url,
            liveKeyIds: { [] }
        )
        #expect(!accepted)
    }

    // MARK: - Push state lock

    /// File classes kept in memory: the lock's class logic, without depending on whether the
    /// Simulator's keybag lets this process weaken a class right now (a fresh test host may not).
    private final class RecordedClasses {
        var classes: [String: URLFileProtection] = [:]
        var sets: [URLFileProtection] = []
        var access: CrossProcessFileLock.FileClasses {
            CrossProcessFileLock.FileClasses(
                read: { [unowned self] url in self.classes[url.path] },
                set: { [unowned self] protection, url in
                    self.sets.append(protection)
                    self.classes[url.path] = protection
                }
            )
        }
    }

    /// A file created in a directory the app's at-rest upgrade made Class B would be Class B,
    /// which the extension cannot open again while the phone is locked. So the creator sets the
    /// lock's class itself instead of inheriting the directory's.
    @Test func aNewLockFileGetsTheClassTheExtensionCanOpenWhileLocked() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replay.lock")
        let recorded = RecordedClasses()

        try CrossProcessFileLock.withLock(fileAt: url, protection: .completeUntilFirstUserAuthentication, classes: recorded.access) {}

        #expect(recorded.sets == [.completeUntilFirstUserAuthentication])
    }

    /// The app and the extension each open the lock file on their own: replacing it would let
    /// a process holding the old file run beside one locking the new file.
    @Test func aLockFileWithAStrongerClassIsFixedInPlaceAndStillExcludesAnotherOpen() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replay.lock")
        let recorded = RecordedClasses()
        try CrossProcessFileLock.withLock(fileAt: url, protection: .completeUntilFirstUserAuthentication, classes: recorded.access) {}
        let inode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        recorded.classes[url.path] = .completeUnlessOpen
        recorded.sets = []

        let blocked = try CrossProcessFileLock.withLock(
            fileAt: url, protection: .completeUntilFirstUserAuthentication, classes: recorded.access
        ) {
            let other = open(url.path, O_RDWR)
            defer { close(other) }
            return other >= 0 && flock(other, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
        }

        #expect(blocked)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == inode)
        #expect(recorded.sets == [.completeUntilFirstUserAuthentication])

        // A lock file that already has the right class is left alone.
        recorded.sets = []
        try CrossProcessFileLock.withLock(fileAt: url, protection: .completeUntilFirstUserAuthentication, classes: recorded.access) {}
        #expect(recorded.sets.isEmpty)
    }

    // MARK: - App icon badge

    /// The extension's badge for a push, against a stored badge file.
    private static func badge(_ userInfo: [AnyHashable: Any], storedAt url: URL) throws -> Int? {
        let vectors = try vectors()
        let result = PushNotificationOpening.open(
            userInfo: userInfo,
            now: now(vectors),
            key: try keyLookup(vectors),
            acceptMessage: { _, _ in true }
        )
        return PushNotificationOpening.badge(for: result) { change in
            PushSharedStore.updateSessionBadge(at: url, change)
        }
    }

    private static func envelope(_ name: String) throws -> [AnyHashable: Any] {
        ["e": try #require(try vectors().valid.first { $0.name == name }).envelope]
    }

    /// The count a stored badge file holds now, without changing it.
    private static func storedCount(at url: URL) -> Int? {
        PushSharedStore.updateSessionBadge(at: url) { _ in }?.count
    }

    @Test func aBlockedPushJoinsTheStoredSessionsOnce() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("badge.json")
        // The app left one waiting session on another server.
        let seeded = PushSharedStore.updateSessionBadge(at: url) {
            $0.insert(.init(serverId: "sha256:other", sessionId: "s_vector"))
        }
        #expect(seeded?.count == 1)

        #expect(try Self.badge(Self.envelope("blocked-permission"), storedAt: url) == 2)
        // Every vector names the same session: a second blocked push adds nothing.
        #expect(try Self.badge(Self.envelope("blocked-auth"), storedAt: url) == 2)
    }

    /// A failed run and an agent's message carry no waiting session, so the badge they show is
    /// nil (leave the icon as it is) and the stored count does not move.
    @Test func aFinishedRunOrAnAgentMessageLeavesTheBadgeAsItIs() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("badge.json")
        _ = PushSharedStore.updateSessionBadge(at: url) {
            $0.insert(.init(serverId: "sha256:other", sessionId: "s_vector"))
        }

        #expect(try Self.badge(Self.envelope("notify-no-workspace"), storedAt: url) == nil)
        #expect(Self.storedCount(at: url) == 1)
    }

    @Test func aFallbackOrPairingPushLeavesTheBadgeAsItIs() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("badge.json")

        #expect(try Self.badge(["aps": ["alert": ["title": "Oppi"]]], storedAt: url) == nil)
        #expect(try Self.badge(["e": "tampered"], storedAt: url) == nil)
        #expect(try Self.badge(Self.envelope("pairing-approval"), storedAt: url) == nil)
        #expect(try Self.badge(Self.envelope("device-enrolled"), storedAt: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Presentation

    private func present(
        _ name: String,
        redaction: PushRedactionSnapshot
    ) throws -> PushAlertPresentation {
        let vectors = try Self.vectors()
        let envelope = try #require(vectors.valid.first { $0.name == name }).envelope
        return PushNotificationOpening.presentation(
            for: PushNotificationOpening.open(
                userInfo: ["aps": ["alert": ["title": "Oppi"]], "e": envelope],
                now: Self.now(vectors),
                key: try Self.keyLookup(vectors),
                acceptMessage: { _, _ in true }
            ),
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

    @Test func anAgentMessageShowsTheAgentsWordsAndOpensItsSession() throws {
        let alert = try present("notify-no-workspace", redaction: PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []))
        #expect(alert.title == "Push relay fix landed")
        #expect(alert.body == "Read the summary in the session.")
        #expect(alert.subtitle == "Fix the flaky test")
        #expect(alert.interruption == .active)
        #expect(alert.playsSound)
        #expect(alert.categoryIdentifier == AttentionNotificationPolicy.agentMessageCategoryId)
        #expect(alert.threadIdentifier == "s_vector")
        #expect(AttentionNotificationPolicy.navigationSessionId(
            categoryIdentifier: alert.categoryIdentifier,
            userInfo: alert.userInfo
        ) == "s_vector")
    }

    @Test(arguments: redactingSnapshots)
    func locksHideTheAgentsWords(redaction: PushRedactionSnapshot) throws {
        let alert = try present("notify-no-workspace", redaction: redaction)
        // The workspace lock cannot apply: this push names no workspace.
        if redaction.lockedScopes.contains(where: { $0.workspaceId != nil }) { return }
        #expect(alert.title == String(localized: "Agent Message"))
        #expect(alert.subtitle.isEmpty)
        #expect(alert.body == String(localized: "Open Oppi to read it."))
    }

    /// The extension tags the pairing alert it opened, so its Deny acts on that approval, with
    /// App Lock on as well.
    @Test func aPairingAlertTheExtensionOpenedCanBeDenied() throws {
        let approvalId = try #require(try Self.expectedPlaintext("pairing-approval").approvalId)
        for appLock in [false, true] {
            let alert = try present("pairing-approval", redaction: PushRedactionSnapshot(appLockEnabled: appLock, lockedScopes: []))
            let request = AttentionNotificationService.openRequest(
                categoryIdentifier: alert.categoryIdentifier,
                actionIdentifier: AttentionNotificationService.pairingDenyActionId,
                userInfo: alert.userInfo,
                pushKey: try Self.keyLookup(Self.vectors())
            )
            #expect(request == .pairing(serverId: Self.serverId, approvalId: approvalId, action: .deny))
        }
    }

    @Test func aPushWithoutAnEnvelopeShowsOnlyTheFixedText() {
        let alert = PushNotificationOpening.presentation(
            for: PushNotificationOpening.open(
                userInfo: ["aps": ["alert": ["title": "Leaked title", "body": "Leaked body"]]],
                now: Date(),
                key: { _ in nil },
                acceptMessage: { _, _ in true }
            ),
            redaction: { PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []) }
        )
        #expect(alert == .fallback)
        #expect(alert.title == "Oppi")
        #expect(alert.body == "You have a new notification.")
        #expect(alert.userInfo.isEmpty)
    }
}
