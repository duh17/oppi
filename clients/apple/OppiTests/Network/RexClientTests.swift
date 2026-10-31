import Foundation
import GhosttyVt
import Synchronization
import Testing
@testable import Oppi

/// A server frame as Rex sends it: unmasked, with the shortest length form.
private func serverFrame(_ opcode: RexWebSocketCodec.Opcode, _ payload: Data, fin: Bool = true) -> Data {
    var frame = Data([(fin ? 0x80 : 0) | opcode.rawValue])
    if payload.count < 126 {
        frame.append(UInt8(payload.count))
    } else if payload.count <= 0xFFFF {
        frame.append(126)
        frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
    } else {
        frame.append(127)
        frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 0xFF) })
    }
    return frame + payload
}

/// A client frame's payload, unmasked, after checking the mask bit is set.
private func clientPayload(_ frame: Data) throws -> (opcode: UInt8, payload: Data) {
    let bytes = [UInt8](frame)
    #expect(bytes[1] & 0x80 != 0, "a client frame is masked")
    var length = Int(bytes[1] & 0x7F)
    var offset = 2
    if length == 126 {
        length = Int(bytes[2]) << 8 | Int(bytes[3])
        offset = 4
    } else if length == 127 {
        length = (0..<8).reduce(0) { $0 << 8 | Int(bytes[2 + $1]) }
        offset = 10
    }
    let mask = Array(bytes[offset..<(offset + 4)])
    let body = bytes[(offset + 4)...]
    #expect(body.count == length)
    return (bytes[0] & 0x0F, Data(body.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
}

private func upgradeAnswer(key: String, subprotocol: String) -> Data {
    Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-Websocket-Accept: \(RexWebSocketCodec.accept(for: key))\r\nSec-Websocket-Protocol: \(subprotocol)\r\nUpgrade: websocket\r\n\r\n".utf8)
}

/// A Ghostty snapshot of a `columns` by `rows` terminal that was written `text`.
private func ghosttySnapshot(of text: String, columns: UInt16 = 80, rows: UInt16 = 24) throws -> Data {
    var terminal: GhosttyTerminal?
    try #require(ghostty_terminal_new(nil, &terminal, columns, rows) == GHOSTTY_SUCCESS)
    defer { ghostty_terminal_free(terminal) }
    // A new terminal keeps about a thousand rows; keep all of them, as Rex does.
    var history = 64 * 1024 * 1024
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &history)
    let bytes = Data(text.utf8)
    bytes.withUnsafeBytes { ghostty_terminal_vt_write(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    var pointer: UnsafeMutablePointer<UInt8>?
    var length = 0
    try #require(ghostty_snapshot_encode_alloc(terminal, nil, &pointer, &length) == GHOSTTY_SUCCESS)
    defer { ghostty_free(nil, pointer, length) }
    return Data(bytes: try #require(pointer), count: length)
}

/// `count` numbered lines (`<name> line 0`, ...), enough to fill several history pages.
private func numberedLines(_ count: Int, name: String = "") -> String {
    (0..<count).map { "\(name) line \($0)" }.joined(separator: "\r\n") + "\r\n$ "
}

/// A snapshot cut where Rex's stream cuts it: the screen (every record
/// through READY) and each whole record after it.
private func snapshotParts(_ snapshot: Data) throws -> (screen: Data, records: [Data]) {
    var stream = RexTerminalStream(nonce: 1)
    var screen: Data?
    var records: [Data] = []
    // One byte at a time, so each record after READY comes out on its own.
    for index in snapshot.indices {
        for piece in try stream.receive(snapshot[index...index]) {
            switch piece {
            case .snapshot(let bytes): screen = bytes
            case .snapshotRecords(let bytes): records.append(bytes)
            case .output, .message: Issue.record("a snapshot alone has no output")
            }
        }
    }
    return (try #require(screen), records)
}

/// Hands `bytes` to `queue` the way a Rex pane's data connection does: cut by
/// `RexTerminalStream`, `chunk` bytes at a time, with Rex's messages left out.
private func pushRexStream(_ bytes: Data, to queue: SSHTerminalEventQueue, block: String? = nil, chunk: Int = 4096) throws {
    var stream = RexTerminalStream(nonce: 1)
    var index = bytes.startIndex
    while index < bytes.endIndex {
        let end = min(index + chunk, bytes.endIndex)
        for piece in try stream.receive(bytes[index..<end]) {
            switch piece {
            case .snapshot(let screen): queue.pushSnapshot(screen, block: block)
            case .snapshotRecords(let records): queue.pushSnapshotRecords(records, block: block)
            case .output(let output): queue.push(.data(output))
            case .message: break
            }
        }
        index = end
    }
}

@Suite("Rex client protocol")
struct RexClientProtocolTests {
    /// RFC 6455's own example: a server's answer is checked against the key
    /// this client sent, so an answer meant for another connection is refused.
    @Test func theUpgradeAnswerMustMatchThisConnectionsKeyAndSubprotocol() throws {
        #expect(RexWebSocketCodec.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

        var codec = RexWebSocketCodec(subprotocol: "rex.control.v1", key: "dGhlIHNhbXBsZSBub25jZQ==")
        let request = String(decoding: codec.upgradeRequest(path: "/api/control"), as: UTF8.self)
        #expect(request.hasPrefix("GET /api/control HTTP/1.1\r\n"))
        #expect(request.contains("Sec-WebSocket-Protocol: rex.control.v1\r\n") && request.hasSuffix("\r\n\r\n"))
        // Headers split across reads still upgrade once complete.
        let answer = upgradeAnswer(key: codec.key, subprotocol: "rex.control.v1")
        #expect(try codec.receive(answer.prefix(30)).messages.isEmpty)
        #expect(!codec.upgraded)
        _ = try codec.receive(answer.dropFirst(30))
        #expect(codec.upgraded)

        var stranger = RexWebSocketCodec(subprotocol: "rex.control.v1", key: "AAAAAAAAAAAAAAAAAAAAAA==")
        #expect(throws: RexWebSocketCodec.Failure.self) { try stranger.receive(answer) }
        var wrongProtocol = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1", key: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(throws: RexWebSocketCodec.Failure.self) { try wrongProtocol.receive(answer) }

        // Rex answers a caller it does not let in with 403 and a JSON reason.
        var refused = RexWebSocketCodec(subprotocol: "rex.control.v1")
        #expect(throws: RexWebSocketCodec.Failure.upgradeRefused(#"HTTP/1.1 403 Forbidden {"error":"not allowed"}"#)) {
            try refused.receive(Data("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{\"error\":\"not allowed\"}\n".utf8))
        }
    }

    /// Every length form, frames split anywhere across reads, a fragmented
    /// message, a ping answered with a masked pong of the same payload, and the
    /// server's close code. A masked server frame breaks the protocol.
    @Test func framesOfEveryLengthAndShapeComeOutWhole() throws {
        var codec = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1")
        _ = try codec.receive(upgradeAnswer(key: codec.key, subprotocol: "rex.data.terminal.v1"))
        let small = Data("hi".utf8), medium = Data(repeating: 0x41, count: 300), large = Data((0..<70_000).map { UInt8($0 % 251) })
        let stream = serverFrame(.binary, small) + serverFrame(.binary, medium) + serverFrame(.binary, large)
            + serverFrame(.text, Data("hel".utf8), fin: false) + serverFrame(.ping, Data("p1".utf8))
            + serverFrame(.continuation, Data("lo".utf8)) + serverFrame(.close, Data([0x0F, 0xA0]) + Data("block closed".utf8))
        var messages: [RexWebSocketCodec.Message] = []
        var replies: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = min(index + 7, stream.endIndex)
            let read = try codec.receive(stream[index..<end])
            messages += read.messages
            replies += read.replies
            index = end
        }
        #expect(messages == [.binary(small), .binary(medium), .binary(large), .text("hello"), .close(code: 4000, reason: "block closed")])
        #expect(replies.count == 1)
        let pong = try clientPayload(try #require(replies.first))
        #expect(pong.opcode == RexWebSocketCodec.Opcode.pong.rawValue && pong.payload == Data("p1".utf8))

        // A client frame round-trips through the mask at each length form.
        for payload in [small, medium, large] {
            #expect(try clientPayload(RexWebSocketCodec.frame(.binary, payload: payload)).payload == payload)
        }

        var strict = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1")
        _ = try strict.receive(upgradeAnswer(key: strict.key, subprotocol: "rex.data.terminal.v1"))
        #expect(throws: RexWebSocketCodec.Failure.self) { try strict.receive(RexWebSocketCodec.frame(.text, payload: small)) }
    }

    @Test func theDataHandshakeReadsWelcomeAndReject() throws {
        #expect(RexDataHandshake.hello(ticket: Data(repeating: 7, count: 16)) == Data([0x01]) + Data(repeating: 7, count: 16))
        var welcome = Data([0x81]) + Data(repeating: 0xAB, count: 16) + Data([0, 0, 0])
        welcome += Data([0x60, 0xEA, 0x00, 0x00]) // 60000, little-endian
        welcome += Data([0x6E, 0xEC, 0x22, 0x5D, 0xC8, 0x3C, 0x43, 0x4B]) // 5423245207537904750
        #expect(try RexDataHandshake.answer(welcome) == .welcome(.init(
            reconnectToken: Data(repeating: 0xAB, count: 16), keepMilliseconds: 60_000, nonce: 5_423_245_207_537_904_750
        )))
        #expect(try RexDataHandshake.answer(Data([0x82, 0x01])) == .reject(0x01))
        #expect(throws: RexDataHandshake.Failure.malformed) { try RexDataHandshake.answer(Data([0x81, 0x00])) }
        #expect(RexSessionConnection.base64URL("AQID_-8") == Data([1, 2, 3, 255, 239]))
    }

    /// The snapshot is cut into whole records: the screen once READY is in,
    /// then the records after it as they complete, through FINISH. Output
    /// starts right after FINISH. Rex's messages leave the output, even split
    /// across reads; a look-alike with another nonce, which a program printed,
    /// stays output.
    @Test func theTerminalStreamSplitsSnapshotRecordsOutputAndRexMessages() throws {
        var stream = RexTerminalStream(nonce: 42)
        let snapshot = try ghosttySnapshot(of: numberedLines(3000))
        let resize = Data("\u{1B}_rex1;42;{\"type\":\"resize\",\"cols\":60,\"rows\":20}\u{1B}\\".utf8)
        let forged = Data("\u{1B}_rex1;7;{\"type\":\"child_exited\",\"exit_code\":9}\u{1B}\\".utf8)
        let exited = Data("\u{1B}_rex1;42;{\"type\":\"child_exited\",\"exit_code\":3}\u{1B}\\".utf8)
        let all = snapshot + resize + Data("$ ls\r\n".utf8) + forged + exited + Data("tail".utf8)
        var pieces: [RexTerminalStream.Piece] = []
        var index = all.startIndex
        while index < all.endIndex {
            let end = min(index + 997, all.endIndex)
            pieces += try stream.receive(all[index..<end])
            index = end
        }
        let output = pieces.reduce(into: Data()) { joined, piece in
            if case .output(let bytes) = piece { joined += bytes }
        }
        let records = pieces.compactMap { piece -> Data? in
            if case .snapshotRecords(let bytes) = piece { bytes } else { nil }
        }
        guard case .snapshot(let screen)? = pieces.first else {
            Issue.record("the screen comes first, got \(String(describing: pieces.first))")
            return
        }
        #expect(screen.count < snapshot.count / 2, "the screen is a small part of a snapshot with history")
        #expect(SSHTerminalSnapshotFormat.record(in: screen, at: screen.count - 10)?.tag == SSHTerminalSnapshotFormat.Tag.ready.rawValue)
        #expect(records.count > 1, "the history arrives as it completes, not all at once")
        #expect(screen + records.reduce(Data(), +) == snapshot, "every snapshot byte, in order, and nothing else")
        #expect(pieces.contains(.message(.resize(columns: 60, rows: 20))))
        #expect(pieces.contains(.message(.childExited(code: 3))))
        #expect(output == Data("$ ls\r\n".utf8) + forged + Data("tail".utf8))
    }

    /// A stream that does not start like a snapshot ends at once, and so does
    /// one whose record would take it past the most a phone holds, before
    /// that record's bytes are waited for.
    @Test func aStreamThatIsNotASnapshotOrTooLargeEnds() throws {
        var stranger = RexTerminalStream(nonce: 1)
        #expect(throws: RexTerminalStream.Failure.notASnapshot) { try stranger.receive(Data("GHOSTS".utf8) + Data("X".utf8)) }
        var newer = RexTerminalStream(nonce: 1)
        #expect(throws: RexTerminalStream.Failure.notASnapshot) { try newer.receive(Data("GHOSTSNP".utf8) + Data([2, 0])) }
        var huge = RexTerminalStream(nonce: 1)
        let page = Data([3, 0]) + Data([0, 0, 0, 0x7F]) + Data(repeating: 0, count: 4)
        #expect(throws: RexTerminalStream.Failure.snapshotTooLarge) {
            try huge.receive(Data("GHOSTSNP".utf8) + Data([1, 0]) + page)
        }
    }
}

/// What a real Rex sent on a data connection that negotiated compression,
/// captured from a throwaway session started with no login shell
/// (`rex new --shell none -- sh -c 'clear; printf "\e[1mrex compressed
/// fixture\e[0m\n"; seq 1 40; exec sleep 600'`), so its screen holds only that
/// text: no login banner, folder, or title. Its upgrade answer (to key
/// `dGhlIHNhbXBsZSBub25jZQ==`), then the raw frames after it: WELCOME (too
/// small to compress), and one compressed binary message holding the snapshot
/// and Rex's `resize` message, whose `owner` is that throwaway session's
/// creating client.
private let compressedRexUpgrade = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-Websocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-Websocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\nSec-Websocket-Protocol: rex.data.terminal.v1\r\nUpgrade: websocket\r\nDate: Sat, 31 Oct 2026 04:23:36 GMT\r\n\r\n"
private let compressedRexFrames = Data(base64Encoded: [
    "giCBw97L232PR69/SVNt+1weDAAAAGDqAAB+DALyMEiHUMJ+A7V8k89r3eUSh5/37bn3hru4cLOwQiu230UFSeD745yTc06hq0LF",
    "RVqIiy6kQ5OemMChDWloa0WIq4HgQiGgbgqKSHeDQRE1lqI0FOkigjKSlYuAUKH6H4wQ09YidJ7FvMPnmc0Lc+ql0zOvzEyfSSQ+",
    "OADvzlbjZ3iWx3UQOA2QKIGUUgIYo1VwAfhHfwotgNgvUtrnueeP3puf//ybhT+2Vt766NbG+tdrt764c3drfn7+p+mZL79/+dc7",
    "p65/svPdez8v3f70/v37AAgoGDgEAiKIIoY4EiiooIoa6mhgYIIpZphjgYMLrrjhjgcBIYQSRjgRAoIIKpjgQoggIiIqYiIuEqKI",
    "iqiKmqiLhhhiIqZiJuZiIY64iKu4ibt4SCAhEiphEi4RCoooqpjiSqigIiqqYiquEqqoiqqqmqqrhhpqoqZqpuZqoY66qKu6qbt6",
    "aKAhGqphGq4RBoYYapjhRphgIiZqYiZuEqaYiqmamqmbhhlmYqZmZuZmYY65mKu5mbt5WGAhFmphFm4RDo446pjjTrjgIi7qYi7u",
    "Eq64iqu6mqu7hhtu4qZu5uZu4Y67uKu7ubt7eOAhHuphHu4RAYEEGljgQYQQIiEaYiEeEqGESqiGWqiHRhhhEqZhFuZhEU64hGu4",
    "hXt4RBAhERphER4RY2Nj4+Pjhw8fPnbsWFmWg8Hg5MmT09PTZ8+enZ2dHY1GV65cWV1dXVtbW19fv3Hjxs2bNzc2NjY3N7e2tra3",
    "t3d2dnZ3dx88ePD0o3lMpgs03946B4nxR8FB0sPnk4w9OR7gVIKv/pePnuHFvZ1VbsORv8y9s35EAo48w91Eaz3R+iXRWoXW24nW",
    "ZqL1WaJ1O9F6mN9LtO7tu+/su+8nWh/v724nWj/+zSdRkahJNCTaJDokuiSmSPRI9MlUJZmqIlPVZKqGTNUmU3XIVF0y1RSZqkem",
    "6pOpSzJ1RaauydQNmbpNpu6Qqbtk6ikydY9M3SfTlGSaikxTk2kaMk2bTNMh03TJNFNkmh6Zpk+mXe5/03/22gurcz/8C4DdI7//",
    "t8W/gQ//v3ZuL9yb4MRvMycOyfLwWnW80yvrbq9bVv1+u1vW7bJbH3+jWHl9aVgMiuXh5cXrw2KimLs0ulwMeuVEsXzp6uViULcn",
    "irnhaCRXFy+sLMjStWLQmyjmhqORLAwXX1tYkaVrxaDqThSXrl4cLheDYm60OLy4Miir81W/bOrJpn2+mpzq1fXk+U6/nKw6852m",
    "KeeaqlcWbx569U8A",
].joined())!

@Suite("Rex WebSocket compression")
struct RexWebSocketCompressionTests {
    /// The client offers compression with no context between messages, Rex
    /// accepts it, and a message it compressed inflates to the pane's
    /// snapshot: the screen restores, and Rex's `resize` message leaves it.
    @Test @MainActor func aRealCompressedRexStreamInflatesToThePanesScreen() throws {
        var codec = RexWebSocketCodec(subprotocol: RexEndpoint.data.subprotocol, key: "dGhlIHNhbXBsZSBub25jZQ==")
        let request = String(decoding: codec.upgradeRequest(path: RexEndpoint.data.path), as: UTF8.self)
        #expect(request.contains("Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\n"))

        #expect(try codec.receive(Data(compressedRexUpgrade.utf8)).messages.isEmpty)
        #expect(codec.upgraded)
        var stream = RexDataStream()
        var outputs: [RexDataStream.Output] = []
        // A few bytes at a time, as an SSH channel may deliver them.
        var index = compressedRexFrames.startIndex
        while index < compressedRexFrames.endIndex {
            let end = min(index + 100, compressedRexFrames.endIndex)
            for message in try codec.receive(compressedRexFrames[index..<end]).messages {
                outputs += stream.receive(message)
            }
            index = end
        }
        guard case .snapshot(let screen)? = outputs.first, outputs.count == 2, case .snapshotRecords(let records) = outputs[1] else {
            Issue.record("expected the screen and its records, got \(outputs)")
            return
        }
        let engine = try SSHTerminalEngine(geometry: .init(columns: 80, rows: 24)) { _ in }
        try engine.beginRestore(screen)
        #expect(try engine.continueRestore(records))
        let text = { engine.frame().rows.map { $0.map(\.text).joined() } }
        #expect(text().contains { $0.hasPrefix("40") }, "the screen: the last number printed")
        engine.scrollToRow(0)
        #expect(text().contains { $0.contains("rex compressed fixture") }, "the history: the line printed first")
    }

    /// A compressed message may span frames: only its first frame says so,
    /// and it inflates once whole.
    @Test func aCompressedMessageMaySpanFrames() throws {
        let compressed = try Self.compressedPayload()
        let whole = try RexWebSocketCodec.inflate(compressed)
        var codec = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1", key: "dGhlIHNhbXBsZSBub25jZQ==")
        _ = try codec.receive(Data(compressedRexUpgrade.utf8))
        #expect(codec.compressed)
        let third = compressed.count / 3
        let frames = Self.frame(0x40 | 0x02, compressed.prefix(third), fin: false)
            + Self.frame(0x00, compressed.dropFirst(third).prefix(third), fin: false)
            + Self.frame(0x00, compressed.dropFirst(2 * third), fin: true)
        #expect(try codec.receive(frames).messages == [.binary(whole)])
    }

    /// Compression is only what was agreed: a compressed frame on a
    /// connection that did not negotiate it, on a continuation, or on a control
    /// frame breaks the protocol, and so does an answer that keeps context
    /// between messages or names a parameter this client does not know. A
    /// message that inflates past the cap is refused.
    @Test func compressionIsOnlyWhatWasNegotiated() throws {
        let compressed = try Self.compressedPayload()
        var plain = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1")
        _ = try plain.receive(upgradeAnswer(key: plain.key, subprotocol: "rex.data.terminal.v1"))
        #expect(!plain.compressed)
        #expect(throws: RexWebSocketCodec.Failure.self) { try plain.receive(Self.frame(0x40 | 0x02, compressed, fin: true)) }

        for bad in [Self.frame(0x02, compressed.prefix(4), fin: false) + Self.frame(0x40, compressed.dropFirst(4), fin: true),
                    Self.frame(0x40 | 0x09, Data(), fin: true)] {
            var codec = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1", key: "dGhlIHNhbXBsZSBub25jZQ==")
            _ = try codec.receive(Data(compressedRexUpgrade.utf8))
            #expect(throws: RexWebSocketCodec.Failure.self) { try codec.receive(bad) }
        }

        for answer in ["permessage-deflate", "permessage-deflate; server_no_context_takeover; future_thing", "x-webkit-deflate-frame"] {
            var codec = RexWebSocketCodec(subprotocol: "rex.data.terminal.v1", key: "dGhlIHNhbXBsZSBub25jZQ==")
            let head = compressedRexUpgrade.replacingOccurrences(
                of: "permessage-deflate; client_no_context_takeover; server_no_context_takeover", with: answer
            )
            #expect(throws: RexWebSocketCodec.Failure.self, "\(answer)") { try codec.receive(Data(head.utf8)) }
        }

        let bomb = try #require((Data(count: RexWebSocketCodec.maximumMessageBytes + 1) as NSData).compressed(using: .zlib) as Data?)
        #expect(throws: RexWebSocketCodec.Failure.self) { try RexWebSocketCodec.inflate(bomb) }
    }

    /// The compressed message in the captured frames: the second frame's payload.
    private static func compressedPayload() throws -> Data {
        let bytes = [UInt8](compressedRexFrames)
        let welcome = 2 + Int(bytes[1] & 0x7F)
        try #require(bytes[welcome] == 0xC2 && bytes[welcome + 1] == 126, "a final, compressed binary frame")
        let length = Int(bytes[welcome + 2]) << 8 | Int(bytes[welcome + 3])
        return Data(bytes[(welcome + 4)..<(welcome + 4 + length)])
    }

    /// An unmasked server frame with `first`'s opcode and reserved bits.
    private static func frame(_ first: UInt8, _ payload: Data, fin: Bool) -> Data {
        var frame = Data([(fin ? 0x80 : 0) | first])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        }
        return frame + payload
    }
}

/// A message-level Rex socket that records what its owner sends: what a
/// WebSocket that frames for itself (the direct route) hands `RexControl`.
private final class RecordingSocket: RexSocket {
    private let sent = Mutex<[RexSocketMessage]>([])
    private let closed = Mutex(false)

    var all: [RexSocketMessage] { sent.withLock { $0 } }
    var isClosed: Bool { closed.withLock { $0 } }

    func send(_ message: RexSocketMessage) async throws { sent.withLock { $0.append(message) } }
    func close() { closed.withLock { $0 = true } }

    func json(_ index: Int) throws -> [String: Any] {
        guard case .text(let text) = all[index] else { throw CancellationError() }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

/// A byte pipe that records what the bridge's client side writes.
private final class WrittenFrames: Sendable {
    let frames = Mutex<[Data]>([])
    func append(_ frame: Data) { frames.withLock { $0.append(frame) } }
    var all: [Data] { frames.withLock { $0 } }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}

@Suite("Rex control connection")
struct RexControlTests {
    /// Hello, then requests matched to their answers by id, an error answer
    /// as Rex's reason, events in order, and the socket's end failing a call
    /// still waiting and every call after it, with the socket's own reason.
    /// The socket frames for itself: the control connection sends and reads
    /// whole messages.
    @Test func helloRequestsEventsAndTheSocketEndingAreRead() async throws {
        let socket = RecordingSocket()
        let control = RexControl()
        control.attach(socket)
        let events = Mutex<[String]>([])
        control.onEvent { event in
            let inner = event["payload"] as? [String: Any]
            events.withLock { $0.append(inner?["type"] as? String ?? "?") }
        }

        let opening = Task { try await control.open() }
        try await waitUntil { socket.all.count == 1 }
        let hello = try socket.json(0)
        #expect(hello["type"] as? String == "hello" && hello["api_revision"] as? Int == RexControl.apiRevision)
        control.receive(.message(.text(#"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576}}"#)))
        try await opening.value

        let first = Task { try await control.call("server.version", [:]) }
        let second = Task { try await control.call("session.attach", ["session_id": "session:x"]) }
        try await waitUntil { socket.all.count == 3 }
        var ids: [String: String] = [:]
        for index in 1...2 {
            let object = try socket.json(index)
            ids[object["method"] as? String ?? ""] = object["id"] as? String
        }
        let attachID = try #require(ids["session.attach"]), versionID = try #require(ids["server.version"])
        // Answers in the other order still reach their callers.
        control.receive(.message(.text(#"{"type":"response","id":"\#(attachID)","seq":0,"error":{"code":"session_not_found","message":"no session","status":404}}"#)))
        control.receive(.message(.text(#"{"type":"event","seq":1,"payload":{"type":"session_created"}}"#)))
        control.receive(.writable(false))
        control.receive(.message(.text(#"{"type":"response","id":"\#(versionID)","seq":1,"payload":{"rex_version":"0.1.0"}}"#)))
        let version = try JSONSerialization.jsonObject(with: try await first.value) as? [String: Any]
        #expect(version?["rex_version"] as? String == "0.1.0")
        #expect(events.withLock { $0 } == ["session_created"], "events reach the handler, whole, in order")
        await #expect(throws: RexClientError.refused(code: "session_not_found", message: "no session")) { try await second.value }

        let waiting = Task { try await control.call("server.status", [:]) }
        try await waitUntil { socket.all.count == 4 }
        control.receive(.ended(RexClientError.notRunning))
        await #expect(throws: RexClientError.notRunning) { try await waiting.value }
        await #expect(throws: RexClientError.notRunning) { try await control.call("server.version", [:]) }
        control.close()
        #expect(socket.isClosed)
    }

    /// A request Rex never answers fails in time instead of holding typing
    /// forever; its answer arriving later is dropped, and the next request
    /// still gets its own answer.
    @Test func anUnansweredRequestTimesOut() async throws {
        let socket = RecordingSocket()
        // Long enough that the test's own answer to the second request, on a
        // busy machine, still lands inside it.
        let control = RexControl(requestTimeout: .seconds(1))
        control.attach(socket)
        let opening = Task { try await control.open() }
        try await waitUntil { socket.all.count == 1 }
        control.receive(.message(.text(#"{"type":"welcome","protocol":"rex.control.v1"}"#)))
        try await opening.value

        await #expect(throws: RexClientError.timedOut) { try await control.call("server.version", [:]) }
        let late = try #require(socket.json(1)["id"] as? String)
        control.receive(.message(.text(#"{"type":"response","id":"\#(late)","seq":0,"payload":{"late":true}}"#)))

        let next = Task { try await control.call("server.status", [:]) }
        try await waitUntil { socket.all.count == 3 }
        let id = try #require(socket.json(2)["id"] as? String)
        control.receive(.message(.text(#"{"type":"response","id":"\#(id)","seq":0,"payload":{"sessions":1}}"#)))
        let answer = try JSONSerialization.jsonObject(with: try await next.value) as? [String: Any]
        #expect(answer?["sessions"] as? Int == 1)
    }
}

@Suite("Rex bridge socket")
struct RexPipeSocketTests {
    /// Over the SSH bridge this side does the WebSocket: it upgrades to the
    /// endpoint's path and subprotocol, hands over whole messages (one that
    /// came in the upgrade's read too), answers a ping with a masked pong, and
    /// frames what it sends. The bridge's exit status says why it ended, as
    /// the SSH channel reports it: EOF, then the status, then closed.
    @Test func theBridgeUpgradesAnswersPingsAndEndsWithTheBridgesReason() async throws {
        let written = WrittenFrames()
        let sink = Mutex<SSHPTYByteSink?>(nil)
        let events = Mutex<[String]>([])
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let opening = Task {
            try await RexPipeSocket.open(.control, key: key, openStream: { delivered in
                sink.withLock { $0 = delivered }
                return SSHExecStream(send: { written.append($0) }, close: {})
            }, onEvent: { event in
                let text: String
                switch event {
                case .message(.text(let body)): text = "text \(body)"
                case .message(let other): text = "\(other)"
                case .writable(let writable): text = "writable \(writable)"
                case .ended(let error): text = "ended \(error)"
                }
                events.withLock { $0.append(text) }
            })
        }
        try await waitUntil { written.all.count == 1 }
        let request = String(decoding: written.all[0], as: UTF8.self)
        #expect(request.hasPrefix("GET /api/control HTTP/1.1\r\n") && request.contains("Sec-WebSocket-Protocol: rex.control.v1\r\n"))
        let deliver = try #require(sink.withLock { $0 })
        deliver(.writabilityChanged(true))
        deliver(.data(upgradeAnswer(key: key, subprotocol: "rex.control.v1") + serverFrame(.ping, Data("p1".utf8)) + serverFrame(.text, Data("hi".utf8))))
        let socket = try await opening.value
        try await waitUntil { written.all.count == 2 }
        let pong = try clientPayload(written.all[1])
        #expect(pong.opcode == RexWebSocketCodec.Opcode.pong.rawValue && pong.payload == Data("p1".utf8))

        try await socket.send(.text("hello"))
        let sent = try clientPayload(written.all[2])
        #expect(sent.opcode == RexWebSocketCodec.Opcode.text.rawValue && sent.payload == Data("hello".utf8))

        deliver(.eof)
        deliver(.exitStatus(4))
        deliver(.closed)
        #expect(events.withLock { $0 } == ["writable true", "text hi", "ended \(RexClientError.notRunning)"])
        await #expect(throws: RexClientError.connectionClosed) { try await socket.send(.text("late")) }

        // A bridge that exits before Rex answers (no `nc` that speaks Unix
        // sockets, 126) fails the open with its reason, not a timeout.
        let early = Mutex<SSHPTYByteSink?>(nil)
        let refused = Task {
            try await RexPipeSocket.open(.data, openStream: { delivered in
                early.withLock { $0 = delivered }
                return SSHExecStream(send: { _ in }, close: {})
            }, onEvent: { _ in })
        }
        try await waitUntil { early.withLock { $0 } != nil }
        let end = try #require(early.withLock { $0 })
        end(.exitStatus(126))
        end(.closed)
        await #expect(throws: RexClientError.bridgeMissing) { try await refused.value }
    }
}

@Suite("Rex events")
struct RexEventTests {
    private func parse(_ frame: String) throws -> RexEvent? {
        RexEvent(frame: try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]))
    }

    private static let session = "session:01a18bbf-6d93-7d00-9dc8-e80056462af2"
    private static let block = "block:01a18bbf-6d94-7130-8ea8-ea4b83e3799a"

    /// Frames a Rex server sent to a client that called `session.attach_all`
    /// with `event_scope: all`, captured from one (`rex server run`) and cut
    /// only for length. The events the overview follows parse into the
    /// session and block they name; the rest of what Rex sends (clients,
    /// owners, processes) is not parsed.
    @Test func theEventsTheOverviewFollowsParseAndTheRestDoNot() throws {
        let session = Self.session, block = Self.block
        let nested = { (inner: String) in
            #"{"type":"event","seq":9,"payload":{"type":"session_event","payload":{"session_id":"\#(session)","event":\#(inner)}}}"#
        }
        let terminal = { (name: String, payload: String) in
            nested(#"{"type":"block_event","payload":{"block_id":"\#(block)","creator_name":"com.superlogical.terminal","name":"\#(name)","payload":\#(payload)}}"#)
        }
        #expect(try parse(#"{"type":"event","seq":2,"payload":{"type":"session_created","payload":{"session":{"session_id":"\#(session)","label":"probe"}}}}"#) == .sessionCreated(session: session))
        #expect(try parse(#"{"type":"event","seq":30,"payload":{"type":"session_destroyed","payload":{"session_id":"\#(session)"}}}"#) == .sessionDestroyed(session: session))
        #expect(try parse(nested(#"{"type":"session_view_changed","payload":{"revision":4}}"#)) == .viewChanged(session: session, revision: 4))
        #expect(try parse(nested(#"{"type":"block_created","payload":{"block_id":"\#(block)"}}"#)) == .blockCreated(session: session, block: block))
        #expect(try parse(nested(#"{"type":"block_closed","payload":{"block_id":"\#(block)"}}"#)) == .blockClosed(session: session, block: block))
        #expect(try parse(terminal("title_changed", #"{"title":"mytitle","owner":{"pid":35837,"name":"bash"}}"#)) == .title(session: session, block: block, "mytitle"))
        #expect(try parse(terminal("pwd_changed", #"{"pwd":"file://h/tmp","owner":{"pid":35837,"name":"bash"}}"#)) == .pwd(session: session, block: block, "file://h/tmp"))
        #expect(try parse(terminal("child_exited", #"{"exit_code":3,"error":"exit status 3"}"#)) == .childExited(session: session, block: block))
        #expect(try parse(terminal("program_status_removed", #"{"ids":["","bash"],"reason":"child_exited"}"#)) == .statusRemoved(session: session, block: block, ids: ["", "bash"]))

        // The root record has no id of its own; a child's id is its record's.
        let root = #"{"id":"","record":{"state":"blocked","kind":"permission","app":"pi","effective_app":"pi","updated_at":"2026-10-30T00:59:16.372948-07:00","owner":{"pid":86966,"name":"bash"}},"reason":"report"}"#
        #expect(try parse(terminal("program_status_changed", root)) == .status(
            session: session, block: block, .init(id: "", state: .blocked, kind: .permission, message: nil, app: "pi")
        ))
        let child = #"{"id":"bash","record":{"id":"bash","state":"working","app":"pi","effective_app":"pi"},"reason":"report"}"#
        #expect(try parse(terminal("program_status_changed", child)) == .status(
            session: session, block: block, .init(id: "bash", state: .working, kind: nil, message: nil, app: "pi")
        ))

        #expect(try parse(terminal("process_changed", #"{"generation":2,"foreground":null}"#)) == nil)
        #expect(try parse(nested(#"{"type":"block_owner_changed","payload":{"block_id":"\#(block)","reason":"create"}}"#)) == nil)
        #expect(try parse(#"{"type":"event","seq":1,"payload":{"type":"client_joined","payload":{"client":{"client_id":"client:1"}}}}"#) == nil)
        // A block that is not a terminal reports nothing the overview reads.
        #expect(try parse(nested(#"{"type":"block_event","payload":{"block_id":"\#(block)","creator_name":"com.superlogical.onboarding","name":"title_changed","payload":{"title":"x"}}}"#)) == nil)
    }
}

@Suite("Rex pane data connection")
struct RexDataStreamTests {
    /// The whole data handshake and stream, as whole messages from the socket:
    /// HELLO with the ticket, WELCOME's nonce, then the snapshot, output with
    /// Rex's messages removed, the program's exit, and close 4000 as the pane
    /// closing. Nothing comes out after the end.
    @Test func helloWelcomeSnapshotOutputExitAndClose() throws {
        let ticket = Data((1...16).map { UInt8($0) })
        var stream = RexDataStream()
        #expect(RexDataStream.hello(ticket: ticket) == .binary(Data([0x01]) + ticket))

        var welcome = Data([0x81]) + Data(repeating: 0, count: 19) + Data([0x60, 0xEA, 0, 0])
        welcome += Data([42, 0, 0, 0, 0, 0, 0, 0])
        #expect(stream.receive(.binary(welcome)).isEmpty)

        let snapshot = try ghosttySnapshot(of: "first line\r\n$ ")
        let (screen, records) = try snapshotParts(snapshot)
        let message = { (json: String) in Data("\u{1B}_rex1;42;\(json)\u{1B}\\".utf8) }
        let body = snapshot + message(#"{"type":"resize","cols":80,"rows":24}"#) + Data("$ ls\r\n".utf8)
            + message(#"{"type":"child_exited","exit_code":2}"#)
        #expect(stream.receive(.binary(body)) == [
            .snapshot(screen), .snapshotRecords(records.reduce(Data(), +)), .output(Data("$ ls\r\n".utf8)), .exited(code: 2),
        ])
        #expect(stream.receive(.close(code: 4000, reason: "block closed")) == [.paneClosed])
        #expect(stream.receive(.binary(Data("late".utf8))).isEmpty)

        var refused = RexDataStream()
        #expect(refused.receive(.binary(Data([0x82, 0x01]))) == [
            .ended(RexDataHandshake.Failure.rejected(0x01).localizedDescription),
        ])
    }
}

@Suite("Rex pane in the terminal engine")
@MainActor
struct RexPaneEngineTests {
    /// A Ghostty snapshot of a terminal with history becomes the grid: the
    /// screen it showed, at this screen's size, and output after it lands on
    /// top. Rex's terminal answered the program's queries, so this one does not.
    @Test func aSnapshotStartsTheGridAndLiveOutputContinuesIt() async throws {
        let snapshot = try ghosttySnapshot(of: "first line\r\n\u{1B}[31mred\u{1B}[0m second\r\n$ ")
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        let fixture = RecordingConnection()
        channel.opened(fixture)
        defer { channel.close(reason: "done") }
        channel.resize(.init(columns: 40, rows: 10))
        // The resize is debounced; wait for it, however busy the machine is.
        for _ in 0..<200 where channel.engine.geometry.rows != 10 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(channel.engine.geometry.rows == 10)

        let queue = SSHTerminalEventQueue()
        // Output glued to the snapshot's end is still output.
        try pushRexStream(snapshot + Data("l".utf8), to: queue)
        // A device-attributes query the program printed, then output.
        queue.push(.data(Data("\u{1B}[cs\r\n".utf8)))
        queue.end("done")
        await channel.consume(queue)

        let rows = channel.engine.frame().rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        #expect(rows.prefix(3) == ["first line", "red second", "$ ls"])
        #expect(rows.count == 10, "the restored terminal takes this screen's size")
        #expect(await fixture.sent.isEmpty, "Rex's terminal answered the query; a second answer would be typed input")
        #expect(!channel.connected)
    }

    /// Something that is not a snapshot ends the terminal with a reason
    /// instead of drawing garbage.
    @Test func anUnreadableSnapshotEndsTheTerminal() async throws {
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        channel.opened(RecordingConnection())
        let queue = SSHTerminalEventQueue()
        queue.pushSnapshot(Data("GHOSTSNP\u{9}\u{9}not a snapshot".utf8))
        queue.end("never reached")
        await channel.consume(queue)
        #expect(!channel.connected)
        #expect(channel.reason.contains("could not be read"))
    }

    /// A pane that showed an image, as Rex itself encodes it: Rex 1642 writes
    /// Kitty graphics records (storage, pixels) into the snapshot. Captured
    /// from a Rex session whose program printed a line, a 1x1 red image with
    /// id 7, and another line. The pane opens with its text and its image.
    @Test func aRexSnapshotWithAnImageRestoresTheGridAndTheImage() async throws {
        let snapshot = try Data(contentsOf: TestFixtures.url("rex-kitty-image-snapshot.bin"))
        let (channel, rows) = try await Self.restore(snapshot)
        #expect(channel.reason == "stream over", "the snapshot restored; it did not end the terminal: \(channel.reason)")
        #expect(rows.contains("rex kitty fixture") && rows.contains("after image"))
        let frame = channel.engine.frame()
        let kitty = try #require(frame.kitty, "the image came with the snapshot")
        #expect(kitty.placements.map(\.imageID) == [7])
        // The pixels came too, not only a placement that would draw blank:
        // one red pixel, stored as sent (`f=24`, RGB).
        let image = try #require(kitty.imagesByID[7])
        let graphics = try #require(frame.kittyGraphics)
        let pixels = try #require(image.resolvePixels(graphics))
        #expect(Array(UnsafeBufferPointer(start: pixels.pointer, count: pixels.byteCount)) == [0xFF, 0x00, 0x00])
    }

    /// A newer Rex may add kinds of snapshot records this Oppi does not know.
    /// They are skipped, wherever they appear (before READY, between history
    /// pages), and the pane still opens with all its history.
    @Test func aSnapshotRecordOfAnUnknownKindIsSkipped() async throws {
        let screen = try Self.withUnknownRecord(try ghosttySnapshot(of: "first line\r\n$ "), before: SSHTerminalSnapshotFormat.Tag.ready)
        let (channel, rows) = try await Self.restore(screen)
        #expect(channel.reason == "stream over", "the snapshot restored; it did not end the terminal: \(channel.reason)")
        #expect(rows.prefix(2) == ["first line", "$"])

        let history = try ghosttySnapshot(of: numberedLines(3000))
        let (plain, _) = try await Self.restore(history)
        let (skipping, _) = try await Self.restore(try Self.withUnknownRecord(history, before: SSHTerminalSnapshotFormat.Tag.page))
        #expect(skipping.reason == "stream over", "the snapshot restored; it did not end the terminal: \(skipping.reason)")
        #expect(skipping.engine.scrollbar.total == plain.engine.scrollbar.total)
    }

    /// A pane draws at READY: its screen restores from the records through
    /// READY alone, and the older history follows a record at a time, ending
    /// with exactly what one decode of the whole snapshot gives.
    @Test func thePaneDrawsAtReadyAndItsHistoryFollowsRecordByRecord() throws {
        let snapshot = try ghosttySnapshot(of: numberedLines(4000))
        let (screen, records) = try snapshotParts(snapshot)
        try #require(records.count > 3, "history pages after READY")

        let engine = try SSHTerminalEngine(geometry: .init(columns: 80, rows: 24)) { _ in }
        try engine.beginRestore(screen)
        #expect(Self.text(engine).contains { $0.contains("line 3999") }, "the screen draws before its history is in")
        let atReady = engine.scrollbar.total
        for record in records.dropLast() {
            #expect(try engine.continueRestore(record) == false)
        }
        #expect(try engine.continueRestore(try #require(records.last)), "FINISH completes the snapshot")

        let whole = try SSHTerminalEngine(geometry: .init(columns: 80, rows: 24)) { _ in }
        try whole.beginRestore(screen)
        #expect(try whole.continueRestore(records.reduce(Data(), +)))
        #expect(engine.scrollbar.total == whole.scrollbar.total && engine.scrollbar.total > atReady)
        engine.scrollToRow(0)
        #expect(Self.text(engine).first == "line 0", "the oldest line arrived")
    }

    /// A history record that does not decode after the screen drew still ends
    /// the pane, and the reason says the history was the part that failed.
    @Test func aDamagedHistoryRecordEndsThePaneNamingItsHistory() async throws {
        let (screen, records) = try snapshotParts(try ghosttySnapshot(of: numberedLines(4000)))
        let page = try #require(records.firstIndex {
            SSHTerminalSnapshotFormat.record(in: $0, at: 0)?.tag == SSHTerminalSnapshotFormat.Tag.page.rawValue
        })
        var damaged = records
        damaged[page][damaged[page].startIndex + 20] ^= 0xFF // a payload byte: its CRC no longer matches
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        channel.opened(RecordingConnection())
        var restored = 0
        channel.snapshotRestored = { _ in restored += 1 }
        let queue = SSHTerminalEventQueue()
        queue.pushSnapshot(screen)
        for record in damaged { queue.pushSnapshotRecords(record) }
        queue.end("stream over")
        await channel.consume(queue)
        #expect(restored == 1, "the screen drew")
        #expect(channel.reason == SSHTerminalSnapshotFormat.unreadableHistory)
    }

    /// A long pane keeps all of its history: 30,000 phone-width rows, more
    /// than the 18,000 or so the old 8 MiB cap held, all arrive and stay.
    @Test func aLongPanesWholeHistoryIsKept() throws {
        let (screen, records) = try snapshotParts(try ghosttySnapshot(of: numberedLines(30000), columns: 49, rows: 45))
        let engine = try SSHTerminalEngine(geometry: .init(columns: 49, rows: 45)) { _ in }
        try engine.beginRestore(screen)
        #expect(try engine.continueRestore(records.reduce(Data(), +)))
        engine.scrollToRow(0)
        #expect(Self.text(engine).first == "line 0", "the oldest line is still there")
        engine.scrollToRow(15000)
        #expect(Self.text(engine).first == "line 15000", "history deep in the pane reads back after compression")
    }

    /// An image restores at READY with its placement; its pixels arrive with
    /// a later record, and only then can the grid draw it.
    @Test func anImagesPixelsFollowItsPlacement() throws {
        let (screen, records) = try snapshotParts(try Data(contentsOf: TestFixtures.url("rex-kitty-image-snapshot.bin")))
        let engine = try SSHTerminalEngine(geometry: .init(columns: 80, rows: 24)) { _ in }
        try engine.beginRestore(screen)
        var frame = engine.frame()
        var image = try #require(frame.kitty?.imagesByID[7], "the image and its placement are there at READY")
        var graphics = try #require(frame.kittyGraphics)
        #expect(image.resolvePixels(graphics) == nil, "its pixels are not")

        #expect(try engine.continueRestore(records.reduce(Data(), +)))
        frame = engine.frame()
        image = try #require(frame.kitty?.imagesByID[7])
        graphics = try #require(frame.kittyGraphics)
        let pixels = try #require(image.resolvePixels(graphics))
        #expect(Array(UnsafeBufferPointer(start: pixels.pointer, count: pixels.byteCount)) == [0xFF, 0x00, 0x00])
    }

    /// Ghostty drops the history pages of a terminal whose width changed since
    /// READY. The restored terminal keeps the snapshot's width until its
    /// history is in, then takes this screen's, so a pane opened (or rotated)
    /// at another width still gets all of it.
    @Test func theSnapshotsWidthHoldsUntilItsHistoryIsIn() throws {
        let (screen, records) = try snapshotParts(try ghosttySnapshot(of: numberedLines(4000)))
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 10)) { _ in }
        try engine.beginRestore(screen)
        #expect(engine.frame().rows.first?.count == 80)
        engine.resize(.init(columns: 50, rows: 12))
        #expect(engine.frame().rows.first?.count == 80)
        #expect(try engine.continueRestore(records.reduce(Data(), +)))
        #expect(engine.frame().rows.first?.count == 50)
        #expect(engine.frame().rows.count - engine.frame().rowsBelowViewport == 12)
        engine.scrollToRow(0)
        #expect(Self.text(engine).first == "line 0", "no history page was dropped")
    }

    /// Records keep their order with what follows them: output after the
    /// snapshot lands on its finished history. A switch that overtakes a pane
    /// mid-history drops the records it still sends: they never reach the
    /// pane swapped in.
    @Test func aSwitchMidHistoryDropsThePaneLeftBehindsRecords() async throws {
        let (screenA, recordsA) = try snapshotParts(try ghosttySnapshot(of: numberedLines(4000, name: "a")))
        let (screenB, recordsB) = try snapshotParts(try ghosttySnapshot(of: numberedLines(3000, name: "b")))
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        channel.opened(RecordingConnection())
        defer { channel.close(reason: "done") }
        var restored: [String?] = []
        channel.snapshotRestored = { restored.append($0) }
        let queue = SSHTerminalEventQueue()
        queue.pushSnapshot(screenA, block: "a")
        queue.pushSnapshotRecords(recordsA[0], block: "a")
        queue.pushSnapshot(screenB, block: "b")
        for record in recordsA.dropFirst() { queue.pushSnapshotRecords(record, block: "a") }
        for record in recordsB { queue.pushSnapshotRecords(record, block: "b") }
        queue.push(.data(Data("after".utf8)))
        queue.end("stream over")
        await channel.consume(queue)

        #expect(channel.reason == "stream over", "nothing failed: \(channel.reason)")
        #expect(restored == ["a", "b"])
        #expect(Self.text(channel.engine).contains { $0.hasSuffix("$ after") }, "output after the snapshot")
        channel.engine.scrollToRow(0)
        #expect(Self.text(channel.engine).first == "b line 0", "b's whole history, and none of a's")
    }

    private static func text(_ engine: SSHTerminalEngine) -> [String] {
        let frame = engine.frame()
        return frame.rows.prefix(frame.rows.count - frame.rowsBelowViewport)
            .map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    }

    /// Restores `snapshot` the way a Rex pane's stream delivers it, then ends
    /// the stream with "stream over". Returns the channel and its grid's rows.
    private static func restore(_ snapshot: Data) async throws -> (SSHTerminalChannel, [String]) {
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        channel.opened(RecordingConnection())
        let queue = SSHTerminalEventQueue()
        try pushRexStream(snapshot, to: queue)
        queue.end("stream over")
        await channel.consume(queue)
        return (channel, text(channel.engine))
    }

    /// `snapshot` with a record of a kind no Ghostty defines (tag 0x7FFF)
    /// right before the first record of kind `tag`, with the CRC32C the
    /// format requires of every record: over the tag and payload length, then
    /// the payload.
    private static func withUnknownRecord(_ snapshot: Data, before tag: SSHTerminalSnapshotFormat.Tag) throws -> Data {
        let bytes = [UInt8](snapshot)
        func integer(at offset: Int, size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        func littleEndian(_ value: some FixedWidthInteger) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var offset = 10 // The "GHOSTSNP" magic and the version.
        while integer(at: offset, size: 2) != Int(tag.rawValue) {
            offset += 10 + integer(at: offset + 2, size: 4)
            try #require(offset + 10 <= bytes.count, "the snapshot has a record of that kind")
        }
        let payload = Data("a record from a newer Rex".utf8)
        let prefix = littleEndian(UInt16(0x7FFF)) + littleEndian(UInt32(payload.count))
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in prefix + payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1 }
        }
        let record = prefix + littleEndian(~crc) + payload
        return Data(bytes[..<offset]) + record + Data(bytes[offset...])
    }
}

private actor RecordingConnection: SSHTerminalConnection {
    private(set) var sent = [Data]()
    func send(_ bytes: Data) async throws { sent.append(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream { throw SSHConnectionError.notConnected }
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async {}
}

// MARK: - A Rex session as a terminal

/// `session.view` as a Rex server answers it for one window split in two,
/// captured from a running server (labels and ids kept, nothing else).
private let realSessionView = #"""
{"revision":91,"session_id":"session:01a18b8b-8553-7528-a80f-b22306f97869","label":"wispy-lagoon","active_window_id":"window:01a18b8b-8573-7a06-b823-adc052256a88","windows":[{"window_id":"window:01a18b8b-8573-7a06-b823-adc052256a88","label":"Window 52256a88","focused_block_id":"block:01a18b97-3672-78d5-8997-d7f0f053c94a","layers":[{"layer_id":"layer:01a18b8b-8573-7a0e-8875-5b84bd348249","kind":"tiled","bounds":[0,0,1,1],"layout":{"rect":[0,0,1,1],"split":{"split_id":"split:01a18b97-3693-7ce8-afb3-b248042618d0","direction":"horizontal","ratio":0.5,"before":{"rect":[0,0,0.5,1],"block_id":"block:01a18b8b-8553-762a-a19b-0e6b2ec933b8"},"after":{"rect":[0.5,0,0.5,1],"block_id":"block:01a18b97-3672-78d5-8997-d7f0f053c94a"}}},"blocks":[{"block_id":"block:01a18b8b-8553-762a-a19b-0e6b2ec933b8","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell","host_id":"ae49134e-bb38-46b4-b36b-0b34cfc1656b"},{"block_id":"block:01a18b97-3672-78d5-8997-d7f0f053c94a","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell","host_id":"ae49134e-bb38-46b4-b36b-0b34cfc1656b"}]}]}]}
"""#

@Suite("Rex session layout")
struct RexSessionLayoutTests {
    private func layout(_ json: String) throws -> RexSessionLayout {
        RexSessionLayout(view: try JSONDecoder().decode(RexView.self, from: Data(json.utf8)))
    }

    /// A real server's view: the tiled layer's split decodes to its two
    /// blocks, before then after, each at its rect.
    @Test func aRealViewDecodesToPanesAndMinimapCells() throws {
        let view = try JSONDecoder().decode(RexView.self, from: Data(realSessionView.utf8))
        let tiled = try #require(view.windows?.first?.layers?.first)
        #expect(tiled.kind == "tiled")
        guard case .split(let direction, let ratio, let before, let after, let rect)? = tiled.layout else {
            Issue.record("the layout is not a split")
            return
        }
        #expect(direction == .horizontal && ratio == 0.5 && rect == [0, 0, 1, 1])
        #expect(before == .block(id: "block:01a18b8b-8553-762a-a19b-0e6b2ec933b8", rect: [0, 0, 0.5, 1]))
        #expect(after == .block(id: "block:01a18b97-3672-78d5-8997-d7f0f053c94a", rect: [0.5, 0, 0.5, 1]))

        let panes = RexSessionLayout(view: view)
        #expect(panes.panes.map(\.blockID) == ["block:01a18b8b-8553-762a-a19b-0e6b2ec933b8", "block:01a18b97-3672-78d5-8997-d7f0f053c94a"])
        #expect(panes.minimap(around: "block:01a18b97-3672-78d5-8997-d7f0f053c94a").map(\.rect) == [
            CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        ])
    }

    /// Strip order: windows in view order; inside a window, an in-order walk
    /// of the split tree (before, then after), whatever order `blocks` lists.
    /// A block that is not a terminal is no pane. The minimap is the shown
    /// pane's window only.
    @Test func paneOrderFollowsWindowsThenTheLayoutTree() throws {
        func leaf(_ id: String, _ rect: String) -> String { #"{"rect":\#(rect),"block_id":"\#(id)"}"# }
        func block(_ id: String, creator: String = "com.superlogical.terminal") -> String {
            #"{"block_id":"\#(id)","label":"\#(id)","creator_name":"\#(creator)"}"#
        }
        // Window one: a vertical split whose bottom half splits again; `blocks` lists them scrambled.
        let inner = #"{"rect":[0,0.5,1,0.5],"split":{"split_id":"s2","direction":"horizontal","ratio":0.5,"before":\#(leaf("c", "[0,0.5,0.5,0.5]")),"after":\#(leaf("d", "[0.5,0.5,0.5,0.5]"))}}"#
        let tree = #"{"rect":[0,0,1,1],"split":{"split_id":"s1","direction":"vertical","ratio":0.5,"before":\#(leaf("b", "[0,0,1,0.5]")),"after":\#(inner)}}"#
        let json = #"{"revision":1,"session_id":"s","windows":[{"window_id":"w1","layers":[{"kind":"tiled","layout":\#(tree),"blocks":[\#([block("d"), block("b"), block("walkthrough", creator: "com.superlogical.onboarding"), block("c")].joined(separator: ","))]}]},{"window_id":"w2","layers":[{"kind":"tiled","layout":\#(leaf("e", "[0,0,1,1]")),"blocks":[\#(block("e"))]}]}]}"#
        let parsed = try layout(json)
        #expect(parsed.panes.map(\.blockID) == ["b", "c", "d", "e"])
        #expect(parsed.panes.map(\.windowName) == ["Window 1", "Window 1", "Window 1", "Window 2"])
        #expect(parsed.minimap(around: "c").map(\.blockID) == ["b", "c", "d"])
        #expect(parsed.minimap(around: "e").map(\.blockID) == ["e"])
        // A layout this build cannot read still lists its blocks.
        let unreadable = try layout(#"{"revision":1,"session_id":"s","windows":[{"window_id":"w","layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1]},"blocks":[\#(block("x")),\#(block("y"))]}]}]}"#)
        #expect(unreadable.panes.map(\.blockID) == ["x", "y"] && unreadable.minimap(around: "x").isEmpty)
    }

    /// One rule for every pane, with no program known by name: a program that
    /// reports gets a monogram of the first character of its name; a plain shell
    /// or a name with nothing to start from gets the terminal glyph.
    @Test func aPanesIconIsAMonogramOfItsProgramOrTheTerminalGlyph() {
        typealias Icon = SSHTerminalPaneIcon
        #expect(Icon(program: nil) == .terminal, "a plain shell")
        #expect(Icon(program: "") == .terminal && Icon(program: "   ") == .terminal, "no name")
        #expect(Icon(program: "claude") == .monogram("C"), "a lowercase Latin initial is uppercased")
        #expect(Icon(program: "Codex") == .monogram("C") && Icon(program: "7zip") == .monogram("7"))
        #expect(Icon(program: "\u{03C0} - oppi") == .monogram("\u{03C0}"), "π stays π: not an initial")
        #expect(Icon(program: "\u{2733} Fixing the build") == .monogram("\u{2733}"), "a program's mark that is no letter")
        #expect(Icon(program: "  pi") == .monogram("P"), "leading space is not the initial")
        #expect(Icon(program: "e\u{0301}cho") == .monogram("\u{00C9}"), "a whole grapheme, not a scalar")
        #expect(Icon(program: "\u{00F1}and\u{00FA}") == .monogram("\u{00D1}"))
        #expect(Icon(program: "\u{1F469}\u{200D}\u{1F4BB} dev") == .monogram("\u{1F469}\u{200D}\u{1F4BB}"), "an emoji sequence is one grapheme")
        #expect(Icon(program: "\u{00DF}tack") == .monogram("\u{00DF}"), "a capital of more than one character is not an initial: ß stays")
        #expect(Icon(program: "\u{FB01}x") == .monogram("\u{FB01}"), "a ligature whose capital is two letters stays")
        // What is drawn as a picture: an emoji by default, or one that asked for it with U+FE0F.
        #expect(Icon.monogram("\u{1F680}").isPicture && Icon(program: "\u{26A0}\u{FE0F} warn").isPicture)
        #expect(Icon(program: "\u{26A1}\u{FE0F}").isPicture)
        #expect(!Icon.monogram("\u{2733}").isPicture && !Icon.monogram("\u{03C0}").isPicture && !Icon.monogram("C").isPicture)
    }

    /// Every monogram is drawn where the terminal glyph is drawn (its symbol
    /// canvas has padding, so the whole canvas is not the measure), so the bar
    /// does not change size or weight with the pane. A monogram is a tinted
    /// template, and a picture keeps its colors.
    @Test @MainActor func everyPaneIconIsDrawnWhereTheTerminalGlyphIs() {
        typealias Icon = SSHTerminalPaneIcon
        let terminal = Icon.drawnBounds(of: Icon.terminal.image())
        #expect(terminal.width > 10 && terminal.height > 8)
        for icon in [Icon.monogram("P"), .monogram("\u{03C0}"), .monogram("\u{2733}"), .monogram("W"), .monogram("\u{00DF}")] {
            let drawn = Icon.drawnBounds(of: icon.image())
            #expect(abs(drawn.width - terminal.width) <= 1 && abs(drawn.height - terminal.height) <= 1, "\(icon) is as big as the glyph: \(drawn) vs \(terminal)")
            #expect(abs(drawn.midX - terminal.midX) <= 1 && abs(drawn.midY - terminal.midY) <= 1, "\(icon) sits where the glyph does")
            #expect(icon.image().renderingMode == .alwaysTemplate)
        }
        for picture in [Icon.monogram("\u{1F680}"), .monogram("\u{26A0}\u{FE0F}")] {
            let drawn = Icon.drawnBounds(of: picture.image())
            #expect(drawn.width <= terminal.width + 2 && drawn.height <= terminal.height + 2 && !drawn.isEmpty)
            #expect(picture.image().renderingMode == .alwaysOriginal)
        }
        #expect(Icon.terminal.image().renderingMode == .alwaysTemplate)
    }

    @Test func aClosedPanesNeighbourIsTheNextThenThePrevious() {
        let order = ["a", "b", "c"]
        #expect(RexSessionLayout.neighbour(of: "b", in: order, surviving: ["a", "c"]) == "c")
        #expect(RexSessionLayout.neighbour(of: "c", in: order, surviving: ["a", "b"]) == "b")
        #expect(RexSessionLayout.neighbour(of: "b", in: order, surviving: ["a"]) == "a")
        #expect(RexSessionLayout.neighbour(of: "a", in: ["a"], surviving: []) == nil)
    }

    @Test func aSwipePastTheEndsDoesNothingAndEachSideMovesOnePane() {
        let state = RexSessionState(
            panes: ["a", "b", "c"].map { .init(blockID: $0, name: $0) }, shown: "b", minimap: []
        )
        #expect(state.pane(offsetBy: 1) == "c" && state.pane(offsetBy: -1) == "a")
        var last = state
        last.shown = "c"
        #expect(last.pane(offsetBy: 1) == nil)
        var first = state
        first.shown = "a"
        #expect(first.pane(offsetBy: -1) == nil)
        #expect(state.neighbour(offsetBy: 1)?.name == "c" && last.neighbour(offsetBy: 1) == nil)
        #expect(SSHTerminalPaneSwipe.begins(velocity: CGPoint(x: 300, y: 40)) && !SSHTerminalPaneSwipe.begins(velocity: CGPoint(x: 300, y: 250)))
    }

    /// Letting go of a drag: far enough or fast enough along the axis, toward a
    /// pane that exists, and not thrown back the way it came, commits; anything
    /// else puts the screen back and asks for nothing.
    @Test func letGoOfADragCommitsOnlyForAClearSwipeTowardAPane() {
        func release(_ x: CGFloat, _ y: CGFloat = 0, velocity: CGFloat = 0, canStep: Bool = true) -> SSHTerminalPaneSwipe.Release {
            SSHTerminalPaneSwipe.release(
                translation: CGPoint(x: x, y: y), velocity: CGPoint(x: velocity, y: 0), canStep: { _ in canStep }, canCreate: false
            )
        }
        #expect(release(-80, 10) == .commit(step: 1))
        #expect(release(80, -10) == .commit(step: -1))
        #expect(release(-30, velocity: -900) == .commit(step: 1), "a short flick commits")
        #expect(release(-30, velocity: -100) == .springBack, "short and slow springs back")
        #expect(release(-80, 70) == .springBack, "a diagonal drag is not a swipe")
        #expect(release(-80, canStep: false) == .springBack, "no pane that way")
        #expect(release(-80, velocity: 900) == .springBack, "far, then thrown back")
        #expect(release(-55) == .springBack && release(-56) == .commit(step: 1), "the distance threshold")
    }

    /// A new pane starts where the shown one is: Rex's `pwd` is a path or the
    /// `file://` URL OSC 7 carries, whose host and escapes are not the folder.
    @Test func aNewPanesFolderComesFromThePwdRexReports() {
        #expect(RexSessionConnection.folder(fromPwd: "/Users/chen/oppi") == "/Users/chen/oppi")
        #expect(RexSessionConnection.folder(fromPwd: "file://mac-studio.local/Users/chen/my%20proj") == "/Users/chen/my proj")
        #expect(RexSessionConnection.folder(fromPwd: "file:///tmp") == "/tmp")
        #expect(RexSessionConnection.folder(fromPwd: "") == nil && RexSessionConnection.folder(fromPwd: "~/oppi") == nil)
        #expect(RexSessionConnection.folder(fromPwd: "file://host") == nil)
    }

    /// Past the last pane (the finger moving left, with no pane after) the same
    /// distance and flick rules open a new pane instead of springing back; the
    /// first pane (the finger moving right) keeps springing back, and a session
    /// that cannot open one springs back at both ends.
    @Test func letGoPastTheLastPaneOpensANewPaneByTheSameRules() {
        func release(
            _ x: CGFloat, _ y: CGFloat = 0, velocity: CGFloat = 0, next: Bool = false, previous: Bool = false, canCreate: Bool = true
        ) -> SSHTerminalPaneSwipe.Release {
            SSHTerminalPaneSwipe.release(
                translation: CGPoint(x: x, y: y), velocity: CGPoint(x: velocity, y: 0),
                canStep: { $0 > 0 ? next : previous }, canCreate: canCreate
            )
        }
        #expect(release(-80, 10) == .newPane)
        #expect(release(-30, velocity: -900) == .newPane, "a short flick opens one")
        #expect(release(-30, velocity: -100) == .springBack, "short and slow springs back")
        #expect(release(-55) == .springBack && release(-56) == .newPane, "the distance threshold is a switch's")
        #expect(release(-80, 70) == .springBack, "a diagonal drag is not a swipe")
        #expect(release(-80, velocity: 900) == .springBack, "far, then thrown back")
        #expect(release(80) == .springBack, "the first pane keeps its rubber band")
        #expect(release(80, previous: true) == .commit(step: -1))
        #expect(release(-80, next: true) == .commit(step: 1), "a pane after wins over a new one")
        #expect(release(-80, canCreate: false) == .springBack)
        #expect(SSHTerminalPaneSwipe.crossesThreshold(-55) == false && SSHTerminalPaneSwipe.crossesThreshold(-56))
    }

    /// The screen follows the finger one to one while a pane lies that way, and
    /// gives way like a scroll view's edge when none does: never to the far
    /// side, never past the width, and always less than the finger.
    @Test func theDraggedScreenFollowsTheFingerAndResistsAtAnEdge() {
        let width: CGFloat = 400
        func offset(_ x: CGFloat, canStep: Bool) -> CGFloat {
            SSHTerminalPaneSwipe.offset(translation: x, width: width, canStep: canStep)
        }
        #expect(offset(-137, canStep: true) == -137 && offset(60, canStep: true) == 60)
        #expect(offset(-900, canStep: true) == -width, "never past the pane's width")
        #expect(offset(0, canStep: false) == 0)
        let banded = [20, 80, 200, 600].map { offset(-CGFloat($0), canStep: false) }
        #expect(zip(banded, banded.dropFirst()).allSatisfy { $0 > $1 } && banded.allSatisfy { $0 < 0 && $0 > -width })
        #expect(zip(banded, [20, 80, 200, 600]).allSatisfy { abs($0) < CGFloat($1) })
        #expect(offset(150, canStep: false) == -offset(-150, canStep: false))
    }
}

@Suite("Rex session terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexSessionTerminalTests {
    static let session = "session:rex-test"

    /// A session of panes `a`, `b`, ... on a fake host, opened on `first`, the
    /// way the connect session opens one, with the grid at 40 × 10.
    @MainActor struct Rig {
        let fake: RexFakeSession
        let channel: SSHTerminalChannel
        let connection: RexSessionConnection
        let model: RexSessionModel
        let consumer: Task<Void, Never>

        var rows: [String] {
            channel.engine.frame().rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        }

        func shows(_ text: String) -> Bool { rows.contains { $0.contains(text) } }

        func stop() async {
            channel.close(reason: "done")
            consumer.cancel()
            await consumer.value
        }
    }

    static func block(_ name: String) -> String { "block:\(name)" }

    /// `reporting` gives a pane's OSC 7501 records (Rex's JSON) by pane name,
    /// `folders` the folder a pane's shell reported (`pwd`).
    /// `holding` panes' `data.connect` waits for `release`; the first pane's
    /// screen is then not waited for.
    func open(
        _ names: [String], first: String? = nil, reporting: [String: String] = [:], folders: [String: String] = [:],
        holding: Set<String> = []
    ) async throws -> Rig {
        let fake = RexFakeSession(sessionID: Self.session, panes: names.map {
            .init(
                block: Self.block($0), label: "shell", title: "title \($0)", screen: "screen of \($0)\r\n$ ",
                records: reporting[$0] ?? "[]", pwd: folders[$0]
            )
        })
        let (transport, control) = try await fake.connect()
        let queue = SSHTerminalEventQueue()
        let opening = first ?? names[0]
        let connection = try await RexSessionConnection.open(
            transport: transport, control: control,
            target: RexPaneTarget(sessionID: Self.session, blockID: Self.block(opening), label: "shell"), queue: queue
        )
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        let model = RexSessionModel(connection: connection)
        channel.rex = model
        channel.opened(connection)
        let consumer = Task { await channel.consume(queue) }
        fake.hold(dataConnectFor: Set(holding.map(Self.block)))
        channel.resize(.init(columns: 40, rows: 10))
        let rig = Rig(fake: fake, channel: channel, connection: connection, model: model, consumer: consumer)
        guard holding.isEmpty else { return rig }
        guard await waitForMainActorCondition(timeout: .seconds(5), { rig.shows("screen of \(opening)") }) else {
            await rig.stop()
            Issue.record("the first pane never showed")
            throw CancellationError()
        }
        // The pane's size is on its way to Rex, not just the grid's: a stall on a
        // cold start could let the data connection arm before the size arrives,
        // and the first switch then has no geometry to size the next pane by.
        guard await waitForMainActorCondition(timeout: .seconds(5), {
            fake.requests("com.superlogical.terminal.resize").contains { $0.string("block_id") == Self.block(opening) }
        }) else {
            await rig.stop()
            Issue.record("the opening pane was never sized")
            throw CancellationError()
        }
        return rig
    }

    /// Switching takes the new pane for size, sizes it, and only then asks for
    /// its stream, whose snapshot replaces the grid. Typing and resizing go to
    /// it from then on, the pane left behind is handed back, and nothing ever
    /// focuses a pane on the host.
    @Test func switchingRetargetsWritesAndResizesAndRestoresTheNewPanesSnapshot() async throws {
        let rig = try await open(["a", "b"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        #expect(rig.model.state.shown == a && rig.model.state.panes.map(\.name) == ["title a", "title b"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.map(\.name) == ["title a", "title b"] })

        rig.model.show(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") }, "the new pane's snapshot is on the grid")
        #expect(!rig.shows("screen of a"))

        // Order of what Rex was asked: take, size, then its stream.
        let methods = rig.fake.requests.filter { $0.string("block_id") == b || $0.method == "session.own_block" }
        let own = try #require(methods.firstIndex { $0.method == "session.own_block" && $0.payload.contains(b) })
        let resize = try #require(methods.firstIndex { $0.method == "com.superlogical.terminal.resize" && $0.string("block_id") == b })
        let connect = try #require(methods.firstIndex { $0.method == "data.connect" && $0.string("block_id") == b })
        #expect(own < resize && resize < connect)
        #expect(rig.fake.requests("session.own_block").last?.payload.contains(#""mode":"take""#) == true)
        let size = try #require(rig.fake.requests("com.superlogical.terminal.resize").last { $0.string("block_id") == b }?.payload)
        #expect(size.contains(#""columns":40"#) && size.contains(#""rows":10"#))

        #expect(rig.fake.dataHosts.count == 2 && rig.fake.dataHosts[0].isClosed, "one data connection at a time")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("session.disown_block").contains { $0.payload.contains(a) }
        }, "the pane left behind goes back to the host's own clients")

        // Typing and resizing now reach b.
        rig.channel.send(Data("ls\r".utf8))
        rig.channel.resize(.init(columns: 50, rows: 12))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("com.superlogical.terminal.write").last?.string("block_id") == b
                && rig.fake.requests("com.superlogical.terminal.resize").last?.payload.contains(#""columns":50"#) == true
        })
        #expect(rig.fake.requests("com.superlogical.terminal.write").allSatisfy { $0.string("block_id") == b })
        #expect(rig.fake.requests("com.superlogical.terminal.resize").last?.string("block_id") == b)

        // The host's own focus never moved.
        #expect(!rig.fake.requests.contains { $0.method.contains("focus") })
        await rig.stop()
    }

    /// Opening a pane costs as few round trips as it can: the screen's first
    /// size goes at once and is the only resize the pane gets, and its data
    /// connection opens and upgrades while Rex is still issuing the ticket
    /// HELLO needs.
    @Test func theFirstPaneIsSizedOnceAndItsStreamOpensBeforeItsTicket() async throws {
        let rig = try await open(["a"], holding: ["a"])
        let a = Self.block("a")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.dataHosts.first?.isUpgraded == true },
                "upgraded with data.connect still unanswered")
        #expect(rig.fake.dataHosts.first?.isWelcomed == false, "HELLO waits for the ticket")
        rig.fake.release(dataConnectFor: a)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of a") })
        let resizes = rig.fake.requests("com.superlogical.terminal.resize")
        #expect(resizes.count == 1 && resizes.first?.string("block_id") == a, "sized once, by the screen")
        await rig.stop()
    }

    /// A pane's status and progress belong to its program: a pane swapped in
    /// does not show the one before's.
    @Test func statusOfThePaneLeftBehindDoesNotFollowTheSwitch() async throws {
        let rig = try await open(["a", "b"])
        rig.fake.dataHosts[0].emit("\u{1B}]7501;state=blocked:kind=permission:app=pi:msg=\(Data("ok?".utf8).base64EncodedString())\u{1B}\\")
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.programStatus.root != nil })

        rig.model.show(Self.block("b"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") })
        #expect(rig.channel.programStatus.records.isEmpty)
        await rig.stop()
    }

    /// A fast double swipe goes through the strip's order, one pane at a time,
    /// and ends on the last pane asked for. The pane overtaken never gets a
    /// data connection, and what a pane left behind sends late never reaches
    /// the grid.
    @Test func aSupersededSwitchNeverReachesTheGridAndTheLastRequestWins() async throws {
        let rig = try await open(["a", "b", "c"])
        let (b, c) = (Self.block("b"), Self.block("c"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 3 })
        rig.fake.hold(dataConnectFor: [b])

        #expect(rig.model.step(1) == true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.fake.requests("data.connect").filter { $0.string("block_id") == b }.isEmpty })
        // The second swipe lands while b's ticket is still outstanding, and counts from b.
        #expect(rig.model.step(1) == true)
        #expect(rig.connection.state.shown == c)
        rig.fake.release(dataConnectFor: b)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        let helloed = rig.fake.dataHosts.compactMap { $0.block }
        #expect(helloed == [Self.block("a"), c], "b's stream never said HELLO")
        let abandonedClosed = rig.fake.dataHosts.filter { $0.block == nil }.allSatisfy { $0.isClosed }
        #expect(abandonedClosed, "and it was closed")
        #expect(rig.model.step(1) == false, "a swipe past the last pane does nothing")

        // Output the first pane's stream sends after it was left is not drawn.
        rig.fake.dataHosts[0].emit("LATE FROM A")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { !rig.shows("LATE FROM A") })
        #expect(rig.channel.connected, "a stream closing because of a switch does not end the terminal")
        await rig.stop()
    }

    /// A pane closed on the host moves the terminal to its neighbour (the
    /// next, else the one before), by Rex's event or by its data connection
    /// closing; with none left the terminal ends and says why.
    @Test func closingTheShownPaneMovesToItsNeighbourAndTheLastOneEndsTheTerminal() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b, c) = (Self.block("a"), Self.block("b"), Self.block("c"))
        rig.model.show(b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") })

        rig.fake.blockClosed(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") }, "the next pane")
        #expect(rig.model.state.shown == c)

        // The last pane closes through its stream: the one before it.
        rig.fake.dataHosts.last?.closePane()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.shown == a || rig.model.state.shown == b })
        #expect(rig.channel.connected)

        // A pane closing that is not on screen changes nothing.
        let shown = rig.model.state.shown
        rig.fake.blockClosed(shown == a ? c : a)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { rig.model.state.shown == shown })
        await rig.stop()
    }

    /// The bridge is `exec nc -U`: when Rex closes the pane's socket `nc`
    /// exits and the channel reports it closed, right behind the close frame
    /// and before the neighbour's stream is open. That is the pane leaving,
    /// not the connection failing: the terminal stays and ends on the neighbour.
    @Test func theBridgeExitingWithAClosedPaneDoesNotEndTheTerminal() async throws {
        let rig = try await open(["a", "b", "c"])
        let (b, c) = (Self.block("b"), Self.block("c"))
        rig.model.show(b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") })
        // The neighbour's stream is slow to open, so the bridge's end lands first.
        rig.fake.hold(dataConnectFor: [c])
        rig.fake.dataHosts[1].closePane()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.shown == c })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            rig.channel.connected && rig.model.state.shown == c
        })
        rig.fake.release(dataConnectFor: c)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        #expect(rig.channel.connected)
        await rig.stop()
    }

    /// The neighbour closed before the terminal heard (Rex refuses to take it):
    /// the terminal does not fall back onto the pane that just closed, and moves
    /// to the first pane that is still there.
    @Test func aRefusedNeighbourMovesOnToALivePaneNotBackToTheClosedOne() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b, c) = (Self.block("a"), Self.block("b"), Self.block("c"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 3 })
        rig.fake.refuse(["session.own_block"], for: [b])
        rig.fake.blockClosed(a)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        #expect(rig.model.state.shown == c && rig.channel.connected)
        #expect(rig.fake.requests("data.connect").allSatisfy { $0.string("block_id") != b })
        await rig.stop()
    }

    /// A refusal that lands after a newer request must not undo it: the
    /// request for C stands, and the terminal ends up on C, not back on A.
    @Test func aRefusalDoesNotOverwriteANewerRequest() async throws {
        let rig = try await open(["a", "b", "c"])
        let (b, c) = (Self.block("b"), Self.block("c"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 3 })
        rig.fake.hold(dataConnectFor: [b])
        rig.model.show(b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == b }
        })
        rig.model.show(c)
        rig.fake.refuse(dataConnectFor: b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of c") })
        #expect(rig.model.state.shown == c && rig.channel.connected, "\(rig.channel.reason)")
        await rig.stop()
    }

    /// A to B, overtaken by C before B's stream said HELLO, and C refused: the
    /// terminal goes back to A, the pane that was on screen, not to B, which
    /// never drew.
    @Test func aRefusalAfterAnOvertakenSwitchGoesBackToThePaneOnScreen() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b, c) = (Self.block("a"), Self.block("b"), Self.block("c"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 3 })
        rig.fake.hold(dataConnectFor: [b, c])
        rig.model.show(b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == b }
        })
        rig.model.show(c)
        rig.fake.release(dataConnectFor: b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == c }
        })
        rig.fake.refuse(dataConnectFor: c)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.model.state.shown == a && rig.fake.requests("data.connect").filter { $0.string("block_id") == a }.count == 2
        }, "back to a, reopened")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of a") })
        #expect(rig.channel.connected, "\(rig.channel.reason)")
        #expect(rig.fake.requests("data.connect").filter { $0.string("block_id") == b }.count == 1, "b was never asked for again")
        await rig.stop()
    }

    /// With every other pane gone, a refused neighbour ends the terminal with
    /// the reason, instead of leaving it on a dead pane.
    @Test func aRefusedNeighbourWithNoPaneLeftEndsTheTerminal() async throws {
        let rig = try await open(["a", "b"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        rig.fake.refuse(["session.own_block"], for: [Self.block("b")])
        rig.fake.blockClosed(Self.block("a"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected })
        #expect(rig.channel.reason == "The pane closed in Rex.")
        await rig.stop()
    }

    /// The view the terminal holds is stale until Rex announces the next one:
    /// a second close must not hand the terminal back to the pane that closed
    /// first.
    @Test func aSecondCloseNeverHandsBackToTheFirstClosedPane() async throws {
        let rig = try await open(["a", "b"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        rig.fake.blockClosed(a)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") })
        rig.fake.blockClosed(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected })
        #expect(rig.channel.reason == "The pane closed in Rex.")
        #expect(rig.fake.requests("data.connect").filter { $0.string("block_id") == a }.count == 1, "only the one that opened the terminal")
        await rig.stop()
    }

    /// A switch that is overtaken after the pane was taken (A to B, then back
    /// to A before B's stream) must not leave B at this screen's size.
    @Test func aSwitchOvertakenAfterTakingAPaneHandsItBack() async throws {
        let rig = try await open(["a", "b"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        rig.fake.hold(dataConnectFor: [b])
        rig.model.show(b)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == b }
        })
        rig.model.show(a)
        rig.fake.release(dataConnectFor: b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("session.disown_block").contains { $0.payload.contains(b) }
        })
        let helloed = rig.fake.dataHosts.compactMap { $0.block }
        #expect(helloed.allSatisfy { $0 == a }, "b's stream never said HELLO")
        let abandonedClosed = rig.fake.dataHosts.filter { $0.block == nil }.allSatisfy { $0.isClosed }
        #expect(abandonedClosed, "and it was closed")
        await rig.stop()
    }

    /// Rex refuses a write or a resize for a pane that closed before the
    /// terminal heard of it. That pane is leaving; the session is not over.
    @Test func aRefusedWriteOrResizeDoesNotEndTheTerminal() async throws {
        let rig = try await open(["a", "b"])
        rig.fake.refuse(["com.superlogical.terminal.write", "com.superlogical.terminal.resize"])
        rig.channel.send(Data("x".utf8))
        rig.channel.resize(.init(columns: 50, rows: 12))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            !rig.fake.requests("com.superlogical.terminal.write").isEmpty
                && rig.fake.requests("com.superlogical.terminal.resize").contains { $0.payload.contains(#""columns":50"#) }
        })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { rig.channel.connected })
        await rig.stop()
    }

    @Test func theLastPaneClosingEndsTheTerminalWithAReason() async throws {
        let rig = try await open(["a"])
        rig.fake.dataHosts[0].closePane()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected })
        #expect(rig.channel.reason == "The pane closed in Rex.")
        await rig.stop()
    }

    /// Rex closes a pane whose program exited. Until it does the pane stays
    /// on screen; then the terminal moves to the neighbour, and if there is
    /// none it ends saying how the program exited.
    @Test func aProgramExitingIsFollowedByRexClosingItsPane() async throws {
        let rig = try await open(["a", "b"])
        rig.fake.dataHosts[0].emitChildExit(code: 3)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            rig.channel.connected && rig.model.state.shown == Self.block("a")
        })
        rig.fake.dataHosts[0].closePane()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("screen of b") })
        // Rex's view no longer lists the pane that closed.
        let remaining = RexFakeSession(sessionID: Self.session, panes: [.init(block: Self.block("b"), label: "shell", title: "", screen: "")])
        rig.fake.setView(remaining.viewJSON(revision: 5), revision: 5)
        rig.fake.viewChanged(revision: 5)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 1 })
        rig.fake.dataHosts[1].emitChildExit(code: 2)
        rig.fake.dataHosts[1].closePane()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected })
        #expect(rig.channel.reason == "title b exited with status 2.")
        await rig.stop()
    }

    /// A real close of the shown pane's stream (the bridge dying) still ends
    /// the terminal, with the bridge's reason.
    @Test func theShownPanesStreamDyingEndsTheTerminal() async throws {
        let rig = try await open(["a", "b"])
        rig.fake.dataHosts[0].end(status: 4)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected })
        #expect(rig.channel.reason == "Rex is not running on this host.")
        await rig.stop()
    }

    /// The pane list follows the session: a `session_view_changed` reads the view
    /// again (one read for one change, a revision already applied is not read
    /// again), and a title event renames a pane in place.
    @Test func thePaneListFollowsViewChangesAndTitles() async throws {
        let rig = try await open(["a", "b"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        #expect(rig.model.state.showsSwitcher && rig.model.state.showsMinimap)

        let bigger = RexFakeSession(sessionID: Self.session, panes: ["a", "b", "c"].map {
            .init(block: Self.block($0), label: "shell", title: "t", screen: "")
        })
        let before = rig.fake.requests("session.view").count
        rig.fake.setView(bigger.viewJSON(revision: 7), revision: 7)
        rig.fake.viewChanged(revision: 7)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 3 })
        #expect(rig.model.state.minimap.count == 3)
        #expect(rig.fake.requests("session.view").count == before + 1)
        rig.fake.viewChanged(revision: 7)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { rig.fake.requests("session.view").count == before + 1 })

        rig.fake.titleChanged(Self.block("b"), "vim")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.map(\.name) == ["title a", "vim", "shell"] })
        await rig.stop()
    }

    /// A pane's program is known to the switcher while it reports status: from
    /// the first read, then by events (a record added, removed, the program
    /// exiting), named by its title, else its app, else Rex's label. A plain
    /// shell has none.
    @Test func aPanesProgramFollowsWhatItReports() async throws {
        let rig = try await open(["a", "b", "c"], reporting: ["b": #"[{"state":"working","app":"claude"}]"#])
        func programs() -> [String?] { rig.model.state.panes.map(\.program) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", nil] }, "the title, not the app")
        let c = Self.block("c")

        rig.fake.statusChanged(c, record: #"{"state":"idle"}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", "title c"] })
        rig.fake.titleChanged(c, "")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", "shell"] }, "no title, no app: Rex's label")
        rig.fake.statusChanged(c, record: #"{"state":"idle","app":"pi"}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", "pi"] }, "no title: its app")
        rig.fake.titleChanged(c, "\u{03C0} - x")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", "\u{03C0} - x"] })
        rig.fake.statusRemoved(c, ids: [""])
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, "title b", nil] }, "reporting stopped")
        rig.fake.blockEvent(Self.block("b"), "child_exited", #"{"exit_code":0}"#)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { programs() == [nil, nil, nil] }, "the program exited")
        await rig.stop()
    }

    @Test func aSessionOfOnePaneHasNoSwitcherAndAWindowOfOneHasNoMinimap() async throws {
        let rig = try await open(["a"])
        #expect(!rig.model.state.showsSwitcher && !rig.model.state.showsMinimap)
        #expect(rig.model.step(1) == false && rig.model.step(-1) == false)
        await rig.stop()
    }

    /// A pane the host's view does not list is not shown, so a stale tap cannot
    /// make the terminal ask Rex for it.
    @Test func aPaneTheViewDoesNotListIsNotShown() async throws {
        let rig = try await open(["a", "b"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        rig.model.show("block:ghost")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { rig.model.state.shown == Self.block("a") })
        #expect(rig.fake.requests("data.connect").count == 1)
        await rig.stop()
    }
}
