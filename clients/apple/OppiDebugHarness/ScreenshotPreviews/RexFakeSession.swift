#if DEBUG
import Foundation
import GhosttyVt
import Synchronization

/// A stand-in for one pane's data connection (`/api/data`, `rex.data.terminal.v1`)
/// behind the byte pipe `RexBridge.command` opens: it upgrades the connection,
/// reads HELLO's ticket, answers WELCOME, and sends what the caller makes up
/// (`emitSnapshot`, `emit`, `closePane`), as Rex frames it. The client under
/// test speaks the real wire protocol to something that only decides the bytes.
final class RexFakeDataHost: Sendable {
    private struct State {
        var sink: SSHPTYByteSink?
        var inbound = Data()
        var upgraded = false
        var ticket: Data?
        var closed = false
    }

    /// The pane this connection serves.
    let block: String
    private let nonce: UInt64
    private let state = Mutex(State())

    init(block: String, nonce: UInt64 = 42) {
        self.block = block
        self.nonce = nonce
    }

    /// The client's end of the pipe. Its output reaches `sink`; closing it
    /// reports `.closed` there, as an SSH channel's close does.
    func open(sink: @escaping SSHPTYByteSink) -> SSHExecStream {
        state.withLock { $0.sink = sink }
        return SSHExecStream(
            send: { [self] in receive($0) },
            close: { [self] in
                let sink = state.withLock { state -> SSHPTYByteSink? in
                    guard !state.closed else { return nil }
                    state.closed = true
                    return state.sink
                }
                sink?(.closed)
            }
        )
    }

    /// The ticket the client said HELLO with, once it has.
    var ticket: Data? { state.withLock { $0.ticket } }
    /// The client closed its end of the pipe.
    var isClosed: Bool { state.withLock { $0.closed } }
    /// The data connection is open and welcomed: output can flow.
    var isWelcomed: Bool { state.withLock { $0.ticket != nil } }

    /// The pane's screen as Ghostty's snapshot, then Rex's `resize` message,
    /// which ends it.
    func emitSnapshot(_ snapshot: Data, columns: Int = 80, rows: Int = 24) {
        deliver(Self.frame(0x02, snapshot + message(#"{"type":"resize","cols":\#(columns),"rows":\#(rows)}"#)))
    }

    /// The program's output.
    func emit(_ text: String) {
        deliver(Self.frame(0x02, Data(text.utf8)))
    }

    /// The program exited.
    func emitChildExit(code: Int) {
        deliver(Self.frame(0x02, message(#"{"type":"child_exited","exit_code":\#(code)}"#)))
    }

    /// Rex closed the pane: WebSocket close 4000.
    func closePane() {
        deliver(Self.frame(0x08, Data([0x0F, 0xA0])))
    }

    /// The command ended, as the bridge's exit does.
    func end(status: Int) {
        let sink = state.withLock { state -> SSHPTYByteSink? in
            state.closed = true
            return state.sink
        }
        sink?(.exitStatus(status))
        sink?(.closed)
    }

    private func message(_ json: String) -> Data { Data("\u{1B}_rex1;\(nonce);\(json)\u{1B}\\".utf8) }

    /// Bytes from the client: the upgrade request, then masked frames (HELLO).
    private func receive(_ bytes: Data) {
        var answers: [Data] = []
        state.withLock { state in
            guard !state.closed else { return }
            state.inbound.append(bytes)
            while true {
                if !state.upgraded {
                    guard let end = state.inbound.range(of: Data("\r\n\r\n".utf8)) else { return }
                    let head = String(decoding: state.inbound[..<end.lowerBound], as: UTF8.self)
                    state.inbound.removeSubrange(..<end.upperBound)
                    let key = head.split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                        .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
                    answers.append(Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-Websocket-Accept: \(RexWebSocketCodec.accept(for: key))\r\nSec-Websocket-Protocol: rex.data.terminal.v1\r\nUpgrade: websocket\r\n\r\n".utf8))
                    state.upgraded = true
                    continue
                }
                let bytes = [UInt8](state.inbound)
                guard bytes.count >= 2 else { return }
                var length = Int(bytes[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                }
                guard bytes.count >= offset + 4 + length else { return }
                let mask = Array(bytes[offset..<(offset + 4)])
                let payload = bytes[(offset + 4)..<(offset + 4 + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] }
                state.inbound.removeSubrange(..<(offset + 4 + length))
                // HELLO: 0x01, then the 16-byte ticket. WELCOME: 0x81, a
                // reconnect token, 60 s of keep, and the stream's nonce.
                guard bytes[0] & 0x0F == 0x02, payload.first == 0x01, payload.count == 17 else { continue }
                state.ticket = Data(payload[1...])
                var welcome = Data([0x81]) + Data(repeating: 0, count: 19)
                welcome += Data([0x60, 0xEA, 0, 0])
                welcome += Data((0..<8).map { UInt8((nonce >> ($0 * 8)) & 0xFF) })
                answers.append(Self.frame(0x02, welcome))
            }
        }
        deliver(answers)
    }

    private func deliver(_ frame: Data) { deliver([frame]) }

    private func deliver(_ frames: [Data]) {
        let sink = state.withLock { $0.closed ? nil : $0.sink }
        for frame in frames { sink?(.data(frame)) }
    }

    /// An unmasked server frame with the final bit set.
    private static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
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
}

/// One Rex session on a fake host, for previews and tests of a session
/// terminal: panes tiled in one window in a row (or the view a test gives),
/// answering the control calls the terminal makes, and serving each pane's
/// data connection from a snapshot. It records every request, so a test can
/// say what the terminal asked of Rex (and what it never did).
final class RexFakeSession: Sendable {
    struct Pane: Sendable {
        let block: String
        let label: String
        let title: String
        /// What the pane's screen shows when its data connection opens.
        let screen: String
    }

    private struct State {
        var view: String
        var revision = 1
        var dataHosts: [RexFakeDataHost] = []
        var served: [RexFakeDataHost] = []
        var held: Set<String> = []
    }

    let sessionID: String
    let panes: [Pane]
    private let state = Mutex(State(view: ""))
    private let host = Mutex<RexFakeHost?>(nil)

    /// `panes` sit in one window, left to right, in the tiled layer.
    init(sessionID: String, panes: [Pane]) {
        self.sessionID = sessionID
        self.panes = panes
        let view = viewJSON(revision: 1)
        state.withLock { $0.view = view }
    }

    /// The session's view as Rex answers `session.view`: one window, a tiled
    /// layer, `layout.rect [0,0,1,1]`, and a split per extra pane (horizontal,
    /// the first pane before, the rest after).
    func viewJSON(revision: Int? = nil) -> String {
        let revision = revision ?? state.withLock { $0.revision }
        func block(_ pane: Pane) -> String {
            #"{"block_id":"\#(pane.block)","label":"\#(pane.label)","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell"}"#
        }
        func layout(_ panes: ArraySlice<Pane>, x: Double, width: Double) -> String {
            guard let first = panes.first else { return "null" }
            if panes.count == 1 {
                return #"{"rect":[\#(x),0,\#(width),1],"block_id":"\#(first.block)"}"#
            }
            let ratio = 1 / Double(panes.count)
            let before = #"{"rect":[\#(x),0,\#(width * ratio),1],"block_id":"\#(first.block)"}"#
            let after = layout(panes.dropFirst(), x: x + width * ratio, width: width - width * ratio)
            return #"{"rect":[\#(x),0,\#(width),1],"split":{"split_id":"split:\#(first.block)","direction":"horizontal","ratio":\#(ratio),"before":\#(before),"after":\#(after)}}"#
        }
        let window = "window:\(sessionID)-1"
        return #"{"revision":\#(revision),"session_id":"\#(sessionID)","label":"preview","active_window_id":"\#(window)","windows":[{"window_id":"\#(window)","label":"Window 1","focused_block_id":"\#(panes.first?.block ?? "")","layers":[{"layer_id":"layer:1","kind":"tiled","bounds":[0,0,1,1],"layout":\#(layout(panes[...], x: 0, width: 1)),"blocks":[\#(panes.map(block).joined(separator: ","))]}]}]}"#
    }

    /// Replaces the view `session.view` and `session.attach` answer.
    func setView(_ json: String, revision: Int) {
        state.withLock {
            $0.view = json
            $0.revision = revision
        }
    }

    /// `data.connect` for these panes is not answered until `release`.
    func hold(dataConnectFor blocks: Set<String>) { state.withLock { $0.held = blocks } }

    /// Answers the held `data.connect` for `block`.
    func release(dataConnectFor block: String) {
        guard let host = host.withLock({ $0 }),
              let request = host.requests.last(where: { $0.method == "data.connect" && $0.string("block_id") == block }) else { return }
        state.withLock { _ = $0.held.remove(block) }
        host.respond(to: request, Self.ticketJSON)
    }

    /// Every request the terminal made, in order.
    var requests: [RexFakeHost.Request] { host.withLock { $0 }?.requests ?? [] }

    /// The requests of `method`.
    func requests(_ method: String) -> [RexFakeHost.Request] { requests.filter { $0.method == method } }

    /// The data connections the terminal opened, in order.
    var dataHosts: [RexFakeDataHost] { state.withLock { $0.served } }

    /// A server event for this session, as the control connection delivers it.
    func sessionEvent(_ type: String, _ payload: String) {
        host.withLock { $0 }?.sessionEvent(sessionID, type, payload)
    }

    func viewChanged(revision: Int) {
        host.withLock { $0 }?.viewChanged(sessionID, revision: revision)
    }

    func blockClosed(_ block: String) {
        sessionEvent("block_closed", #"{"block_id":"\#(block)"}"#)
    }

    func titleChanged(_ block: String, _ title: String) {
        host.withLock { $0 }?.blockEvent(sessionID, block, "title_changed", #"{"title":"\#(title)"}"#)
    }

    /// A transport for `RexSessionConnection.open` over this session: its
    /// control channel speaks to the fake host, and each data stream the
    /// terminal opens is the next pane stream `data.connect` queued.
    func transport(control: RexControl) -> RexFakeTransport {
        let fake = RexFakeHost { [weak self] in
            self?.answer($0) ?? .refuse(code: "gone", message: "the fake session is gone")
        }
        host.withLock { $0 = fake }
        return RexFakeTransport(host: fake, control: control, session: self)
    }

    /// A Ghostty snapshot of a terminal that was written `text`.
    static func snapshot(of text: String) throws -> Data {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS else { throw CocoaError(.coderInvalidValue) }
        defer { ghostty_terminal_free(terminal) }
        let bytes = Data(text.utf8)
        bytes.withUnsafeBytes { ghostty_terminal_vt_write(terminal, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_snapshot_encode_alloc(terminal, nil, &pointer, &length) == GHOSTTY_SUCCESS, let pointer else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { ghostty_free(nil, pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    /// The pane whose connection this data host serves shows its screen.
    func serve(_ data: RexFakeDataHost) {
        guard let pane = panes.first(where: { $0.block == data.block }), let snapshot = try? Self.snapshot(of: pane.screen) else { return }
        Task { [weak data] in
            // The terminal sends HELLO once the upgrade lands; Rex starts the stream after WELCOME.
            for _ in 0..<400 where data?.isWelcomed != true { try? await Task.sleep(for: .milliseconds(5)) }
            data?.emitSnapshot(snapshot)
        }
    }

    fileprivate func nextDataHost() -> RexFakeDataHost? {
        state.withLock { state in
            // The latest data.connect is the one being opened; an older one was
            // overtaken before its stream was.
            guard let next = state.dataHosts.popLast() else { return nil }
            state.dataHosts = []
            state.served.append(next)
            return next
        }
    }

    /// 16 bytes, base64url without padding, as Rex writes tickets.
    private static let ticketJSON = #"{"ticket":"AAECAwQFBgcICQoLDA0ODw","expires_in_ms":60000}"#

    /// Rex issues a ticket; the stream that uses it is this pane's.
    private func issueTicket(for block: String) -> String {
        state.withLock { $0.dataHosts.append(RexFakeDataHost(block: block)) }
        return Self.ticketJSON
    }

    private func answer(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        let block = request.string("block_id") ?? ""
        switch request.method {
        case "session.attach":
            return .result(#"{"client_id":"client:preview","view":\#(state.withLock { $0.view })}"#)
        case "session.view":
            return .result(state.withLock { $0.view })
        case "session.own_block", "session.disown_block":
            return .result(#"{"blocks":[]}"#)
        case "data.connect":
            let ticket = issueTicket(for: block)
            return state.withLock({ $0.held.contains(block) }) ? .hold : .result(ticket)
        case "com.superlogical.terminal.title":
            return .result(#"{"title":"\#(panes.first { $0.block == block }?.title ?? "")"}"#)
        case "com.superlogical.terminal.resize", "com.superlogical.terminal.write":
            return .result("{}")
        default:
            return .refuse(code: "bad_request", message: "unexpected \(request.method)")
        }
    }
}

/// The SSH connection under a `RexFakeSession`'s terminal: the control channel
/// is the fake host's, and every other stream the terminal opens is the next
/// pane stream.
final class RexFakeTransport: RexTransport {
    private struct State {
        var streams: [SSHExecStream] = []
        var commands: [String] = []
        var closed = false
    }

    private let control: SSHExecStream
    private let session: RexFakeSession
    private let state = Mutex(State())

    fileprivate init(host: RexFakeHost, control: RexControl, session: RexFakeSession) {
        self.session = session
        self.control = host.open(sink: { control.receive($0) })
    }

    /// The commands the terminal opened streams with, in order.
    var commands: [String] { state.withLock { $0.commands } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func send(_ bytes: Data) async throws { try await control.send(bytes) }

    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        state.withLock { $0.commands.append(command) }
        guard command == RexBridge.command, let data = session.nextDataHost() else { throw SSHConnectionError.notConnected }
        let stream = data.open(sink: sink)
        state.withLock { $0.streams.append(stream) }
        session.serve(data)
        return stream
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}

    func close() {
        let streams = state.withLock { state -> [SSHExecStream] in
            state.closed = true
            return state.streams
        }
        control.close()
        streams.forEach { $0.close() }
    }

    func cancel() async { close() }
}
#endif
