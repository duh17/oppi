import CryptoKit
import Foundation
import Security

enum WebSocketOpcode: UInt8, Sendable, Equatable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool {
        rawValue >= 0x8
    }
}

enum WebSocketDecodedFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case close(code: UInt16, reason: Data)
    case ping(Data)
    case pong(Data)
}

/// RFC 6455 frame codec and HTTP upgrade helpers.
///
/// Client frames are always masked. Incoming messages are capped at 16 MiB.
/// Per-message compression is not negotiated.
enum WebSocketFrameCodec {
    static let maxMessageBytes = 16 * 1024 * 1024
    static let maxControlPayloadBytes = 125
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func makeKey(random: (Int) -> Data = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }) -> String {
        random(16).base64EncodedString()
    }

    static func acceptKey(for clientKey: String) -> String {
        let material = Data((clientKey + acceptGUID).utf8)
        let digest = Insecure.SHA1.hash(data: material)
        return Data(digest).base64EncodedString()
    }

    static func encodeUpgradeRequest(
        path: String,
        headers: [String: String],
        key: String
    ) -> Data {
        var headerLines = [
            "GET \(path) HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        for name in headers.keys.sorted() {
            headerLines.append("\(name): \(headers[name] ?? "")")
        }
        return Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func parseUpgradeResponse(_ buffer: Data) throws -> (
        status: Int,
        headers: [String: String],
        remainder: Data
    )? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw WebSocketTransportError.handshakeFailed("Invalid HTTP upgrade response")
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw WebSocketTransportError.handshakeFailed("Missing HTTP status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]) else {
            throw WebSocketTransportError.handshakeFailed("Invalid HTTP status line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }
        let remainder = buffer.subdata(in: headerRange.upperBound..<buffer.endIndex)
        return (statusCode, headers, remainder)
    }

    static func validateUpgrade(
        status: Int,
        headers: [String: String],
        clientKey: String
    ) throws {
        guard status == 101 else {
            throw WebSocketTransportError.upgradeRejected(statusCode: status)
        }
        let upgrade = headers["upgrade"]?.lowercased() ?? ""
        let connection = headers["connection"]?.lowercased() ?? ""
        guard upgrade == "websocket" else {
            throw WebSocketTransportError.handshakeFailed("Missing Upgrade: websocket")
        }
        guard connection.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
            .contains("upgrade") else {
            throw WebSocketTransportError.handshakeFailed("Missing Connection: Upgrade")
        }
        let expected = acceptKey(for: clientKey)
        guard headers["sec-websocket-accept"] == expected else {
            throw WebSocketTransportError.handshakeFailed("Invalid Sec-WebSocket-Accept")
        }
        if let extensions = headers["sec-websocket-extensions"], !extensions.isEmpty {
            throw WebSocketTransportError.handshakeFailed("Per-message compression is not supported")
        }
    }

    static func encodeFrame(
        opcode: WebSocketOpcode,
        payload: Data,
        mask: Data,
        fin: Bool = true
    ) throws -> Data {
        precondition(mask.count == 4, "WebSocket mask must be 4 bytes")
        if opcode.isControl {
            guard fin else {
                throw WebSocketTransportError.invalidFrame("Control frames cannot be fragmented")
            }
            guard payload.count <= maxControlPayloadBytes else {
                throw WebSocketTransportError.invalidFrame("Control frame payload exceeds 125 bytes")
            }
        }
        guard payload.count <= maxMessageBytes else {
            throw WebSocketTransportError.messageTooLarge
        }

        var header = Data(count: 2)
        header[0] = (fin ? 0x80 : 0x00) | opcode.rawValue
        let length = payload.count
        var extended = Data()
        if length <= 125 {
            header[1] = 0x80 | UInt8(length)
        } else if length <= 0xFFFF {
            header[1] = 0x80 | 126
            var value = UInt16(length).bigEndian
            extended = Data(bytes: &value, count: 2)
        } else {
            header[1] = 0x80 | 127
            var value = UInt64(length).bigEndian
            extended = Data(bytes: &value, count: 8)
        }

        var masked = payload
        for index in masked.indices {
            masked[index] ^= mask[mask.startIndex + (index - masked.startIndex) % 4]
        }
        return header + extended + mask + masked
    }

    static func encodeClose(code: UInt16, reason: Data = Data(), mask: Data) throws -> Data {
        var payload = Data(count: 2)
        payload[0] = UInt8(code >> 8)
        payload[1] = UInt8(code & 0xFF)
        payload.append(reason)
        return try encodeFrame(opcode: .close, payload: payload, mask: mask)
    }
}

struct WebSocketFrameDecoder: Sendable {
    private var buffer = Data()
    private var fragmentOpcode: WebSocketOpcode?
    private var fragmentPayload = Data()

    mutating func append(_ data: Data) throws -> [WebSocketDecodedFrame] {
        if !data.isEmpty {
            buffer.append(data)
        }
        var frames: [WebSocketDecodedFrame] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func nextFrame() throws -> WebSocketDecodedFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let fin = (first & 0x80) != 0
        let rsv = first & 0x70
        guard rsv == 0 else {
            throw WebSocketTransportError.invalidFrame("RSV bits must be zero")
        }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw WebSocketTransportError.invalidFrame("Reserved opcode")
        }
        let masked = (second & 0x80) != 0
        var payloadLength = Int(second & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLength = Int(readUInt16(at: offset))
            offset += 2
        } else if payloadLength == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            let extended = readUInt64(at: offset)
            guard extended <= UInt64(WebSocketFrameCodec.maxMessageBytes) else {
                throw WebSocketTransportError.messageTooLarge
            }
            payloadLength = Int(extended)
            offset += 8
        }

        if opcode.isControl {
            guard fin else {
                throw WebSocketTransportError.invalidFrame("Control frames cannot be fragmented")
            }
            guard payloadLength <= WebSocketFrameCodec.maxControlPayloadBytes else {
                throw WebSocketTransportError.invalidFrame("Control frame payload exceeds 125 bytes")
            }
        }

        let maskLength = masked ? 4 : 0
        let total = offset + maskLength + payloadLength
        guard buffer.count >= total else { return nil }
        if !opcode.isControl {
            let assembled = (fragmentPayload.count) + payloadLength
            if assembled > WebSocketFrameCodec.maxMessageBytes {
                throw WebSocketTransportError.messageTooLarge
            }
        }

        let maskStart = buffer.startIndex + offset
        let payloadStart = maskStart + maskLength
        let payloadEnd = payloadStart + payloadLength
        var payload = buffer.subdata(in: payloadStart..<payloadEnd)
        if masked {
            let mask = buffer.subdata(in: maskStart..<payloadStart)
            for index in payload.indices {
                payload[index] ^= mask[mask.startIndex + (index - payload.startIndex) % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)

        if opcode.isControl {
            return try decodeControl(opcode: opcode, payload: payload)
        }
        return try assembleData(opcode: opcode, payload: payload, fin: fin)
    }

    private mutating func assembleData(
        opcode: WebSocketOpcode,
        payload: Data,
        fin: Bool
    ) throws -> WebSocketDecodedFrame? {
        switch opcode {
        case .continuation:
            guard fragmentOpcode != nil else {
                throw WebSocketTransportError.invalidFrame("Continuation without a start frame")
            }
            fragmentPayload.append(payload)
        case .text, .binary:
            guard fragmentOpcode == nil else {
                throw WebSocketTransportError.invalidFrame("New data frame while fragmenting")
            }
            if !fin {
                fragmentOpcode = opcode
                fragmentPayload = payload
                return nil
            }
            return try completeData(opcode: opcode, payload: payload)
        case .close, .ping, .pong:
            throw WebSocketTransportError.invalidFrame("Unexpected control opcode on data path")
        }

        if fin {
            let start = fragmentOpcode ?? opcode
            let complete = fragmentPayload
            fragmentOpcode = nil
            fragmentPayload = Data()
            return try completeData(opcode: start, payload: complete)
        }
        return nil
    }

    private func completeData(opcode: WebSocketOpcode, payload: Data) throws -> WebSocketDecodedFrame {
        switch opcode {
        case .text:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw WebSocketTransportError.invalidUTF8
            }
            return .text(text)
        case .binary:
            return .binary(payload)
        default:
            throw WebSocketTransportError.invalidFrame("Invalid data opcode")
        }
    }

    private func decodeControl(opcode: WebSocketOpcode, payload: Data) throws -> WebSocketDecodedFrame {
        switch opcode {
        case .ping:
            return .ping(payload)
        case .pong:
            return .pong(payload)
        case .close:
            if payload.isEmpty {
                return .close(code: 1005, reason: Data())
            }
            guard payload.count >= 2 else {
                throw WebSocketTransportError.invalidFrame("Close payload must be empty or at least 2 bytes")
            }
            let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
            return .close(code: code, reason: payload.dropFirst(2))
        default:
            throw WebSocketTransportError.invalidFrame("Invalid control opcode")
        }
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        let start = buffer.startIndex + offset
        return UInt16(buffer[start]) << 8 | UInt16(buffer[start + 1])
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        let start = buffer.startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(buffer[start + index])
        }
        return value
    }
}
