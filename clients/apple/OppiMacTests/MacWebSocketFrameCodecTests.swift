import Foundation
import Testing
@testable import Oppi

@Suite("Mac WebSocket frame codec")
struct MacWebSocketFrameCodecTests {
    @Test func rfc6455AcceptKeyMatchesKnownVector() {
        let accept = WebSocketFrameCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func upgradeRequestUsesOwnerBearerAndNoHTTPS() {
        let encoded = String(
            data: WebSocketFrameCodec.encodeUpgradeRequest(
                path: "/app/events/stream",
                headers: ["Authorization": "Bearer sk_owner"],
                key: "dGhlIHNhbXBsZSBub25jZQ=="
            ),
            encoding: .utf8
        ) ?? ""
        #expect(encoded.hasPrefix("GET /app/events/stream HTTP/1.1\r\n"))
        #expect(encoded.contains("Authorization: Bearer sk_owner"))
        #expect(encoded.contains("Upgrade: websocket"))
        #expect(encoded.contains("Sec-WebSocket-Version: 13"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("7749"))
        #expect(!encoded.lowercased().contains("permessage-deflate"))
    }

    @Test func parseAndValidateSuccessfulUpgrade() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        var raw = Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)
        raw.append(Data("Upgrade: websocket\r\nConnection: Upgrade\r\n".utf8))
        raw.append(Data("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\nleftover".utf8))
        let parsed = try #require(try WebSocketFrameCodec.parseUpgradeResponse(raw))
        #expect(parsed.status == 101)
        try WebSocketFrameCodec.validateUpgrade(status: parsed.status, headers: parsed.headers, clientKey: key)
        #expect(String(data: parsed.remainder, encoding: .utf8) == "leftover")
    }

    @Test func rejectNon101AndCompressionExtensions() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        do {
            try WebSocketFrameCodec.validateUpgrade(
                status: 401,
                headers: ["upgrade": "websocket", "connection": "Upgrade"],
                clientKey: key
            )
            Issue.record("Expected 401 handshake to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .upgradeRejected(statusCode: 401))
        }
        do {
            try WebSocketFrameCodec.validateUpgrade(
                status: 101,
                headers: [
                    "upgrade": "websocket",
                    "connection": "Upgrade",
                    "sec-websocket-accept": WebSocketFrameCodec.acceptKey(for: key),
                    "sec-websocket-extensions": "permessage-deflate",
                ],
                clientKey: key
            )
            Issue.record("Expected compression extension to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .handshakeFailed("Per-message compression is not supported"))
        }
    }

    @Test func masksAndUnmasksTextRoundTrip() throws {
        let mask = Data([0x37, 0xFA, 0x21, 0x3D])
        let encoded = try WebSocketFrameCodec.encodeFrame(
            opcode: .text,
            payload: Data("Hello".utf8),
            mask: mask
        )
        #expect(encoded[1] & 0x80 != 0)
        var decoder = WebSocketFrameDecoder()
        #expect(try decoder.append(encoded) == [.text("Hello")])
    }

    @Test func encodesExtendedSixteenBitLength() throws {
        let payload = Data(repeating: 0x61, count: 200)
        let encoded = try WebSocketFrameCodec.encodeFrame(opcode: .binary, payload: payload, mask: Data([1, 2, 3, 4]))
        #expect(encoded[1] & 0x7F == 126)
        var decoder = WebSocketFrameDecoder()
        #expect(try decoder.append(encoded) == [.binary(payload)])
    }

    @Test func encodesSixtyFourBitLength() throws {
        let payload = Data(repeating: 0x62, count: 70_000)
        let encoded = try WebSocketFrameCodec.encodeFrame(opcode: .binary, payload: payload, mask: Data([9, 8, 7, 6]))
        #expect(encoded[1] & 0x7F == 127)
        var decoder = WebSocketFrameDecoder()
        #expect(try decoder.append(encoded) == [.binary(payload)])
    }

    @Test func reassemblesFragmentedText() throws {
        let first = try WebSocketFrameCodec.encodeFrame(
            opcode: .text,
            payload: Data("Hel".utf8),
            mask: Data([1, 1, 1, 1]),
            fin: false
        )
        let second = try WebSocketFrameCodec.encodeFrame(
            opcode: .continuation,
            payload: Data("lo".utf8),
            mask: Data([2, 2, 2, 2])
        )
        var decoder = WebSocketFrameDecoder()
        #expect(try decoder.append(first).isEmpty)
        #expect(try decoder.append(second) == [.text("Hello")])
    }

    @Test func rejectsFragmentedAndOversizedControlFrames() throws {
        let fragmented = Data([0x09, 0x01, 0x00])
        var decoder = WebSocketFrameDecoder()
        do {
            _ = try decoder.append(fragmented)
            Issue.record("Expected fragmented ping to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .invalidFrame("Control frames cannot be fragmented"))
        }

        var oversized = Data([0x89, 0x7E, 0x00, 0x7E])
        oversized.append(Data(repeating: 0x21, count: 126))
        decoder = WebSocketFrameDecoder()
        do {
            _ = try decoder.append(oversized)
            Issue.record("Expected oversized ping to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .invalidFrame("Control frame payload exceeds 125 bytes"))
        }
    }

    @Test func rejectsInvalidUTF8AndRSV() throws {
        let invalidUTF8 = try WebSocketFrameCodec.encodeFrame(
            opcode: .text,
            payload: Data([0xC3, 0x28]),
            mask: Data([0, 0, 0, 0])
        )
        var decoder = WebSocketFrameDecoder()
        do {
            _ = try decoder.append(invalidUTF8)
            Issue.record("Expected invalid UTF-8 to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .invalidUTF8)
        }

        decoder = WebSocketFrameDecoder()
        do {
            _ = try decoder.append(Data([0xC1, 0x00]))
            Issue.record("Expected RSV bits to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .invalidFrame("RSV bits must be zero"))
        }
    }

    @Test func rejectsMessagesOverSixteenMebibytes() throws {
        var header = Data([0x82, 127])
        var length = UInt64(WebSocketFrameCodec.maxMessageBytes + 1).bigEndian
        header.append(Data(bytes: &length, count: 8))
        var decoder = WebSocketFrameDecoder()
        do {
            _ = try decoder.append(header)
            Issue.record("Expected oversized message to fail")
        } catch let error as WebSocketTransportError {
            #expect(error == .messageTooLarge)
        }
    }

    @Test func decodesClosePingAndPong() throws {
        let close = try WebSocketFrameCodec.encodeClose(code: 1000, reason: Data("bye".utf8), mask: Data([3, 3, 3, 3]))
        let ping = try WebSocketFrameCodec.encodeFrame(opcode: .ping, payload: Data("hi".utf8), mask: Data([4, 4, 4, 4]))
        let pong = try WebSocketFrameCodec.encodeFrame(opcode: .pong, payload: Data("hi".utf8), mask: Data([5, 5, 5, 5]))
        var decoder = WebSocketFrameDecoder()
        #expect(try decoder.append(close + ping + pong) == [
            .close(code: 1000, reason: Data("bye".utf8)),
            .ping(Data("hi".utf8)),
            .pong(Data("hi".utf8)),
        ])
    }
}
