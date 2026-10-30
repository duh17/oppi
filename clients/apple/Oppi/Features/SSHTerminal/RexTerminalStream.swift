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
/// The snapshot has no length prefix. Rex sends a `resize` message right after
/// it, so the snapshot is everything before the first message of this stream.
struct RexTerminalStream {
    enum Message: Equatable, Sendable {
        case resize(columns: Int, rows: Int)
        case childExited(code: Int)
        /// A `theme`, or a type a newer Rex adds.
        case other(type: String)
    }

    enum Piece: Equatable, Sendable {
        case snapshot(Data)
        case output(Data)
        case message(Message)
    }

    enum Failure: Error, Equatable {
        case snapshotTooLarge
    }

    /// The engine keeps 8 MiB of history, and Ghostty's snapshot compresses
    /// its pages; a snapshot larger than this is not one worth holding on a phone.
    static let maximumSnapshotBytes = 64 * 1024 * 1024
    /// A message longer than this without its terminator is a program's look-alike.
    static let maximumMessageBytes = 1024 * 1024

    private let marker: Data
    private var pending = Data()
    private var snapshotDone = false
    /// Where the snapshot's search for the first message resumes, so a large
    /// snapshot arriving in many reads is scanned once, not once per read.
    private var searched = 0

    init(nonce: UInt64) {
        marker = Data("\u{1B}_rex1;\(nonce);".utf8)
    }

    mutating func receive(_ bytes: Data) throws -> [Piece] {
        pending.append(bytes)
        var pieces: [Piece] = []
        if !snapshotDone {
            let from = pending.startIndex + searched
            guard let found = pending.range(of: marker, in: from..<pending.endIndex) else {
                guard pending.count <= Self.maximumSnapshotBytes else { throw Failure.snapshotTooLarge }
                searched = max(0, pending.count - marker.count + 1)
                return []
            }
            pieces.append(.snapshot(Data(pending[pending.startIndex..<found.lowerBound])))
            pending.removeSubrange(pending.startIndex..<found.lowerBound)
            snapshotDone = true
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
