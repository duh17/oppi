import Compression
import CryptoKit
import Foundation

/// The client half of a WebSocket (RFC 6455) over a byte pipe iOS cannot open
/// as a socket: an SSH exec stream to Rex's Unix socket on the host. Only what
/// Rex needs: one upgrade, text and binary messages, ping and pong, and close.
///
/// It offers compression (permessage-deflate, RFC 7692) with no context kept
/// between messages, which Rex accepts: each compressed message from Rex
/// inflates on its own. A pane's snapshot shrinks to about a fifth on the wire.
/// This client's own messages (requests, keys) go uncompressed, as the
/// extension allows.
struct RexWebSocketCodec {
    enum Message: Equatable, Sendable {
        case text(String)
        case binary(Data)
        /// The server's close frame, or nil code when it sent none.
        case close(code: UInt16?, reason: String)
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The server did not switch protocols: its status line and, when it
        /// sent one, the body's first line (Rex answers 403 with a JSON reason).
        case upgradeRefused(String)
        case protocolViolation(String)

        var errorDescription: String? {
            switch self {
            case .upgradeRefused(let status): "Rex refused the connection: \(status)"
            case .protocolViolation(let detail): "Rex sent something Oppi cannot read: \(detail)"
            }
        }
    }

    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    /// Rex's largest control message is 1 MiB and a data message 64 KiB.
    static let maximumMessageBytes = 8 * 1024 * 1024
    /// An upgrade answer longer than this is not one.
    private static let maximumHeaderBytes = 16 * 1024
    /// RFC 6455 section 1.3.
    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// RFC 7692. Without context takeover each message is a deflate stream of
    /// its own, so no inflater state outlives a message.
    static let compressionOffer = "permessage-deflate; client_no_context_takeover; server_no_context_takeover"

    let key: String
    let subprotocol: String
    private(set) var upgraded = false
    /// The server accepted `compressionOffer`: a data message may arrive compressed.
    private(set) var compressed = false
    private var buffer = Data()
    private var fragments: (opcode: Opcode, compressed: Bool, payload: Data)?

    init(subprotocol: String, key: String = Self.makeKey()) {
        self.subprotocol = subprotocol
        self.key = key
    }

    /// The `Sec-WebSocket-Accept` a server must answer `key` with.
    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
    }

    static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    /// Any host name works over a Unix socket.
    func upgradeRequest(path: String) -> Data {
        let lines: [String] = [
            "GET \(path) HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(subprotocol)",
            "Sec-WebSocket-Extensions: \(Self.compressionOffer)",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Feeds bytes as they arrive. Returns the messages they complete and the
    /// frames the client must send back (a pong for each ping) in order.
    mutating func receive(_ bytes: Data) throws -> (messages: [Message], replies: [Data]) {
        buffer.append(bytes)
        if !upgraded {
            guard try readUpgrade() else { return ([], []) }
        }
        var messages: [Message] = []
        var replies: [Data] = []
        while let frame = try nextFrame() {
            switch frame.opcode {
            case .ping:
                replies.append(Self.frame(.pong, payload: frame.payload))
            case .pong:
                break
            case .close:
                let code = frame.payload.count >= 2 ? UInt16(frame.payload[frame.payload.startIndex]) << 8 | UInt16(frame.payload[frame.payload.startIndex + 1]) : nil
                let reason = frame.payload.count > 2 ? String(decoding: frame.payload.dropFirst(2), as: UTF8.self) : ""
                messages.append(.close(code: code, reason: reason))
            case .text, .binary, .continuation:
                if let message = try assemble(frame) { messages.append(message) }
            }
        }
        return (messages, replies)
    }

    /// One masked client frame, as RFC 6455 requires of a client.
    static func frame(_ opcode: Opcode, payload: Data, mask: [UInt8]? = nil) -> Data {
        let mask = mask ?? (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> ($0 * 8)) & 0xFF) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// Reads the HTTP answer to the upgrade. True once it switched protocols;
    /// false while its headers are still arriving.
    private mutating func readUpgrade() throws -> Bool {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count < Self.maximumHeaderBytes else {
                throw Failure.upgradeRefused("an answer that is not HTTP")
            }
            return false
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        guard status.hasPrefix("HTTP/1.1 101") else {
            let body = String(decoding: buffer[end.upperBound...], as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            throw Failure.upgradeRefused(body.isEmpty ? status : "\(status) \(body)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["sec-websocket-accept"] == Self.accept(for: key) else {
            throw Failure.protocolViolation("the upgrade did not answer this connection's key")
        }
        guard headers["sec-websocket-protocol"] == subprotocol else {
            throw Failure.protocolViolation("the server chose subprotocol \(headers["sec-websocket-protocol"] ?? "none"), not \(subprotocol)")
        }
        if let extensions = headers["sec-websocket-extensions"] {
            try acceptCompression(extensions)
        }
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        upgraded = true
        return true
    }

    /// The server's answer to `compressionOffer`: the one extension, with
    /// `server_no_context_takeover`, since this client inflates each message
    /// on its own. A window size is fine: an inflater reads any window.
    private mutating func acceptCompression(_ answer: String) throws {
        let offers = answer.split(separator: ",")
        guard offers.count == 1 else { throw Failure.protocolViolation("more than one extension: \(answer)") }
        let parameters = offers[0].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parameters.first == "permessage-deflate" else {
            throw Failure.protocolViolation("an extension this client did not offer: \(answer)")
        }
        var noContextTakeover = false
        for parameter in parameters.dropFirst() {
            let name = parameter.split(separator: "=", maxSplits: 1).first.map(String.init) ?? parameter
            switch name {
            case "server_no_context_takeover": noContextTakeover = true
            case "client_no_context_takeover", "server_max_window_bits", "client_max_window_bits": break
            default: throw Failure.protocolViolation("a compression parameter this client does not know: \(parameter)")
            }
        }
        guard noContextTakeover else {
            throw Failure.protocolViolation("compression that keeps its context between messages")
        }
        compressed = true
    }

    private struct Frame {
        let fin: Bool
        /// RSV1: the message this frame starts is compressed.
        let compressed: Bool
        let opcode: Opcode
        let payload: Data
    }

    /// Reads `buffer` in place: a copy of it alive across the removal below
    /// would copy every buffered byte once per frame.
    private mutating func nextFrame() throws -> Frame? {
        let start = buffer.startIndex
        guard buffer.count >= 2 else { return nil }
        let first = buffer[start], second = buffer[start + 1]
        guard let opcode = Opcode(rawValue: first & 0x0F) else {
            throw Failure.protocolViolation("unknown frame opcode \(first & 0x0F)")
        }
        // RSV1 marks a compressed message, on its first frame only and only
        // once negotiated; RSV2 and RSV3 have no meaning here.
        let compressedFrame = first & 0x40 != 0
        guard first & 0x30 == 0, !compressedFrame || (compressed && (opcode == .text || opcode == .binary)) else {
            throw Failure.protocolViolation("a frame with reserved bits set")
        }
        guard second & 0x80 == 0 else { throw Failure.protocolViolation("a masked frame from the server") }
        var offset = 2
        var length = UInt64(second & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[start + 2 + $1]) }
            offset = 10
        }
        let fin = first & 0x80 != 0
        if opcode.rawValue >= 0x8, !fin || length > 125 {
            throw Failure.protocolViolation("a fragmented or oversized control frame")
        }
        guard length <= UInt64(Self.maximumMessageBytes) else {
            throw Failure.protocolViolation("a frame of \(length) bytes")
        }
        let total = offset + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer[(start + offset)..<(start + total)])
        buffer.removeSubrange(start..<(start + total))
        return Frame(fin: fin, compressed: compressedFrame, opcode: opcode, payload: payload)
    }

    /// A data frame, joined with the fragments before it. Nil until the
    /// message's last fragment.
    private mutating func assemble(_ frame: Frame) throws -> Message? {
        var opcode = frame.opcode
        var compressedMessage = frame.compressed
        var payload = frame.payload
        if opcode == .continuation {
            guard let started = fragments else { throw Failure.protocolViolation("a continuation with no message") }
            opcode = started.opcode
            compressedMessage = started.compressed
            payload = started.payload + payload
        } else if fragments != nil {
            throw Failure.protocolViolation("a new message inside a fragmented one")
        }
        guard payload.count <= Self.maximumMessageBytes else {
            throw Failure.protocolViolation("a message of \(payload.count) bytes")
        }
        guard frame.fin else {
            fragments = (opcode, compressedMessage, payload)
            return nil
        }
        fragments = nil
        if compressedMessage {
            payload = try Self.inflate(payload)
        }
        if opcode == .text {
            guard let text = String(data: payload, encoding: .utf8) else {
                throw Failure.protocolViolation("a text message that is not UTF-8")
            }
            return .text(text)
        }
        return .binary(payload)
    }

    /// One compressed message's payload, inflated: a raw DEFLATE stream that
    /// ends where the sender cut its sync flush (RFC 7692 7.2.2), so the
    /// empty stored block that flush ended with goes back on first. More than
    /// `maximumMessageBytes` inflated is refused, wherever the message claims to end.
    static func inflate(_ payload: Data) throws -> Data {
        let input = payload + Data([0x00, 0x00, 0xFF, 0xFF])
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.protocolViolation("no inflater")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let window = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { window.deallocate() }
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = window
                stream.pointee.dst_size = chunk
                let unread = stream.pointee.src_size
                let status = compression_stream_process(stream, 0)
                let produced = chunk - stream.pointee.dst_size
                output.append(window, count: produced)
                guard output.count <= maximumMessageBytes else {
                    throw Failure.protocolViolation("a compressed message of more than \(maximumMessageBytes) bytes")
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // Everything in, and room left over: nothing more to come.
                    if stream.pointee.src_size == 0, produced < chunk { return }
                    // No input read and no output: a stream cut short.
                    if produced == 0, stream.pointee.src_size == unread {
                        throw Failure.protocolViolation("a compressed message that ends early")
                    }
                default:
                    throw Failure.protocolViolation("a compressed message that does not inflate")
                }
            }
        }
        return output
    }
}
