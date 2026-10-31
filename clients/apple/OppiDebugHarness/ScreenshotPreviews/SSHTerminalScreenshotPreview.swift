#if DEBUG
import Synchronization
import UIKit

/// Which OSC 7501 report this preview feeds through the real terminal engine.
enum SSHTerminalScreenshotStatus: String {
    case none, blocked
    /// A Rex session terminal: three panes in one window, over a fake host,
    /// so the pane strip, the minimap, and the swipe draw.
    case rexPanes
}

/// `SCREENSHOT_SCREEN=ssh-terminal`, `-status-blocked`, `-rex-panes`: the real
/// terminal at the root of a router stack, over an in-memory connection. A
/// Herdr-like screen in the grid, and `herdr api snapshot` answered with one
/// blocked agent so the toolbar overview and its badge render, beside two saved
/// machines: `mac-mini` with a working agent and `build box`, which cannot be
/// reached. The host runs Rex too, with a pane waiting on a permission, so the
/// Rex Sessions button and its sheet render beside Herdr's. `status: .blocked`
/// also feeds real OSC 7501 bytes through libghostty.
final class SSHTerminalPreviewController: PreviewRootController {
    private let status: SSHTerminalScreenshotStatus
    private let channel: SSHTerminalChannel?
    /// The fixture bytes the terminal plays, and the Rex session's event
    /// stream: tasks this controller owns, so a re-used launch leaves nothing
    /// running behind the preview it dropped.
    private var playback: Task<Void, Never>?
    private var consumption: Task<Void, Never>?

    init(status: SSHTerminalScreenshotStatus = .none, hostLabel: String = "chen@mac-studio") {
        self.status = status
        // `SCREENSHOT_COLOR_SCHEME` picks the side; a fresh `ThemeStore` reads it
        // and puts it in `ThemeRuntimeState`, which the terminal's chrome reads.
        if ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            ScreenshotVolatileDefaults.applyTheme(.light)
        } else {
            ScreenshotVolatileDefaults.applyDarkTheme(true)
        }
        let themeStore = ThemeStore()
        // A server-scoped connection, as the app root injects, so the input bar
        // claims the shared dictation manager and shows its mic. The terminal
        // holds it.
        let connection = ServerConnection()
        connection.setPreviewServerId("preview-server")
        let channel = try? SSHTerminalChannel()
        self.channel = channel
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) {
                // A channel that will not open leaves an empty window.
                guard let channel else { return UIViewController() }
                return SSHTerminalViewController(
                    channel: channel,
                    reconnect: {},
                    editHost: {},
                    hostLabel: hostLabel,
                    composerConnection: connection
                )
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        playback?.cancel()
        consumption?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let channel else { return }
        let status = self.status
        // The fixture's bytes, once the terminal above is its view controller.
        playback = Task { @MainActor [weak self] in
            if status == .rexPanes {
                await self?.playRexSession(on: channel)
            } else {
                self?.play(on: channel)
            }
        }
    }

    private func play(on channel: SSHTerminalChannel) {
        guard !channel.connected else { return }
        // Echo what the composer and key strip send, escaped, so a driven run
        // (OPPI_UI_VALIDATE_TAPS) shows the bytes that reached the "PTY".
        // Both previews start in direct typing: a report never brings up the
        // chat bar, so the blocked variant shows the card and status symbol
        // over the terminal's own bar. The status variants run a login shell,
        // so only the root record picks the key strip.
        channel.opened(PreviewConnection { [weak channel] bytes in
            let shown = String(decoding: bytes, as: UTF8.self).unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x1b: "\\e"
                case 0x0d: "\\r"
                case 0x0a: "\\n"
                case 0..<0x20: "^" + String(UnicodeScalar(UInt8(scalar.value + 0x40)))
                default: String(scalar)
                }
            }.joined()
            channel?.event(.data(Data("\r\nsent: \(shown)".utf8)))
        }, command: status == .none ? "herdr" : nil)
        let esc = "\u{1b}["
        let screen = switch status {
        case .none: herdrScreen(esc)
        case .blocked, .rexPanes: statusScreen(esc)
        }
        var bytes = Data(screen.utf8)
        bytes.append(statusReports(status))
        channel.event(.data(bytes))
    }

    /// The terminal's connection is a `RexSessionConnection` to a fake Rex
    /// session of three panes (`RexFakeSession`), opened on the first. Its
    /// real control and data protocols run against the fake host, so a tap on
    /// the strip or a minimap cell switches panes for real.
    private func playRexSession(on channel: SSHTerminalChannel) async {
        guard !channel.connected else { return }
        let esc = "\u{1b}["
        let panes = [
            RexFakeSession.Pane(block: "block:preview-pi", label: "shell", title: "pi - oppi", screen: (1...80).map { "\(esc)2mbuild log line \($0)\(esc)0m\r\n" }.joined() + "\(esc)1mpi\(esc)0m in ~/oppi\r\n\(esc)32m>\(esc)0m refactor the connection\r\n\r\nThe terminal stands for the session.\r\nSwipe sideways to move between its panes.\r\n"),
            RexFakeSession.Pane(block: "block:preview-logs", label: "shell", title: "tail -f server.log", screen: "\(esc)2m12:01:09\(esc)0m listening on :7749\r\n\(esc)2m12:01:11\(esc)0m GET /health 200\r\n"),
            RexFakeSession.Pane(block: "block:preview-shell", label: "shell", title: "~/dotfiles", screen: "$ git status\r\nOn branch main\r\nnothing to commit\r\n$ "),
        ]
        let fake = RexFakeSession(sessionID: "session:preview", panes: panes)
        let control = RexControl()
        let transport = fake.transport(control: control)
        let queue = SSHTerminalEventQueue()
        guard let connection = try? await RexSessionConnection.open(
            transport: transport, control: control,
            target: RexPaneTarget(sessionID: fake.sessionID, blockID: panes[0].block, label: "pi"), queue: queue
        ) else { return }
        channel.rex = RexSessionModel(connection: connection)
        channel.opened(connection)
        consumption = Task { await channel.consume(queue) }
    }

    private func herdrScreen(_ esc: String) -> String {
        [
            "\(esc)2J\(esc)H",
            "\(esc)38;5;3m\u{25d0} \(esc)1mdotfiles\(esc)0m                     \(esc)2mtab 1\(esc)0m\r\n",
            "\(esc)38;5;3m\u{25d0} 1 needs you\(esc)0m\r\n",
            "\(esc)38;5;4m\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\(esc)0m\r\n\r\n",
            "\(esc)48;5;236m can you tidy the ssh terminal header \(esc)0m\r\n\r\n",
            "\(esc)3;38;5;67mThe header has a status row and a warning\r\nthat duplicate the toolbar. Let me check.\(esc)0m\r\n\r\n",
            "\(esc)42;30m[bash]\(esc)0m rg -n networkChanged Oppi/\r\n\r\n",
            "Allow running \(esc)1mrg\(esc)0m?  \(esc)7m Yes \(esc)0m  No  Always\r\n\r\n",
            "\(esc)38;5;5m\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\(esc)0m\r\n",
            "\(esc)2m$0.146 \u{2502} 1.9%/1.0M \u{2502} mac-studio\(esc)0m",
        ].joined()
    }

    private func statusScreen(_ esc: String) -> String {
        "\(esc)2J\(esc)H Allow running rg?  Yes  No  Always\r\n"
    }

    private func statusReports(_ status: SSHTerminalScreenshotStatus) -> Data {
        switch status {
        case .none, .rexPanes:
            return Data()
        case .blocked:
            return osc("state=blocked:kind=permission:app=pi:msg=\(b64("Allow running rg in the repo?"))")
        }
    }

    private func osc(_ body: String) -> Data { Data("\u{1b}]7501;\(body)\u{1b}\\".utf8) }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}

private actor PreviewConnection: SSHTerminalConnection {
    let echo: @MainActor (Data) -> Void
    init(echo: @escaping @MainActor (Data) -> Void) {
        self.echo = echo
    }

    func send(_ bytes: Data) async throws { await echo(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async {}

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        guard command == RexBridge.command else { throw SSHConnectionError.notConnected }
        return RexFakeHost.preview().open(sink: sink)
    }
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        if command == "sh -s" { // a keybinding file read: none here, so defaults
            return SSHExecResult(output: Data(), errorOutput: Data("No such file".utf8), exitStatus: 1)
        }
        if command == HerdrRemote.machinesCommand {
            let machines = #"[{"id":"aa11","label":"mac-mini","enabled":true},{"id":"bb22","label":"build box","enabled":true}]"#
            return SSHExecResult(output: Data(machines.utf8), errorOutput: Data(), exitStatus: 0)
        }
        if command == HerdrRemote.snapshotCommand(machine: "aa11") {
            let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"tools","focused":true}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"working","focused":true,"terminal_title_stripped":"Adding skill frontmatter"}]}}}"#
            return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
        }
        if command == HerdrRemote.snapshotCommand(machine: "bb22") {
            return SSHExecResult(output: Data(), errorOutput: Data("ssh: connect to host build port 22: Operation timed out".utf8), exitStatus: 255)
        }
        let json = #"{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"dotfiles","focused":true},{"workspace_id":"w2","label":"oppi","focused":false}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"},{"tab_id":"w2:t1","workspace_id":"w2","label":"1"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"pi","agent_status":"blocked","focused":true,"terminal_title_stripped":"Allow running rg?"},{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","agent_status":"working","focused":false,"terminal_title_stripped":"Fixing the build"},{"pane_id":"w2:p2","workspace_id":"w2","tab_id":"w2:t1","agent":"grok","agent_status":"done","focused":false,"terminal_title_stripped":"Summarized the diff"},{"pane_id":"w2:p3","workspace_id":"w2","tab_id":"w2:t1","agent":"codex","agent_status":"idle","focused":false,"terminal_title_stripped":"Ready"}]}}}"#
        return SSHExecResult(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0)
    }
}
/// A stand-in for the host's Rex server, behind the byte pipe `RexBridge.command`
/// opens: it upgrades the connection, welcomes the hello, answers each request
/// from `responder`, and sends events the caller makes up (`emit…`), all as
/// Rex frames them. Previews and the Rex overview's tests use it, so the
/// client under test speaks the real wire protocol to something that only
/// decides the answers.
final class RexFakeHost: Sendable {
    enum Answer: Sendable {
        /// The result's JSON.
        case result(String)
        case refuse(code: String, message: String)
        /// No answer until `respond` or `refuse` gives one.
        case hold
    }

    struct Request: Sendable, Equatable {
        let id: String
        let method: String
        /// The request's payload as JSON, keys sorted.
        let payload: String

        /// A string field of the payload, such as `block_id`.
        func string(_ key: String) -> String? {
            let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            return object?[key] as? String
        }
    }

    private struct State {
        var sink: SSHPTYByteSink?
        var inbound = Data()
        var upgraded = false
        var requests: [Request] = []
        var seq = 0
        var closed = false
    }

    private let state = Mutex(State())
    private let responder: @Sendable (Request) -> Answer
    private let reportsClose: Bool

    /// `reportsClose` false models a host whose close comes back late, as
    /// SSH's does (the channel is only closed once the peer answers): closing
    /// the stream reports nothing until `end(status:)`.
    init(reportsClose: Bool = true, _ responder: @escaping @Sendable (Request) -> Answer) {
        self.reportsClose = reportsClose
        self.responder = responder
    }

    /// Every request received, in order.
    var requests: [Request] { state.withLock { $0.requests } }
    /// The client closed its end of the pipe.
    var isClosed: Bool { state.withLock { $0.closed } }
    /// A stream has been opened on this host.
    var isOpen: Bool { state.withLock { $0.sink != nil } }

    /// The client's end of the pipe. Its output reaches `sink`, as the SSH
    /// channel's does; closing it reports `.closed` there.
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
                if reportsClose { sink?(.closed) }
            }
        )
    }

    func respond(to request: Request, _ json: String) {
        deliver([Self.text(#"{"type":"response","id":\#(Self.quoted(request.id)),"seq":0,"payload":\#(json)}"#)])
    }

    func refuse(_ request: Request, code: String, message: String) {
        deliver([Self.text(Self.refusal(request.id, code, message))])
    }

    /// A server event: `type` with `payload` (JSON), framed with the next `seq`.
    func emit(_ type: String, _ payload: String) {
        let seq = state.withLock { state -> Int in
            state.seq += 1
            return state.seq
        }
        deliver([Self.text(#"{"type":"event","seq":\#(seq),"payload":{"type":\#(Self.quoted(type)),"payload":\#(payload)}}"#)])
    }

    func sessionEvent(_ session: String, _ type: String, _ payload: String) {
        emit("session_event", #"{"session_id":\#(Self.quoted(session)),"event":{"type":\#(Self.quoted(type)),"payload":\#(payload)}}"#)
    }

    func blockEvent(_ session: String, _ block: String, _ name: String, _ payload: String) {
        sessionEvent(session, "block_event", #"{"block_id":\#(Self.quoted(block)),"creator_name":"com.superlogical.terminal","name":\#(Self.quoted(name)),"payload":\#(payload)}"#)
    }

    func viewChanged(_ session: String, revision: Int) {
        sessionEvent(session, "session_view_changed", #"{"revision":\#(revision)}"#)
    }

    /// The bridge command ended: its exit status, then the channel closing.
    func end(status: Int) {
        let sink = state.withLock { state -> SSHPTYByteSink? in
            state.closed = true
            return state.sink
        }
        sink?(.exitStatus(status))
        sink?(.closed)
    }

    /// Bytes from the client: the upgrade request, then masked frames.
    private func receive(_ bytes: Data) {
        var answers: [Data] = []
        var held: [Request] = []
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
                    answers.append(Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-Websocket-Accept: \(RexWebSocketCodec.accept(for: key))\r\nSec-Websocket-Protocol: rex.control.v1\r\nUpgrade: websocket\r\n\r\n".utf8))
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
                } else if length == 127 {
                    guard bytes.count >= 10 else { return }
                    length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
                    offset = 10
                }
                guard bytes.count >= offset + 4 + length else { return }
                let mask = bytes[offset..<(offset + 4)].map { $0 }
                let payload = bytes[(offset + 4)..<(offset + 4 + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] }
                state.inbound.removeSubrange(..<(offset + 4 + length))
                guard bytes[0] & 0x0F == RexWebSocketCodec.Opcode.text.rawValue,
                      let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { continue }
                switch object["type"] as? String {
                case "hello":
                    answers.append(Self.text(#"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},"api_revision":7,"api_server_revision":7}"#))
                case "request":
                    guard let id = object["id"] as? String, let method = object["method"] as? String else { continue }
                    let body = (object["payload"] as? [String: Any]).flatMap {
                        try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
                    }
                    let request = Request(id: id, method: method, payload: body.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
                    state.requests.append(request)
                    held.append(request)
                default:
                    break
                }
            }
        }
        // The responder runs outside the lock, and in order.
        for request in held {
            switch responder(request) {
            case .result(let json):
                answers.append(Self.text(#"{"type":"response","id":\#(Self.quoted(request.id)),"seq":0,"payload":\#(json)}"#))
            case .refuse(let code, let message):
                answers.append(Self.text(Self.refusal(request.id, code, message)))
            case .hold:
                break
            }
        }
        deliver(answers)
    }

    private func deliver(_ frames: [Data]) {
        let sink = state.withLock { $0.closed ? nil : $0.sink }
        for frame in frames { sink?(.data(frame)) }
    }

    private static func refusal(_ id: String, _ code: String, _ message: String) -> String {
        #"{"type":"response","id":\#(quoted(id)),"seq":0,"error":{"code":\#(quoted(code)),"message":\#(quoted(message))}}"#
    }

    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// An unmasked server text frame.
    private static func text(_ json: String) -> Data {
        let payload = Data(json.utf8)
        var frame = Data([0x80 | RexWebSocketCodec.Opcode.text.rawValue])
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

    /// Two sessions: Claude waiting on a permission and a working pi in one,
    /// beside a shell in a second window that never reported; a codex pane
    /// at idle in the other.
    static func preview() -> RexFakeHost {
        let oppi = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
        let dotfiles = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"
        func block(_ id: String) -> String {
            #"{"block_id":"\#(id)","label":"shell","creator_name":"com.superlogical.terminal"}"#
        }
        func window(_ id: String, _ label: String, focused: String, _ blocks: [String]) -> String {
            #"{"window_id":"\#(id)","label":"\#(label)","focused_block_id":"\#(focused)","layers":[{"blocks":[\#(blocks.map(block).joined(separator: ","))]}]}"#
        }
        let claude = "block:01a18a26-6620-78ba-80d4-4e8caa018b37"
        let pi = "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"
        let logs = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cb"
        let codex = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cc"
        let views: [String: String] = [
            oppi: #"{"revision":4,"session_id":"\#(oppi)","label":"oppi","active_window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c82f","windows":[\#(window("window:01a18a26-6645-713c-97f1-2f1058c8c82f", "agents", focused: claude, [claude, pi])),\#(window("window:01a18a26-6645-713c-97f1-2f1058c8c830", "logs", focused: logs, [logs]))]}"#,
            dotfiles: #"{"revision":2,"session_id":"\#(dotfiles)","label":"dotfiles","active_window_id":"window:01a18a26-6645-713c-97f1-2f1058c8c831","windows":[\#(window("window:01a18a26-6645-713c-97f1-2f1058c8c831", "main", focused: codex, [codex]))]}"#,
        ]
        let titles = [claude: "Fixing the build", pi: "Adding skill frontmatter", logs: "tail -f server.log", codex: "Ready"]
        let records = [
            claude: #"[{"effective_app":"claude","state":"working"},{"id":"bash","effective_app":"claude","state":"blocked","kind":"permission","msg":"Run rm -rf build?"}]"#,
            pi: #"[{"effective_app":"pi","state":"working"}]"#,
            codex: #"[{"effective_app":"codex","state":"idle"}]"#,
        ]
        return RexFakeHost { request in
            switch request.method {
            case "session.attach_all":
                return .result(#"{"sessions":[{"session_id":"\#(oppi)","label":"oppi"},{"session_id":"\#(dotfiles)","label":"dotfiles"}]}"#)
            case "session.view":
                guard let view = request.string("session_id").flatMap({ views[$0] }) else {
                    return .refuse(code: "session_not_found", message: "no such session")
                }
                return .result(view)
            case "com.superlogical.terminal.title":
                return .result(#"{"title":"\#(request.string("block_id").flatMap { titles[$0] } ?? "")"}"#)
            case "com.superlogical.terminal.program_status":
                return .result(#"{"records":\#(request.string("block_id").flatMap { records[$0] } ?? "[]")}"#)
            default:
                return .result("{}")
            }
        }
    }
}
#endif
