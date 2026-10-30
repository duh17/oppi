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
        #expect(RexSessionConnection.base64URL("AQID_-8") == Data([1, 2, 3, 255, 239]))
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
        let events = Mutex<[String]>([])
        control.onEvent { event in
            let inner = event["payload"] as? [String: Any]
            events.withLock { $0.append(inner?["type"] as? String ?? "?") }
        }

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
        #expect(events.withLock { $0 } == ["session_created"], "events reach the handler, whole, in order")
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
        #expect(stream.receive(serverFrame(.close, Data([0x0F, 0xA0]))) == [.paneClosed])
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
        #expect(parsed.minimap(around: "c").map(\.blockID) == ["b", "c", "d"])
        #expect(parsed.minimap(around: "e").map(\.blockID) == ["e"])
        // A layout this build cannot read still lists its blocks.
        let unreadable = try layout(#"{"revision":1,"session_id":"s","windows":[{"window_id":"w","layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1]},"blocks":[\#(block("x")),\#(block("y"))]}]}]}"#)
        #expect(unreadable.panes.map(\.blockID) == ["x", "y"] && unreadable.minimap(around: "x").isEmpty)
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
        // A sideways drag far enough, or fast enough; never a diagonal one.
        #expect(SSHTerminalPaneSwipe.step(translation: CGPoint(x: -80, y: 10), velocity: .zero) == 1)
        #expect(SSHTerminalPaneSwipe.step(translation: CGPoint(x: 80, y: -10), velocity: .zero) == -1)
        #expect(SSHTerminalPaneSwipe.step(translation: CGPoint(x: -30, y: 0), velocity: CGPoint(x: -900, y: 0)) == 1)
        #expect(SSHTerminalPaneSwipe.step(translation: CGPoint(x: -30, y: 0), velocity: CGPoint(x: -100, y: 0)) == nil)
        #expect(SSHTerminalPaneSwipe.step(translation: CGPoint(x: -80, y: 70), velocity: .zero) == nil)
        #expect(SSHTerminalPaneSwipe.begins(velocity: CGPoint(x: 300, y: 40)) && !SSHTerminalPaneSwipe.begins(velocity: CGPoint(x: 300, y: 250)))
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

    func open(_ names: [String], first: String? = nil) async throws -> Rig {
        let fake = RexFakeSession(sessionID: Self.session, panes: names.map {
            .init(block: Self.block($0), label: "shell", title: "title \($0)", screen: "screen of \($0)\r\n$ ")
        })
        let control = RexControl()
        let transport = fake.transport(control: control)
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
        channel.resize(.init(columns: 40, rows: 10))
        let rig = Rig(fake: fake, channel: channel, connection: connection, model: model, consumer: consumer)
        guard await waitForMainActorCondition(timeout: .seconds(5), { rig.shows("screen of \(opening)") }) else {
            await rig.stop()
            Issue.record("the first pane never showed")
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
        #expect(rig.fake.dataHosts.map(\.block) == [Self.block("a"), c], "b never got a stream")
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
        #expect(rig.fake.dataHosts.map(\.block) == [a], "b never got a stream")
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

    /// The strip follows the session: a `session_view_changed` reads the view
    /// again (one read for one change, a revision already applied is not read
    /// again), and a title event renames a pane in place.
    @Test func theStripFollowsViewChangesAndTitles() async throws {
        let rig = try await open(["a", "b"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.state.panes.count == 2 })
        #expect(rig.model.state.showsStrip && rig.model.state.showsMinimap)

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

    @Test func aSessionOfOnePaneHasNoStripAndAWindowOfOneHasNoMinimap() async throws {
        let rig = try await open(["a"])
        #expect(!rig.model.state.showsStrip && !rig.model.state.showsMinimap)
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
