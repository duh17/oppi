import Foundation
import Testing
@testable import Oppi

/// The end of the canary run (server/scripts/push-canary.ts): APNs payloads the real server
/// sealed and the real relay sent, opened by the Notification Service Extension's path. The
/// relay never saw the canaries; this device's key recovers them, and anything altered on
/// the way shows only the fixed fallback.
///
/// The first four payloads ran concurrently; the fifth was sealed after the server forgot the
/// device's registration and the phone registered the same push key again.
@Suite("Push canary capture")
struct PushCanaryCaptureTests {
    struct Capture: Decodable {
        let now: Double
        let serverPublicKey: String
        let serverFingerprint: String
        let canaries: [String: String]
        let apnsPayloads: [String]
    }

    struct CryptoKitVectors: Decodable {
        struct Key: Decodable { let privateKey: String; let keyId: String }
        let recipient: Key
        let other: Key
    }

    /// OppiTests/Protocol/<file> → clients/apple → repo root.
    private static let vectorsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/push/vectors")

    private let capture: Capture
    private let keys: CryptoKitVectors

    init() throws {
        capture = try JSONDecoder().decode(
            Capture.self,
            from: Data(contentsOf: Self.vectorsDir.appendingPathComponent("canary-capture.json"))
        )
        keys = try JSONDecoder().decode(
            CryptoKitVectors.self,
            from: Data(contentsOf: Self.vectorsDir.appendingPathComponent("cryptokit-hpke.json"))
        )
    }

    private func userInfo(_ payload: String) throws -> [AnyHashable: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    private func material(privateKey: String) throws -> PushKeyMaterial {
        PushKeyMaterial(
            privateKey: try #require(Data(base64URLEncodedPushString: privateKey)),
            serverPublicKey: try #require(Data(base64URLEncodedPushString: capture.serverPublicKey)),
            serverId: capture.serverFingerprint
        )
    }

    /// Opens payloads in order against one replay ledger file, like the extension does.
    private func opener(
        privateKey: String,
        ledger: URL
    ) throws -> (([AnyHashable: Any]) -> PushAlertPresentation) {
        let material = try material(privateKey: privateKey)
        let keyId = try #require(Data(base64URLEncodedPushString: keys.recipient.keyId))
        let now = Date(timeIntervalSince1970: capture.now / 1000)
        return { userInfo in
            PushNotificationOpening.presentation(
                userInfo: userInfo,
                now: now,
                key: { $0 == keyId ? material : nil },
                acceptMessage: { messageId, keyId in
                    PushSharedStore.acceptMessage(
                        messageId,
                        keyId: keyId,
                        now: now,
                        ledgerURL: ledger,
                        liveKeyIds: { [keyId.base64URLEncodedPushString] }
                    )
                },
                redaction: { PushRedactionSnapshot(appLockEnabled: false, lockedScopes: []) }
            )
        }
    }

    private func withOpener(
        privateKey: String? = nil,
        _ body: (([AnyHashable: Any]) -> PushAlertPresentation) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(try opener(
            privateKey: privateKey ?? keys.recipient.privateKey,
            ledger: directory.appendingPathComponent("replay.json")
        ))
    }

    @Test func theRelayCarriedOnlyTheFixedTemplate() throws {
        #expect(capture.apnsPayloads.count == 5)
        for payload in capture.apnsPayloads {
            let aps = try #require(try userInfo(payload)["aps"] as? [String: Any])
            let alert = try #require(aps["alert"] as? [String: String])
            #expect(alert == ["title": PushAlertPresentation.fallbackTitle, "body": PushAlertPresentation.fallbackBody])
            for canary in capture.canaries.values { #expect(!payload.contains(canary)) }
        }
    }

    @Test func thisDevicesKeyRecoversTheCanaries() throws {
        let serverKey = try #require(Data(base64URLEncodedPushString: capture.serverPublicKey))
        #expect(PushRegistrationSignature.serverFingerprint(forPublicKey: serverKey) == capture.serverFingerprint)

        try withOpener { open in
            let alerts = try capture.apnsPayloads.map { open(try userInfo($0)) }
            let name = try #require(capture.canaries["sessionName"])
            // The first four sends ran concurrently, so APNs saw them in any order.
            #expect(Set(alerts.prefix(4).map(\.title)) == ["Needs Approval", "Session Done", "Session Error", "Session Ended"])
            #expect(alerts.allSatisfy { $0.subtitle == name })
            #expect(alerts.allSatisfy { $0.userInfo["sessionId"] == capture.canaries["sessionId"] })
            #expect(alerts.allSatisfy { $0.userInfo["workspaceId"] == capture.canaries["workspaceId"] })
            #expect(alerts.first { $0.title == "Session Ended" }?.body == capture.canaries["endedReason"])
        }
    }

    @Test func aPushAfterReRegisteringTheSameKeyOpens() throws {
        // Regression: replay state was a per-key sequence number the server restarted at 1
        // whenever it recreated a registration, while the phone kept the key and its window.
        try withOpener { open in
            let payloads = try capture.apnsPayloads.map { try userInfo($0) }
            for payload in payloads.prefix(4) { #expect(open(payload) != .fallback) }
            let afterReregistration = try #require(payloads.last)
            #expect(open(afterReregistration).title == "Question")
            #expect(open(afterReregistration) == .fallback)
        }
    }

    @Test func aReplayedPushShowsTheFallback() throws {
        try withOpener { open in
            let first = try userInfo(try #require(capture.apnsPayloads.first))
            #expect(open(first) != .fallback)
            #expect(open(first) == .fallback)
        }
    }

    @Test func aTamperedPushShowsTheFallback() throws {
        var info = try userInfo(try #require(capture.apnsPayloads.first))
        var envelope = Array(try #require(info["e"] as? String))
        let index = envelope.count / 2
        envelope[index] = envelope[index] == "A" ? "B" : "A"
        info["e"] = String(envelope)
        try withOpener { open in #expect(open(info) == .fallback) }
    }

    @Test func anotherKeyCannotOpenIt() throws {
        // The right key ID with another device's private key: HPKE refuses.
        let info = try userInfo(try #require(capture.apnsPayloads.first))
        try withOpener(privateKey: keys.other.privateKey) { open in #expect(open(info) == .fallback) }
    }

    @Test func anOversizedEnvelopeShowsTheFallback() throws {
        var info = try userInfo(try #require(capture.apnsPayloads.first))
        info["e"] = try #require(info["e"] as? String) + "AAAA"
        try withOpener { open in #expect(open(info) == .fallback) }
    }
}
