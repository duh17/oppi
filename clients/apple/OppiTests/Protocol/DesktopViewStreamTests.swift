import Foundation
import Testing
@testable import Oppi

@Suite("Desktop view stream protocol")
struct DesktopViewStreamTests {
    @Test func phoneControlMessagesDecodeFromFixture() throws {
        let messages = try loadFixture()
        let helloJSON = try json(messages, key: "phone.hello")
        let hello = try #require(DesktopViewPhoneInbound.parse(helloJSON))
        guard case .hello(let hello) = hello else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.version == 1)
        #expect(hello.features == ["h264-avcc"])
        #expect(hello.grantId == "11111111-1111-4111-8111-111111111111")
        #expect(hello.deviceId == "dev-paired-1")
        #expect(hello.surface.windowId == 42)
        #expect(hello.surface.title == "Notes")
        #expect(hello.expiresAt == "2026-10-10T12:00:00.000Z")

        let ping = try #require(DesktopViewPhoneInbound.parse(try json(messages, key: "phone.ping")))
        guard case .ping(let ping) = ping else {
            Issue.record("expected ping")
            return
        }
        #expect(ping.t == 1_770_000_000_000)

        let error = try #require(DesktopViewPhoneInbound.parse(try json(messages, key: "phone.error_grant_revoked")))
        guard case .error(let error) = error else {
            Issue.record("expected error")
            return
        }
        #expect(error.code == 4104)
        #expect(error.fatal == true)
        #expect(error.message == "View grant revoked")
    }

    @Test func unknownControlTypeIsSkipped() throws {
        let messages = try loadFixture()
        let inbound = try #require(DesktopViewPhoneInbound.parse(try json(messages, key: "compat.unknown_type")))
        guard case .ignored(let type) = inbound else {
            Issue.record("expected ignored")
            return
        }
        #expect(type == "future_control")
    }

    @Test func ackAndPongMatchFixtureShape() throws {
        let messages = try loadFixture()
        let ack = try JSONSerialization.jsonObject(with: DesktopViewPhoneOutbound.ack(
            frameId: 1,
            receivedAt: 1_770_000_000_100
        ).encode()) as? [String: Any]
        let expectedAck = try JSONSerialization.jsonObject(with: try json(messages, key: "phone.ack")) as? [String: Any]
        #expect(ack?["type"] as? String == "ack")
        #expect(ack?["frameId"] as? Int == expectedAck?["frameId"] as? Int)
        #expect(ack?["receivedAt"] as? Int == expectedAck?["receivedAt"] as? Int)

        let pong = try JSONSerialization.jsonObject(with: DesktopViewPhoneOutbound.pong(t: 1_770_000_000_000).encode()) as? [String: Any]
        let expectedPong = try JSONSerialization.jsonObject(with: try json(messages, key: "phone.pong")) as? [String: Any]
        #expect(pong?["type"] as? String == "pong")
        #expect(pong?["t"] as? Int == expectedPong?["t"] as? Int)
    }

    @Test func wireConstantsMatchFixture() throws {
        let messages = try loadFixture()
        let wire = try #require(messages["wire"] as? [String: Any])
        #expect(wire["streamPath"] as? String == DesktopViewStream.path)
        #expect(wire["version"] as? Int == Int(DesktopViewStream.wireVersion))
        #expect(wire["mediaHeaderBytes"] as? Int == DesktopViewStream.mediaHeaderBytes)
        #expect(wire["avcc"] as? Bool == true)
        let fatal = try #require(wire["fatalErrorRange"] as? [String: Int])
        #expect(fatal["min"] == DesktopViewStream.fatalErrorMin)
        #expect(fatal["max"] == DesktopViewStream.fatalErrorMax)
        let errors = try #require(wire["errors"] as? [String: Int])
        #expect(errors["grantRevoked"] == DesktopViewStream.ErrorCode.grantRevoked)
        #expect(errors["surfaceGone"] == DesktopViewStream.ErrorCode.surfaceGone)
        #expect(errors["alreadyStreaming"] == DesktopViewStream.ErrorCode.alreadyStreaming)
        #expect(errors["companionUnavailable"] == DesktopViewStream.ErrorCode.companionUnavailable)
        #expect(DesktopViewStream.isFatalErrorCode(4100))
        #expect(DesktopViewStream.isFatalErrorCode(4109))
        #expect(!DesktopViewStream.isFatalErrorCode(4001))
        #expect(!DesktopViewStream.isFatalErrorCode(4002))
        #expect(!DesktopViewStream.isFatalErrorCode(4110))
        #expect(!DesktopViewStream.isFatalErrorCode(4199))
        #expect(!DesktopViewStream.isFatalErrorCode(4099))
        #expect(!DesktopViewStream.isFatalErrorCode(4200))
    }

    @Test func mediaHeaderRoundTripAndRejectsTruncation() throws {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        let encoded = DesktopViewMediaCodec.encodeFrame(
            header: DesktopViewMediaHeader(
                version: 1,
                keyframe: true,
                frameId: 7,
                capturedAtMs: 1_770_000_000_007,
                width: 640,
                height: 360,
                payloadBytes: 0
            ),
            payload: payload
        )
        #expect(encoded.count == DesktopViewStream.mediaHeaderBytes + payload.count)
        let parsed = try DesktopViewMediaCodec.parseFrame(encoded)
        #expect(parsed.header.keyframe)
        #expect(parsed.header.frameId == 7)
        #expect(parsed.header.capturedAtMs == 1_770_000_000_007)
        #expect(parsed.header.width == 640)
        #expect(parsed.header.height == 360)
        #expect(parsed.payload == payload)

        #expect(throws: DesktopViewMediaParseError.truncated) {
            try DesktopViewMediaCodec.parseFrame(Data(encoded.dropLast()))
        }
        var badVersion = encoded
        badVersion[0] = 2 as UInt8
        #expect(throws: DesktopViewMediaParseError.unsupportedVersion(2)) {
            try DesktopViewMediaCodec.parseFrame(badVersion)
        }
    }

    private func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: snapshotURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["messages"] as? [String: Any] ?? [:]
    }

    private func json(_ messages: [String: Any], key: String) throws -> Data {
        let value = try #require(messages[key])
        return try JSONSerialization.data(withJSONObject: value)
    }

    private var snapshotURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/desktop-view-stream.json")
    }
}
