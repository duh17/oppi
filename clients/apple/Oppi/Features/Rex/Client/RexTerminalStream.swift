import Foundation

/// A Rex data connection's binary handshake: the client's HELLO with the
/// one-time ticket from `data.connect`, then the server's WELCOME or REJECT.
/// Integers are little-endian, as the server's API page describes.
enum RexDataHandshake {
    struct Welcome: Equatable, Sendable {
        let reconnectToken: Data
        /// How long the server keeps the stream for a resume.
        let keepMilliseconds: UInt32
        /// Marks Rex's own messages in the stream, so a program cannot forge one.
        let nonce: UInt64
    }

    enum Answer: Equatable, Sendable {
        case welcome(Welcome)
        case reject(UInt8)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case malformed
        case rejected(UInt8)

        var errorDescription: String? {
            switch self {
            case .malformed: "Rex answered the pane's stream with something Oppi cannot read."
            case .rejected(let reason): "Rex refused the pane's stream: \(RexDataHandshake.rejectReason(reason))"
            }
        }
    }

    static func hello(ticket: Data) -> Data { Data([0x01]) + ticket }

    /// RESUME: the latest WELCOME's token, then the stream bytes received so
    /// far as a 64-bit little-endian integer.
    static func resume(token: Data, received: UInt64) -> Data {
        Data([0x02]) + token + Data((0..<8).map { UInt8((received >> ($0 * 8)) & 0xFF) })
    }

    static func answer(_ message: Data) throws -> Answer {
        let bytes = [UInt8](message)
        switch bytes.first {
        case 0x81 where bytes.count == 32:
            func integer<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
                (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(bytes[offset + $1]) << ($1 * 8) }
            }
            return .welcome(.init(
                reconnectToken: Data(bytes[1..<17]),
                keepMilliseconds: integer(UInt32.self, at: 20),
                nonce: integer(UInt64.self, at: 24)
            ))
        case 0x82 where bytes.count >= 2:
            return .reject(bytes[1])
        default:
            throw Failure.malformed
        }
    }

    static func rejectReason(_ code: UInt8) -> String {
        switch code {
        case 0x01: "the ticket expired or was already used, or the session is gone."
        case 0x02: "this client already has a stream of that pane."
        case 0x03: "the pane is not available."
        case 0x04: "too many streams are open."
        case 0x05: "the handshake was malformed or too slow."
        case 0x07: "the ticket was for another kind of stream."
        default: "the server failed (reason \(code))."
        }
    }
}

/// One Rex terminal stream, split into what each part is for. It starts with a
/// snapshot of the terminal in Ghostty's snapshot format; then comes the
/// program's output, with Rex's own messages placed where they are safe to
/// apply: `ESC _ rex1;<nonce>;<json> ESC \`. Only a message carrying this
/// stream's nonce is Rex's; a look-alike a program printed stays output.
///
/// The snapshot has no length prefix, but its records are framed
/// (`SSHTerminalSnapshotFormat`): it is cut into whole records as they
/// arrive. Everything through READY is the screen, ready to draw; the records
/// after it (older history, image pixels) follow as they complete, and the
/// snapshot ends with its FINISH record. Output starts right after FINISH.
struct RexTerminalStream {
    enum Message: Equatable, Sendable {
        case resize(columns: Int, rows: Int)
        case childExited(code: Int)
        /// A `theme`, or a type a newer Rex adds.
        case other(type: String)
    }

    enum Piece: Equatable, Sendable {
        /// The snapshot's envelope and every record through READY.
        case snapshot(Data)
        /// Whole snapshot records after READY, the last one ending with FINISH.
        case snapshotRecords(Data)
        case output(Data)
        case message(Message)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case snapshotTooLarge
        case notASnapshot

        var errorDescription: String? {
            switch self {
            case .snapshotTooLarge: "This pane's screen is too large to open on this device."
            case .notASnapshot: SSHTerminalSnapshotFormat.unreadable
            }
        }
    }

    private enum Phase { case envelope, screen, history, output }

    /// The engine keeps 32 MiB of history (`SSHTerminalEngine.historyLimitBytes`),
    /// and Ghostty's snapshot compresses its pages; a snapshot larger than this
    /// is not one worth holding on a phone.
    static let maximumSnapshotBytes = 64 * 1024 * 1024
    /// A message longer than this without its terminator is a program's look-alike.
    static let maximumMessageBytes = 1024 * 1024

    private let marker: Data
    private var pending = Data()
    private var phase = Phase.envelope
    /// Snapshot bytes already handed on, toward `maximumSnapshotBytes`.
    private var snapshotBytes = 0

    init(nonce: UInt64) {
        marker = Data("\u{1B}_rex1;\(nonce);".utf8)
    }

    mutating func receive(_ bytes: Data) throws -> [Piece] {
        pending.append(bytes)
        var pieces: [Piece] = []
        if phase != .output {
            try readSnapshot(into: &pieces)
            guard phase == .output else { return pieces }
        }
        while !pending.isEmpty {
            guard let found = pending.range(of: marker) else {
                // Hold back a tail that could be the start of a message.
                let keep = heldTail()
                let cut = pending.endIndex - keep
                if cut > pending.startIndex {
                    pieces.append(.output(Data(pending[pending.startIndex..<cut])))
                    pending.removeSubrange(pending.startIndex..<cut)
                }
                break
            }
            if found.lowerBound > pending.startIndex {
                pieces.append(.output(Data(pending[pending.startIndex..<found.lowerBound])))
            }
            guard let end = pending.range(of: Data([0x1B, 0x5C]), in: found.upperBound..<pending.endIndex) else {
                if pending.endIndex - found.lowerBound > Self.maximumMessageBytes {
                    // No terminator in reach: not Rex's. Pass it on as output.
                    pieces.append(.output(Data(pending[found.lowerBound..<found.upperBound])))
                    pending.removeSubrange(pending.startIndex..<found.upperBound)
                    continue
                }
                pending.removeSubrange(pending.startIndex..<found.lowerBound)
                break
            }
            pieces.append(.message(Self.message(Data(pending[found.upperBound..<end.lowerBound]))))
            pending.removeSubrange(pending.startIndex..<end.upperBound)
        }
        return pieces
    }

    /// Hands on the snapshot's whole records: the screen once READY is in, then
    /// the records after it as they complete, until FINISH.
    private mutating func readSnapshot(into pieces: inout [Piece]) throws {
        typealias Format = SSHTerminalSnapshotFormat
        if phase == .envelope {
            guard let readable = Format.envelopeIsReadable(pending) else { return }
            guard readable else { throw Failure.notASnapshot }
            phase = .screen
        }
        // Records start after the envelope until the screen is handed on.
        var offset = phase == .screen ? Format.envelopeBytes : 0
        var cut = 0
        // `pending` starts where the snapshot bytes handed on so far end.
        let base = snapshotBytes
        func handOn(_ piece: (Data) -> Piece) {
            pieces.append(piece(Data(pending[(pending.startIndex + cut)..<(pending.startIndex + offset)])))
            snapshotBytes = base + offset
            cut = offset
        }
        while let record = Format.record(in: pending, at: offset) {
            guard base + offset + record.length <= Self.maximumSnapshotBytes else { throw Failure.snapshotTooLarge }
            guard pending.count - offset >= record.length else { break }
            offset += record.length
            if phase == .screen, record.tag == Format.Tag.ready.rawValue {
                handOn(Piece.snapshot)
                phase = .history
            } else if phase == .history, record.tag == Format.Tag.finish.rawValue {
                handOn(Piece.snapshotRecords)
                phase = .output
                break
            }
        }
        if phase == .history, offset > cut {
            handOn(Piece.snapshotRecords)
        }
        if cut > 0 {
            pending.removeSubrange(pending.startIndex..<(pending.startIndex + cut))
        }
    }

    /// The longest end of `pending` that is a proper prefix of the marker.
    private func heldTail() -> Int {
        let limit = min(marker.count - 1, pending.count)
        for length in stride(from: limit, to: 0, by: -1)
        where pending.suffix(length).elementsEqual(marker.prefix(length)) {
            return length
        }
        return 0
    }

    private static func message(_ json: Data) -> Message {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String else { return .other(type: "") }
        switch type {
        case "resize":
            guard let columns = object["cols"] as? Int, let rows = object["rows"] as? Int else { return .other(type: type) }
            return .resize(columns: columns, rows: rows)
        case "child_exited":
            return .childExited(code: object["exit_code"] as? Int ?? 0)
        default:
            return .other(type: type)
        }
    }
}

/// A pane's data connection (`/api/data`, `rex.data.terminal.v1`) as a state
/// machine: the socket's messages in, what the terminal gets out. The socket
/// opens and upgrades while `data.connect` is still issuing its ticket; its
/// owner sends `hello(ticket:)` once both are in. It reads WELCOME for the
/// stream's nonce, then splits the stream (`RexTerminalStream`).
struct RexDataStream {
    enum Output: Equatable, Sendable {
        /// The snapshot's screen (`RexTerminalStream.Piece.snapshot`).
        case snapshot(Data)
        /// Its records after READY (`RexTerminalStream.Piece.snapshotRecords`).
        case snapshotRecords(Data)
        case output(Data)
        case exited(code: Int)
        /// Rex closed the pane (close code 4000). Nothing follows it.
        case paneClosed
        /// The stream is over, and why. Nothing follows it.
        case ended(String)
        /// Rex would not continue the stream (`resume()`); a new one starts
        /// with a ticket and a snapshot. Nothing follows it.
        case resumeRefused
    }

    private var terminal: RexTerminalStream?
    private var over = false
    /// The newest WELCOME's reconnect token, and the stream bytes this side
    /// has used since the first WELCOME, across every connection of the
    /// stream: what a RESUME on a new connection carries.
    private var token: Data?
    private var received: UInt64 = 0
    /// A RESUME went out; the next message is Rex's answer to it.
    private var resuming = false
    private var nonce: UInt64?

    /// HELLO with the ticket `data.connect` issued: the first message on the open socket.
    static func hello(ticket: Data) -> RexSocketMessage { .binary(RexDataHandshake.hello(ticket: ticket)) }

    /// RESUME, for the first message on a new connection after this stream's
    /// dropped, or nil when Rex never welcomed it: the same parser then reads
    /// on from the first byte it has not used.
    mutating func resume() -> RexSocketMessage? {
        guard let token, !over else { return nil }
        resuming = true
        return .binary(RexDataHandshake.resume(token: token, received: received))
    }

    mutating func receive(_ message: RexSocketMessage) -> [Output] {
        guard !over else { return [] }
        do {
            return try deliver(message)
        } catch {
            over = true
            return [.ended(error.localizedDescription)]
        }
    }

    private mutating func deliver(_ message: RexSocketMessage) throws -> [Output] {
        switch message {
        case .binary(let payload):
            if resuming {
                resuming = false
                switch try? RexDataHandshake.answer(payload) {
                case .welcome(let welcome)? where welcome.nonce == nonce:
                    token = welcome.reconnectToken
                    return []
                default:
                    over = true
                    return [.resumeRefused]
                }
            }
            guard var stream = terminal else {
                switch try RexDataHandshake.answer(payload) {
                case .welcome(let welcome):
                    terminal = RexTerminalStream(nonce: welcome.nonce)
                    token = welcome.reconnectToken
                    nonce = welcome.nonce
                    return []
                case .reject(let code):
                    throw RexDataHandshake.Failure.rejected(code)
                }
            }
            received &+= UInt64(payload.count)
            let pieces = try stream.receive(payload)
            terminal = stream
            return pieces.compactMap { piece in
                switch piece {
                case .snapshot(let snapshot): .snapshot(snapshot)
                case .snapshotRecords(let records): .snapshotRecords(records)
                case .output(let output): .output(output)
                case .message(.childExited(let code)): .exited(code: code)
                // Resize and theme: who sizes the pane is followed by its owner
                // (`block_owner_changed`), and this client keeps its own colors.
                case .message: nil
                }
            }
        case .close(let code, let reason):
            over = true
            if code == 4000 { return [.paneClosed] }
            return [.ended(reason.isEmpty ? "Rex ended the pane's stream." : "Rex ended the pane's stream: \(reason).")]
        case .text:
            return []
        }
    }
}
