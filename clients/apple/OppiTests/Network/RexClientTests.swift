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
        #expect(RexPaneConnection.base64URL("AQID_-8") == Data([1, 2, 3, 255, 239]))
    }

    /// The snapshot is everything before the stream's first Rex message. Rex's
    /// messages leave the output, even split across reads; a look-alike with
    /// another nonce, which a program printed, stays output.
    @Test func theTerminalStreamSplitsSnapshotOutputAndRexMessages() throws {
        var stream = RexTerminalStream(nonce: 42)
        let snapshot = Data("GHOSTSNP\u{1}\u{0}binary".utf8)
        let resize = Data("\u{1B}_rex1;42;{\"type\":\"resize\",\"cols\":60,\"rows\":20}\u{1B}\\".utf8)
        let forged = Data("\u{1B}_rex1;7;{\"type\":\"child_exited\",\"exit_code\":9}\u{1B}\\".utf8)
        let exited = Data("\u{1B}_rex1;42;{\"type\":\"child_exited\",\"exit_code\":3}\u{1B}\\".utf8)
        let all = snapshot + resize + Data("$ ls\r\n".utf8) + forged + exited + Data("tail".utf8)
        var pieces: [RexTerminalStream.Piece] = []
        var index = all.startIndex
        while index < all.endIndex {
            let end = min(index + 5, all.endIndex)
            pieces += try stream.receive(all[index..<end])
            index = end
        }
        let output = pieces.reduce(into: Data()) { joined, piece in
            if case .output(let bytes) = piece { joined += bytes }
        }
        #expect(pieces.first == .snapshot(snapshot))
        #expect(pieces.contains(.message(.resize(columns: 60, rows: 20))))
        #expect(pieces.contains(.message(.childExited(code: 3))))
        #expect(output == Data("$ ls\r\n".utf8) + forged + Data("tail".utf8))
    }
}

/// A byte pipe that records what the control client writes.
private final class WrittenFrames: Sendable {
    let frames = Mutex<[Data]>([])
    func append(_ frame: Data) { frames.withLock { $0.append(frame) } }
    var all: [Data] { frames.withLock { $0 } }
}

@Suite("Rex control connection")
struct RexControlTests {
    /// Hello, then requests matched to their answers by id, an error answer
    /// as Rex's reason, and the bridge's exit status 4 as "Rex is not running"
    /// for a call still waiting. Events arrive as the SSH channel reports them:
    /// EOF first, then the exit status, then closed.
    @Test func helloRequestsAndTheBridgeEndingAreRead() async throws {
        let written = WrittenFrames()
        let control = RexControl()
        control.attach { written.append($0) }

        let opening = Task { try await control.open() }
        try await waitUntil { !written.all.isEmpty }
        let request = String(decoding: written.all[0], as: UTF8.self)
        let key = try #require(request.split(separator: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.dropFirst(19))
        control.receive(.data(upgradeAnswer(key: String(key), subprotocol: "rex.control.v1")))
        try await waitUntil { written.all.count == 2 }
        let hello = try JSONSerialization.jsonObject(with: try clientPayload(written.all[1]).payload) as? [String: Any]
        #expect(hello?["type"] as? String == "hello" && hello?["api_revision"] as? Int == RexControl.apiRevision)
        control.receive(.data(serverFrame(.text, Data(#"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576}}"#.utf8))))
        try await opening.value

        let first = Task { try await control.call("server.version", [:]) }
        let second = Task { try await control.call("session.attach", ["session_id": "session:x"]) }
        try await waitUntil { written.all.count == 4 }
        var ids: [String: String] = [:]
        for frame in written.all.suffix(2) {
            let object = try JSONSerialization.jsonObject(with: try clientPayload(frame).payload) as? [String: Any]
            ids[object?["method"] as? String ?? ""] = object?["id"] as? String
        }
        let attachID = try #require(ids["session.attach"]), versionID = try #require(ids["server.version"])
        // Answers in the other order still reach their callers.
        control.receive(.data(serverFrame(.text, Data(#"{"type":"response","id":"\#(attachID)","seq":0,"error":{"code":"session_not_found","message":"no session","status":404}}"#.utf8))))
        control.receive(.data(serverFrame(.text, Data(#"{"type":"event","seq":1,"payload":{"type":"session_created"}}"#.utf8))))
        control.receive(.data(serverFrame(.text, Data(#"{"type":"response","id":"\#(versionID)","seq":1,"payload":{"rex_version":"0.1.0"}}"#.utf8))))
        let version = try JSONSerialization.jsonObject(with: try await first.value) as? [String: Any]
        #expect(version?["rex_version"] as? String == "0.1.0")
        await #expect(throws: RexClientError.refused(code: "session_not_found", message: "no session")) { try await second.value }

        let waiting = Task { try await control.call("server.status", [:]) }
        try await waitUntil { written.all.count == 5 }
        control.receive(.eof)
        control.receive(.exitStatus(4))
        control.receive(.closed)
        await #expect(throws: RexClientError.notRunning) { try await waiting.value }
        await #expect(throws: RexClientError.notRunning) { try await control.call("server.version", [:]) }
    }

    /// A request Rex never answers fails in time instead of holding typing
    /// forever; its answer arriving later is dropped, and the next request
    /// still gets its own answer.
    @Test func anUnansweredRequestTimesOut() async throws {
        let written = WrittenFrames()
        // Long enough that the test's own answer to the second request, on a
        // busy machine, still lands inside it.
        let control = RexControl(requestTimeout: .seconds(1))
        control.attach { written.append($0) }
        let opening = Task { try await control.open() }
        try await waitUntil { written.all.count == 1 }
        let upgrade = String(decoding: written.all[0], as: UTF8.self)
        let key = try #require(upgrade.split(separator: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.dropFirst(19))
        control.receive(.data(upgradeAnswer(key: String(key), subprotocol: "rex.control.v1")))
        try await waitUntil { written.all.count == 2 }
        control.receive(.data(serverFrame(.text, Data(#"{"type":"welcome","protocol":"rex.control.v1"}"#.utf8))))
        try await opening.value

        await #expect(throws: RexClientError.timedOut) { try await control.call("server.version", [:]) }
        control.receive(.data(serverFrame(.text, Data(#"{"type":"response","id":"\#(try requestID(written.all[2]))","seq":0,"payload":{"late":true}}"#.utf8))))

        let next = Task { try await control.call("server.status", [:]) }
        try await waitUntil { written.all.count == 4 }
        control.receive(.data(serverFrame(.text, Data(#"{"type":"response","id":"\#(try requestID(written.all[3]))","seq":0,"payload":{"sessions":1}}"#.utf8))))
        let answer = try JSONSerialization.jsonObject(with: try await next.value) as? [String: Any]
        #expect(answer?["sessions"] as? Int == 1)
    }

    private func requestID(_ frame: Data) throws -> String {
        let request = try JSONSerialization.jsonObject(with: try clientPayload(frame).payload) as? [String: Any]
        return try #require(request?["id"] as? String)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
}

@Suite("Rex pane data connection")
struct RexDataStreamTests {
    /// The whole data handshake and stream: HELLO with the ticket the moment
    /// the upgrade lands, WELCOME's nonce, then the snapshot, output with Rex's
    /// messages removed, the program's exit, and close 4000 as the pane closing.
    /// Nothing comes out after the end.
    @Test func helloWelcomeSnapshotOutputExitAndClose() throws {
        let ticket = Data((1...16).map { UInt8($0) })
        var stream = RexDataStream(ticket: ticket, key: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(String(decoding: stream.upgradeRequest, as: UTF8.self).contains("Sec-WebSocket-Protocol: rex.data.terminal.v1\r\n"))

        let upgraded = stream.receive(upgradeAnswer(key: "dGhlIHNhbXBsZSBub25jZQ==", subprotocol: "rex.data.terminal.v1"))
        guard case .send(let hello)? = upgraded.first, upgraded.count == 1 else {
            Issue.record("expected HELLO alone, got \(upgraded)")
            return
        }
        let helloFrame = try clientPayload(hello)
        #expect(helloFrame.opcode == RexWebSocketCodec.Opcode.binary.rawValue)
        #expect(helloFrame.payload == Data([0x01]) + ticket)

        var welcome = Data([0x81]) + Data(repeating: 0, count: 19) + Data([0x60, 0xEA, 0, 0])
        welcome += Data([42, 0, 0, 0, 0, 0, 0, 0])
        #expect(stream.receive(serverFrame(.binary, welcome)).isEmpty)

        let snapshot = Data("GHOSTSNP-bytes".utf8)
        let message = { (json: String) in Data("\u{1B}_rex1;42;\(json)\u{1B}\\".utf8) }
        let body = snapshot + message(#"{"type":"resize","cols":80,"rows":24}"#) + Data("$ ls\r\n".utf8)
            + message(#"{"type":"child_exited","exit_code":2}"#)
        #expect(stream.receive(serverFrame(.binary, body)) == [.snapshot(snapshot), .output(Data("$ ls\r\n".utf8)), .exited(code: 2)])
        #expect(stream.receive(serverFrame(.close, Data([0x0F, 0xA0]))) == [.ended("The pane closed in Rex.")])
        #expect(stream.receive(serverFrame(.binary, Data("late".utf8))).isEmpty)

        var refused = RexDataStream(ticket: ticket, key: "dGhlIHNhbXBsZSBub25jZQ==")
        _ = refused.receive(upgradeAnswer(key: "dGhlIHNhbXBsZSBub25jZQ==", subprotocol: "rex.data.terminal.v1"))
        #expect(refused.receive(serverFrame(.binary, Data([0x82, 0x01]))) == [
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
        let snapshot = try Self.snapshot(of: "first line\r\n\u{1B}[31mred\u{1B}[0m second\r\n$ ")
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
        queue.pushSnapshot(snapshot + Data("l".utf8))
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

    private static func snapshot(of text: String) throws -> Data {
        var terminal: GhosttyTerminal?
        try #require(ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS)
        defer { ghostty_terminal_free(terminal) }
        let bytes = Data(text.utf8)
        bytes.withUnsafeBytes { ghostty_terminal_vt_write(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try #require(ghostty_snapshot_encode_alloc(terminal, nil, &pointer, &length) == GHOSTTY_SUCCESS)
        defer { ghostty_free(nil, pointer, length) }
        return Data(bytes: try #require(pointer), count: length)
    }
}

private actor RecordingConnection: SSHTerminalConnection {
    private(set) var sent = [Data]()
    func send(_ bytes: Data) async throws { sent.append(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async {}
}
