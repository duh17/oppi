import Foundation
import Testing
@testable import Oppi

@Suite("Pairing push plaintext")
struct PushPairingPlaintextTests {
    private let serverId = "sha256:server"

    @Test func decodesPairingApprovalAndOmitsSessionId() throws {
        let plaintext = try decode("""
        {
          "v": 1,
          "ts": 1760000000000,
          "event": "pairing_approval",
          "approvalId": "pa_1",
          "title": "Approve New Device?",
          "body": "iPad wants to pair (invite, 100.64.0.7)."
        }
        """)
        #expect(plaintext.event == .pairingApproval)
        #expect(plaintext.approvalId == "pa_1")
        #expect(plaintext.sessionId == nil)
        #expect(plaintext.deviceId == nil)
    }

    @Test func decodesDeviceEnrolled() throws {
        let plaintext = try decode("""
        {
          "v": 1,
          "ts": 1760000000000,
          "event": "device_enrolled",
          "deviceId": "dev_new",
          "title": "New Device Paired",
          "body": "iPad paired (invite, 100.64.0.7)."
        }
        """)
        #expect(plaintext.event == .deviceEnrolled)
        #expect(plaintext.deviceId == "dev_new")
        #expect(plaintext.sessionId == nil)
    }

    @Test func sessionEventWithoutSessionIdIsRejectedAsPlaintext() throws {
        let json = #"{"v":1,"ts":1,"event":"done","title":"Session Done","body":"Finished."}"#
        #expect(throws: DecodingError.self) {
            try decode(json)
        }
        #expect(throws: PushEnvelopeRejection.plaintext) {
            try PushEnvelopeOpener.decodePadded(padded(json))
        }
    }

    @Test func pairingApprovalWithoutApprovalIdIsRejectedAsPlaintext() throws {
        let json = #"{"v":1,"ts":1,"event":"pairing_approval","title":"Approve New Device?","body":"Waiting."}"#
        #expect(throws: DecodingError.self) {
            try decode(json)
        }
        #expect(throws: PushEnvelopeRejection.plaintext) {
            try PushEnvelopeOpener.decodePadded(padded(json))
        }
    }

    @Test func pairingApprovalPresentsTimeSensitiveSoundAndUserInfo() throws {
        let plaintext = PushPlaintext(
            v: 1,
            ts: 1,
            event: .pairingApproval,
            title: "Approve New Device?",
            body: "iPad wants to pair (invite, 100.64.0.7).",
            approvalId: "pa_1"
        )
        let alert = PushAlertPresentation.make(serverId: serverId, plaintext: plaintext, redacted: false)
        #expect(alert.categoryIdentifier == SessionNotificationCategory.pairingApproval)
        #expect(alert.interruption == .timeSensitive)
        #expect(alert.playsSound)
        #expect(alert.threadIdentifier == "pairing:pa_1")
        #expect(alert.userInfo == [
            "event": "pairing_approval",
            "serverId": serverId,
            "approvalId": "pa_1",
        ])
        #expect(!alert.userInfo.keys.contains("sessionId"))
    }

    @Test func deviceEnrolledPresentsActiveWithoutSound() throws {
        let plaintext = PushPlaintext(
            v: 1,
            ts: 1,
            event: .deviceEnrolled,
            title: "New Device Paired",
            body: "iPad paired (invite, 100.64.0.7).",
            deviceId: "dev_new"
        )
        let alert = PushAlertPresentation.make(serverId: serverId, plaintext: plaintext, redacted: false)
        #expect(alert.categoryIdentifier == SessionNotificationCategory.deviceEnrolled)
        #expect(alert.interruption == .active)
        #expect(!alert.playsSound)
        #expect(alert.threadIdentifier == "device:dev_new")
        #expect(alert.userInfo == [
            "event": "device_enrolled",
            "serverId": serverId,
            "deviceId": "dev_new",
        ])
    }

    @Test func appLockAndServerLockRedactPairingEvents() {
        let plaintext = PushPlaintext(
            v: 1,
            ts: 1,
            event: .pairingApproval,
            title: "Approve New Device?",
            body: "iPad wants to pair (invite, 100.64.0.7).",
            approvalId: "pa_1"
        )
        let appLock = PushRedactionSnapshot(appLockEnabled: true, lockedScopes: [])
        #expect(appLock.redacts(serverId: serverId, plaintext: plaintext))
        let serverLock = PushRedactionSnapshot(
            appLockEnabled: false,
            lockedScopes: [.init(serverId: serverId, workspaceId: nil, sessionId: nil)]
        )
        #expect(serverLock.redacts(serverId: serverId, plaintext: plaintext))

        let redacted = PushAlertPresentation.make(serverId: serverId, plaintext: plaintext, redacted: true)
        #expect(redacted.title == String(localized: "Approve New Device?"))
        #expect(redacted.body == String(localized: "A new device is waiting for your approval."))
        #expect(redacted.subtitle.isEmpty)
    }

    @Test func workspaceAndSessionLocksDoNotRedactPairingEvents() {
        let approval = PushPlaintext(
            v: 1,
            ts: 1,
            event: .pairingApproval,
            workspaceId: "w1",
            title: "Approve New Device?",
            body: "iPad wants to pair.",
            approvalId: "pa_1"
        )
        let enrolled = PushPlaintext(
            v: 1,
            ts: 1,
            event: .deviceEnrolled,
            title: "New Device Paired",
            body: "iPad paired.",
            deviceId: "dev_new"
        )
        let snapshot = PushRedactionSnapshot(
            appLockEnabled: false,
            lockedScopes: [
                .init(serverId: serverId, workspaceId: "w1", sessionId: nil),
                .init(serverId: serverId, workspaceId: nil, sessionId: "s1"),
            ]
        )
        #expect(!snapshot.redacts(serverId: serverId, plaintext: approval))
        #expect(!snapshot.redacts(serverId: serverId, plaintext: enrolled))

        let enrolledRedacted = PushAlertPresentation.make(serverId: serverId, plaintext: enrolled, redacted: true)
        #expect(enrolledRedacted.title == String(localized: "New Device Paired"))
        #expect(enrolledRedacted.body == String(localized: "A new device was paired with your server."))
    }

    private func decode(_ json: String) throws -> PushPlaintext {
        try JSONDecoder().decode(PushPlaintext.self, from: Data(json.utf8))
    }

    private func padded(_ json: String) -> Data {
        var data = Data([UInt8(json.utf8.count >> 8), UInt8(json.utf8.count & 0xff)])
        data.append(contentsOf: json.utf8)
        data.append(contentsOf: repeatElement(0, count: PushEnvelope.paddedPlaintextLength - data.count))
        return data
    }
}
