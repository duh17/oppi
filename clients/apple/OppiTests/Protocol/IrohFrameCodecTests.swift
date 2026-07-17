import Foundation
import Testing
@testable import Oppi

@Suite("Iroh frame codec")
struct IrohFrameCodecTests {
    @Test func encodeDecodeRoundTripAddsBodyLength() throws {
        let body = Data("hello".utf8)
        let encoded = try IrohFrameCodec.encode(header: [
            "v": 1,
            "kind": "response",
        ], body: body)

        let decoded = try IrohFrameCodec.decode(encoded)

        #expect(decoded.header["v"] == 1)
        #expect(decoded.header["kind"] == "response")
        #expect(decoded.header["bodyLength"] == 5)
        #expect(decoded.body == body)
    }

    @Test func rejectsMismatchedBodyLength() throws {
        #expect(throws: IrohFrameCodecError.bodyLengthMismatch(expected: 10, actual: 2)) {
            _ = try IrohFrameCodec.encode(header: ["bodyLength": 10], body: Data([1, 2]))
        }
    }

    @Test func rejectsMalformedAndNonObjectHeaders() throws {
        let malformed = Data([0, 0, 0, 1, 0x7b])
        #expect(throws: IrohFrameCodecError.malformedJSON) {
            _ = try IrohFrameCodec.decode(malformed)
        }

        let arrayHeader = Data([0, 0, 0, 2]) + Data("[]".utf8)
        #expect(throws: IrohFrameCodecError.invalidHeader) {
            _ = try IrohFrameCodec.decode(arrayHeader)
        }
    }

    @Test func rejectsTruncatedBodyAndTrailingBytes() throws {
        let truncated = try IrohFrameCodec.encode(header: ["bodyLength": 3], body: Data([1, 2, 3])).dropLast()
        #expect(throws: IrohFrameCodecError.truncatedBody) {
            _ = try IrohFrameCodec.decode(Data(truncated))
        }

        var trailing = try IrohFrameCodec.encode(header: ["kind": "ok"])
        trailing.append(0xff)
        #expect(throws: IrohFrameCodecError.trailingBytes) {
            _ = try IrohFrameCodec.decode(trailing)
        }
    }

    @Test func rejectsOversizedHeaderAndBody() throws {
        let encoded = try IrohFrameCodec.encode(header: ["bodyLength": 4], body: Data([1, 2, 3, 4]))

        #expect(throws: IrohFrameCodecError.headerTooLarge(limit: 1)) {
            _ = try IrohFrameCodec.decode(encoded, maxHeaderBytes: 1)
        }
        #expect(throws: IrohFrameCodecError.bodyTooLarge(limit: 3)) {
            _ = try IrohFrameCodec.decode(encoded, maxBodyBytes: 3)
        }
    }

    @Test func redactsAuthorizationHeaders() {
        let redacted = IrohFrameCodec.redact(header: [
            "authorization": "Bearer root",
            "headers": .object([
                "Authorization": "Bearer device",
                "content-type": "application/json",
            ]),
        ])

        #expect(redacted["authorization"] == "[redacted]")
        #expect(redacted["headers"]?.objectValue?["Authorization"] == "[redacted]")
        #expect(redacted["headers"]?.objectValue?["content-type"] == "application/json")
    }
}
