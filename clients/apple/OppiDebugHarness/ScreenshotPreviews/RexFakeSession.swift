#if DEBUG
import Foundation
import GhosttyVt
import Synchronization

/// A stand-in for one pane's data connection (`/api/data`, `rex.data.terminal.v1`)
/// behind the byte pipe `RexBridge.command` opens: it upgrades the connection,
/// reads HELLO's ticket, answers WELCOME, and sends what the caller makes up
/// (`emitSnapshot`, `emit`, `closePane`), as Rex frames it. The client under
/// test speaks the real wire protocol to something that only decides the bytes.
/// As on Rex, the connection belongs to no pane until HELLO's ticket names one.
final class RexFakeDataHost: Sendable {
    private struct State {
        var sink: SSHPTYByteSink?
        var inbound = Data()
        var upgraded = false
        var ticket: Data?
        var block: String?
        var closed = false
    }

    private let nonce: UInt64
    /// The pane a ticket was issued for, as `data.connect` recorded it.
    private let pane: @Sendable (Data) -> String?
    private let state = Mutex(State())

    init(nonce: UInt64 = 42, pane: @escaping @Sendable (Data) -> String?) {
        self.nonce = nonce
        self.pane = pane
    }

    /// The pane this connection serves: nil until HELLO's ticket names one.
    var block: String? { state.withLock { $0.block } }
    /// The client upgraded the connection to a WebSocket.
    var isUpgraded: Bool { state.withLock { $0.upgraded } }

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

    /// Rex closed the pane: WebSocket close 4000. The bridge is `exec nc -U`,
    /// so `nc` exits when Rex closes the socket and the channel reports its
    /// end right behind the frame: EOF, exit status 0, closed.
    func closePane() {
        deliver(Self.frame(0x08, Data([0x0F, 0xA0])))
        let sink = state.withLock { state -> SSHPTYByteSink? in
            state.closed = true
            return state.sink
        }
        sink?(.eof)
        sink?(.exitStatus(0))
        sink?(.closed)
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
                state.block = pane(Data(payload[1...]))
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
        /// The OSC 7501 records `program_status` answers, as Rex's JSON; none for a plain shell.
        var records = "[]"
        /// The folder `pwd` answers (a path or an OSC 7 `file://` URL); none until the shell reports.
        var pwd: String?
    }

    private struct State {
        var panes: [Pane]
        var view: String
        var revision = 1
        /// Each ticket `data.connect` issued, by its pane.
        var tickets: [Data: String] = [:]
        var issued = 0
        /// Panes `session.new_split` made, for their block ids.
        var created = 0
        var served: [RexFakeDataHost] = []
        var held: Set<String> = []
        var refusing: Set<String> = []
        /// Limits `refusing` to requests that name one of these panes.
        var refusingBlocks: Set<String>?
    }

    let sessionID: String
    private let state: Mutex<State>
    private let host = Mutex<RexFakeHost?>(nil)

    /// `panes` sit in one window, left to right, in the tiled layer.
    init(sessionID: String, panes: [Pane]) {
        self.sessionID = sessionID
        state = Mutex(State(panes: panes, view: ""))
        let view = viewJSON(revision: 1)
        state.withLock { $0.view = view }
    }

    /// The panes in the window, left to right: the ones the session started
    /// with and the ones `session.new_split` added.
    var panes: [Pane] { state.withLock { $0.panes } }

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

    /// These methods answer `not_found`, as Rex does for a pane that closed:
    /// for every pane, or only a request that names one of `blocks`.
    func refuse(_ methods: Set<String>, for blocks: Set<String>? = nil) {
        state.withLock {
            $0.refusing = methods
            $0.refusingBlocks = blocks
        }
    }

    /// Answers the held `data.connect` for `block`.
    func release(dataConnectFor block: String) {
        guard let host = host.withLock({ $0 }),
              let request = host.requests.last(where: { $0.method == "data.connect" && $0.string("block_id") == block }) else { return }
        state.withLock { _ = $0.held.remove(block) }
        host.respond(to: request, issueTicket(for: block))
    }

    /// Answers the held `data.connect` for `block` with `not_found`: the pane closed meanwhile.
    func refuse(dataConnectFor block: String) {
        guard let host = host.withLock({ $0 }),
              let request = host.requests.last(where: { $0.method == "data.connect" && $0.string("block_id") == block }) else { return }
        state.withLock { _ = $0.held.remove(block) }
        host.refuse(request, code: "not_found", message: "no such block")
    }

    /// Every request the terminal made, in order.
    var requests: [RexFakeHost.Request] { host.withLock { $0 }?.requests ?? [] }

    /// The requests of `method`.
    func requests(_ method: String) -> [RexFakeHost.Request] { requests.filter { $0.method == method } }

    /// The data connections the terminal opened, in order, including any it
    /// closed before its ticket came (`RexFakeDataHost.block` is nil for those).
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

    /// A terminal block event of this session, as Rex's JSON payload.
    func blockEvent(_ block: String, _ name: String, _ payload: String) {
        host.withLock { $0 }?.blockEvent(sessionID, block, name, payload)
    }

    /// The program in `block` reports (or updates) one status record, as Rex's JSON.
    func statusChanged(_ block: String, record: String) {
        host.withLock { $0 }?.blockEvent(sessionID, block, "program_status_changed", #"{"record":\#(record)}"#)
    }

    func statusRemoved(_ block: String, ids: [String]) {
        let list = ids.map { #""\#($0)""# }.joined(separator: ",")
        host.withLock { $0 }?.blockEvent(sessionID, block, "program_status_removed", #"{"ids":[\#(list)]}"#)
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

    /// Once HELLO names its pane, the connection shows that pane's screen.
    func serve(_ data: RexFakeDataHost) {
        Task { [weak self, weak data] in
            // Rex starts the stream after WELCOME, which answers HELLO.
            for _ in 0..<400 where data?.isWelcomed != true { try? await Task.sleep(for: .milliseconds(5)) }
            guard let self, let data, let block = data.block,
                  let pane = panes.first(where: { $0.block == block }),
                  let snapshot = try? Self.snapshot(of: pane.screen) else { return }
            data.emitSnapshot(snapshot)
        }
    }

    fileprivate func nextDataHost() -> RexFakeDataHost {
        let host = RexFakeDataHost { [weak self] ticket in self?.state.withLock { $0.tickets[ticket] } ?? nil }
        state.withLock { $0.served.append(host) }
        return host
    }

    /// Rex issues a ticket, 16 bytes written base64url without padding; the
    /// stream that says HELLO with it is this pane's.
    private func issueTicket(for block: String) -> String {
        let ticket = state.withLock { state -> Data in
            state.issued += 1
            let ticket = Data((0..<16).map { UInt8(truncatingIfNeeded: state.issued >> ($0 * 8)) })
            state.tickets[ticket] = block
            return ticket
        }
        let text = ticket.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return #"{"ticket":"\#(text)","expires_in_ms":60000}"#
    }

    /// `session.new_split` with one shell block after the anchor: the pane is
    /// added to the window's row and the view's revision moves, and the view
    /// event follows the answer, as Rex's does. The pane's folder, when the
    /// request names one, is kept as its `pwd`.
    private func newSplit(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        guard let object = try? JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any],
              let anchor = object["anchor_id"] as? String,
              let layout = object["layout"] as? [String: Any], let shell = layout["block"] as? [String: Any],
              shell["flavor"] as? String == "com.superlogical.terminal.shell" else {
            return .refuse(code: "bad_request", message: "unexpected new_split")
        }
        let cwd = (shell["options"] as? [String: Any])?["cwd"] as? String
        let made: (block: String, revision: Int)? = state.withLock { state in
            guard let index = state.panes.firstIndex(where: { $0.block == anchor }) else { return nil }
            state.created += 1
            let block = "block:created-\(state.created)"
            state.panes.insert(
                Pane(block: block, label: "shell", title: "new shell", screen: "screen of new pane\r\n$ ", pwd: cwd),
                at: index + 1
            )
            state.revision += 1
            return (block, state.revision)
        }
        guard let made else { return .refuse(code: "not_found", message: "no such block") }
        let view = viewJSON(revision: made.revision)
        state.withLock { $0.view = view }
        Task { [weak self] in self?.viewChanged(revision: made.revision) }
        return .result(#"{"anchor_id":"\#(anchor)","block_ids":["\#(made.block)"],"split_ids":["split:created"],"revision":\#(made.revision)}"#)
    }

    private func answer(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        let block = request.string("block_id") ?? ""
        let refused = state.withLock { state in
            state.refusing.contains(request.method)
                && (state.refusingBlocks.map { blocks in blocks.contains { request.payload.contains($0) } } ?? true)
        }
        if refused {
            return .refuse(code: "not_found", message: "no such block")
        }
        switch request.method {
        case "session.attach":
            return .result(#"{"client_id":"client:preview","view":\#(state.withLock { $0.view })}"#)
        case "session.view":
            return .result(state.withLock { $0.view })
        case "session.own_block", "session.disown_block":
            return .result(#"{"blocks":[]}"#)
        case "data.connect":
            return state.withLock({ $0.held.contains(block) }) ? .hold : .result(issueTicket(for: block))
        case "com.superlogical.terminal.title":
            return .result(#"{"title":"\#(panes.first { $0.block == block }?.title ?? "")"}"#)
        case "com.superlogical.terminal.program_status":
            return .result(#"{"records":\#(panes.first { $0.block == block }?.records ?? "[]")}"#)
        case "com.superlogical.terminal.pwd":
            guard let pwd = panes.first(where: { $0.block == block })?.pwd else { return .result("{}") }
            return .result(#"{"pwd":"\#(pwd)"}"#)
        case "session.new_split":
            return newSplit(request)
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
    }

    private let control: SSHExecStream
    private let session: RexFakeSession
    private let state = Mutex(State())

    fileprivate init(host: RexFakeHost, control: RexControl, session: RexFakeSession) {
        self.session = session
        self.control = host.open(sink: { control.receive($0) })
    }

    func send(_ bytes: Data) async throws { try await control.send(bytes) }

    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        guard command == RexBridge.command else { throw SSHConnectionError.notConnected }
        let data = session.nextDataHost()
        let stream = data.open(sink: sink)
        state.withLock { $0.streams.append(stream) }
        session.serve(data)
        return stream
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}

    func close() {
        let streams = state.withLock { $0.streams }
        control.close()
        streams.forEach { $0.close() }
    }

    func cancel() async { close() }
}
#endif
