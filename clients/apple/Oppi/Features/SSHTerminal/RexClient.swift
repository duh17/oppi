import Foundation
import Synchronization

/// The Rex pane a terminal shows: a block in a session on the host's Rex
/// server, and what to call it. A terminal stands for the whole session; this
/// is the pane it opens on, and the one it reopens on after a reconnect.
struct RexPaneTarget: Hashable, Sendable {
    let sessionID: String
    let blockID: String
    /// The pane's name in the list (`claude`, a terminal title), for the
    /// terminal's label and the switcher.
    let label: String
}

/// How Oppi reaches the host's Rex server: a command on the SSH connection
/// whose stdin and stdout are Rex's local socket. Rex trusts a caller on that
/// socket as the account it runs as, which is the SSH user, so it needs no
/// sign-in or network access of its own (its Tailscale serving can stay off).
enum RexBridge {
    /// Rex's socket: in the app's Application Support folder on macOS, in
    /// `$XDG_RUNTIME_DIR/rex` or `~/.local/state/rex/run` elsewhere.
    ///
    /// With no socket the command says why, in its exit status, from the same
    /// one exec (nothing extra is asked while Rex runs): 5 when `rex` is not on
    /// the host either (the CLI inside the macOS app bundle, else on the
    /// `PATH`), 4 when it is installed but no Rex server is listening. With a
    /// socket it exits 126 when `nc` is missing or cannot speak Unix sockets:
    /// Debian's `netcat-traditional` and BusyBox reject `-U` with exit 1, which
    /// would read as a closed connection, so `nc -h` must list `-U` first.
    static let command = SSHTerminalRemoteShell.word(
        "for s in \"$HOME/Library/Application Support/rex/server.sock\" "
            + "\"${XDG_RUNTIME_DIR:-/nonexistent}/rex/server.sock\" \"$HOME/.local/state/rex/run/server.sock\"; do "
            + "[ -S \"$s\" ] && { nc -h 2>&1 | grep -q -e -U || exit 126; exec nc -U \"$s\"; }; done; "
            + "[ -x \"$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex\" ] "
            + "|| command -v rex >/dev/null || exit 5; exit 4"
    )

    static func failure(exitStatus: Int?) -> RexClientError {
        switch exitStatus {
        case 4: .notRunning
        case 5: .notInstalled
        case 126: .bridgeMissing
        default: .connectionClosed
        }
    }
}

enum RexClientError: Error, Equatable, LocalizedError {
    case notRunning
    case notInstalled
    case bridgeMissing
    case connectionClosed
    case timedOut
    /// The server answered a request with an error.
    case refused(code: String, message: String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Rex is not running on this host."
        case .notInstalled: "Rex is not installed on this host."
        case .bridgeMissing: "The host has no nc that can reach Rex's socket (nc -U)."
        case .connectionClosed: "The connection to Rex closed."
        case .timedOut: "Rex did not answer in time."
        case .refused(_, let message): "Rex refused: \(message)"
        case .unreadable(let detail): "Rex sent something Oppi cannot read: \(detail)"
        }
    }
}

/// Rex's control connection (`/api/control`, `rex.control.v1`) over a byte
/// pipe: one hello, then JSON requests matched to their responses by id.
/// Events go to `onEvent` when one is set, and are skipped otherwise. Pings
/// are answered.
///
/// Thread-safe: `receive` runs on the SSH event loop, requests on any task.
final class RexControl: Sendable {
    typealias Write = @Sendable (Data) async throws -> Void

    /// The API revision this client was written against, from the server's
    /// own API page.
    static let apiRevision = 7
    /// No Rex request this client makes takes long; one with no answer by
    /// then is abandoned, and a late answer is dropped.
    static let requestTimeout: Duration = .seconds(15)

    private struct State {
        var codec = RexWebSocketCodec(subprotocol: "rex.control.v1")
        var write: Write?
        var nextID = 0
        /// A result that arrived before its caller waited for it.
        var early: [String: Result<Data, any Error>] = [:]
        var waiting: [String: CheckedContinuation<Data, any Error>] = [:]
        /// Requests given up on, and why; an answer that comes later is dropped.
        var abandoned: [String: any Error] = [:]
        var exitStatus: Int?
        var ended: (any Error)?
        var onEnd: (@Sendable (any Error) -> Void)?
        var onEvent: (@Sendable ([String: Any]) -> Void)?
    }

    private static let upgradeID = "upgrade"
    private static let welcomeID = "welcome"
    private let state = Mutex(State())
    private let timeout: Duration

    init(requestTimeout: Duration = RexControl.requestTimeout) {
        timeout = requestTimeout
    }

    /// Where requests go: the SSH channel this control connection runs on.
    func attach(write: @escaping Write) { state.withLock { $0.write = write } }

    /// Called once when the connection ends, with why.
    func onEnd(_ handler: @escaping @Sendable (any Error) -> Void) {
        let ended = state.withLock { state -> (any Error)? in
            state.onEnd = handler
            return state.ended
        }
        if let ended { handler(ended) }
    }

    /// Called for every server event, as Rex framed it (`{"type":"event","seq":…,"payload":{…}}`),
    /// on the SSH event loop and in the order Rex sent them. A single pane
    /// does not set one: the connection only receives events once it has
    /// attached to a session or to the whole server.
    func onEvent(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        state.withLock { $0.onEvent = handler }
    }

    /// Upgrades the pipe and says hello. Returns once Rex welcomed this client.
    func open() async throws {
        let request = state.withLock { $0.codec.upgradeRequest(path: "/api/control") }
        _ = try await exchange(id: Self.upgradeID, frame: request)
        let hello = try Self.json([
            "type": "hello",
            "api_revision": Self.apiRevision,
            "client": ["kind": "app", "platform": "ios", "name": "Oppi"],
        ])
        _ = try await exchange(id: Self.welcomeID, frame: RexWebSocketCodec.frame(.text, payload: hello))
    }

    /// Calls a method and returns its result's JSON.
    func call(_ method: String, _ payload: [String: Any]) async throws -> Data {
        let id = state.withLock { state -> String in
            state.nextID += 1
            return String(state.nextID)
        }
        let request = try Self.json(["type": "request", "id": id, "method": method, "payload": payload])
        return try await exchange(id: id, frame: RexWebSocketCodec.frame(.text, payload: request))
    }

    /// Feeds what the SSH channel delivered. The channel reports EOF before
    /// the command's exit status, so only `.closed`, which follows both, ends
    /// the connection with the reason the status gives.
    func receive(_ event: SSHPTYEvent) {
        switch event {
        case .data(let bytes):
            let parsed = state.withLock { state -> Result<([RexWebSocketCodec.Message], [Data], Bool), any Error> in
                let wasUpgraded = state.codec.upgraded
                do {
                    let (messages, replies) = try state.codec.receive(bytes)
                    return .success((messages, replies, !wasUpgraded && state.codec.upgraded))
                } catch {
                    return .failure(error)
                }
            }
            switch parsed {
            case .failure(let error):
                end(error)
            case .success(let (messages, replies, upgraded)):
                if upgraded { resolve(Self.upgradeID, .success(Data())) }
                for reply in replies { send(reply) }
                for message in messages { handle(message) }
            }
        case .exitStatus(let status):
            state.withLock { $0.exitStatus = status }
        case .closed:
            end(RexBridge.failure(exitStatus: state.withLock { $0.exitStatus }))
        case .eof, .exitSignal, .writabilityChanged:
            break
        }
    }

    private func handle(_ message: RexWebSocketCodec.Message) {
        switch message {
        case .text(let text):
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { return }
            switch type {
            case "welcome":
                resolve(Self.welcomeID, .success(Data()))
            case "response":
                guard let id = object["id"] as? String else { return }
                if let error = object["error"] as? [String: Any] {
                    resolve(id, .failure(RexClientError.refused(
                        code: error["code"] as? String ?? "",
                        message: error["message"] as? String ?? "an unexplained error"
                    )))
                } else {
                    let payload = object["payload"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                    resolve(id, .success(payload ?? Data("{}".utf8)))
                }
            case "event":
                state.withLock { $0.onEvent }?(object)
            default:
                break
            }
        case .close:
            end(RexClientError.connectionClosed)
        case .binary:
            break
        }
    }

    /// Writes `frame`, then waits for the result filed under `id`, at most
    /// `timeout`.
    private func exchange(id: String, frame: Data) async throws -> Data {
        let write = try state.withLock { state -> Write in
            if let ended = state.ended { throw ended }
            guard let write = state.write else { throw RexClientError.connectionClosed }
            return write
        }
        try await write(frame)
        let timer = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.abandon(id, RexClientError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Data, any Error>? in
                if let result = state.early.removeValue(forKey: id) { return result }
                // Kept until the late answer arrives, so `resolve` drops it.
                if let reason = state.abandoned[id] { return .failure(reason) }
                if let ended = state.ended { return .failure(ended) }
                state.waiting[id] = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func resolve(_ id: String, _ result: Result<Data, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            if let waiter = state.waiting.removeValue(forKey: id) { return waiter }
            // Given up on: the caller already has its answer.
            if state.abandoned.removeValue(forKey: id) == nil { state.early[id] = result }
            return nil
        }
        waiter?.resume(with: result)
    }

    /// Gives up on one request, whether or not its caller is waiting yet. Its
    /// answer, should it come, is dropped (`resolve`).
    private func abandon(_ id: String, _ reason: any Error) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            guard state.early[id] == nil else { return nil }
            state.abandoned[id] = reason
            return state.waiting.removeValue(forKey: id)
        }
        waiter?.resume(throwing: reason)
    }

    private func end(_ error: any Error) {
        let (waiters, handler) = state.withLock { state -> ([CheckedContinuation<Data, any Error>], (@Sendable (any Error) -> Void)?) in
            guard state.ended == nil else { return ([], nil) }
            state.ended = error
            defer { state.waiting.removeAll() }
            return (Array(state.waiting.values), state.onEnd)
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        handler?(error)
    }

    private func send(_ frame: Data) {
        guard let write = state.withLock({ $0.ended == nil ? $0.write : nil }) else { return }
        Task { try? await write(frame) }
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

/// A pane's data connection (`/api/data`, `rex.data.terminal.v1`) as a state
/// machine: bytes from the pipe in, frames to send and what the terminal gets
/// out. It sends HELLO with the ticket as soon as the upgrade lands, reads
/// WELCOME for the stream's nonce, then splits the stream (`RexTerminalStream`).
struct RexDataStream {
    enum Output: Equatable, Sendable {
        case send(Data)
        case snapshot(Data)
        case output(Data)
        case exited(code: Int)
        /// Rex closed the pane (close code 4000). Nothing follows it.
        case paneClosed
        /// The stream is over, and why. Nothing follows it.
        case ended(String)
    }

    private var codec: RexWebSocketCodec
    private let ticket: Data
    private var terminal: RexTerminalStream?
    private var over = false

    init(ticket: Data, key: String = RexWebSocketCodec.makeKey()) {
        codec = RexWebSocketCodec(subprotocol: RexSessionConnection.dataSubprotocol, key: key)
        self.ticket = ticket
    }

    var upgradeRequest: Data { codec.upgradeRequest(path: "/api/data") }

    mutating func receive(_ bytes: Data) -> [Output] {
        guard !over else { return [] }
        var outputs: [Output] = []
        do {
            let wasUpgraded = codec.upgraded
            let (messages, replies) = try codec.receive(bytes)
            if !wasUpgraded, codec.upgraded {
                outputs.append(.send(RexWebSocketCodec.frame(.binary, payload: RexDataHandshake.hello(ticket: ticket))))
            }
            outputs += replies.map(Output.send)
            for message in messages {
                outputs += try deliver(message)
                if over { break }
            }
        } catch {
            outputs.append(.ended(error.localizedDescription))
            over = true
        }
        return outputs
    }

    private mutating func deliver(_ message: RexWebSocketCodec.Message) throws -> [Output] {
        switch message {
        case .binary(let payload):
            guard var stream = terminal else {
                switch try RexDataHandshake.answer(payload) {
                case .welcome(let welcome):
                    terminal = RexTerminalStream(nonce: welcome.nonce)
                    return []
                case .reject(let code):
                    throw RexDataHandshake.Failure.rejected(code)
                }
            }
            let pieces = try stream.receive(payload)
            terminal = stream
            return pieces.compactMap { piece in
                switch piece {
                case .snapshot(let snapshot): .snapshot(snapshot)
                case .output(let output): .output(output)
                case .message(.childExited(let code)): .exited(code: code)
                case .message: nil // Resize and theme: this client owns the size and its colors.
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

/// What a Rex terminal needs of its SSH connection: writes to the control
/// channel (its main channel), more exec streams beside it, side commands, and
/// the connection's own lifecycle. `SSHPTYSession` is one; tests and previews
/// stand in for the host with another.
protocol RexTransport: Sendable {
    func send(_ bytes: Data) async throws
    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream
    func run(_ command: String, input: Data) async throws -> SSHExecResult
    func checkAlive() async throws
    func close()
    func cancel() async
}

extension SSHPTYSession: RexTransport {}

/// One Rex session shown as a terminal, over the SSH connection to its host:
/// one control connection, attached to the session, and one data connection
/// for the pane on screen.
///
/// The connection's main channel is the control connection. The shown pane's
/// output comes on a second channel, the data connection, which first opens on
/// the first resize so the snapshot Rex starts it with is already at this
/// screen's size. This client owns the pane while it shows it
/// (`session.own_block`, take), so the pane follows the phone's size; a pane
/// left behind is handed back (`session.disown_block`), and when the
/// connection drops Rex hands the rest back to the client in line, such as the
/// Mac app. It never focuses anything: the host's own focus stays where it is.
///
/// Showing another pane (`show`) takes it, sizes it, closes the data
/// connection of the one before and opens one for the new pane, whose snapshot
/// replaces the grid (`SSHTerminalEventQueue.pushSnapshot`). Switches run one
/// at a time, so a fast double swipe ends on the last pane asked for, and the
/// stream of a pane left behind is dropped by generation: it is never fed to
/// the grid and never ends the terminal. The strip and minimap follow
/// `session.view`, read again at each `session_view_changed` (at most one read
/// at a time, again if another came meanwhile, an older answer dropped).
///
/// Typing goes to the pane as `com.superlogical.terminal.write`, one call at a
/// time (the channel waits for each), so keys keep their order. Side commands
/// (uploads, the Ghostty theme, keybindings) run on the same SSH connection as
/// for a shell, since the pane is on the same host.
final class RexSessionConnection: SSHTerminalConnection, Sendable {
    static let dataSubprotocol = "rex.data.terminal.v1"
    /// A screen that never sizes the terminal still gets its pane.
    static let firstResizeWait: Duration = .milliseconds(1500)

    /// The last size the screen asked for, which each pane taken is given
    /// before its snapshot is made.
    private struct Geometry: Sendable {
        let columns: Int
        let rows: Int
        let cellWidth: Int?
        let cellHeight: Int?

        var arguments: [String: Any] {
            var args: [String: Any] = ["columns": columns, "rows": rows]
            if let cellWidth, let cellHeight {
                args["cell_width_px"] = cellWidth
                args["cell_height_px"] = cellHeight
            }
            return args
        }
    }

    private struct State: Sendable {
        /// The pane asked for last: typing and sizing go here.
        var requested: String
        /// The pane the current data connection carries.
        var streamBlock: String?
        /// Panes this client has taken for size and not handed back.
        var owned: Set<String> = []
        var generation = 0
        /// Generations whose pane Rex closed. `nc` exits when Rex closes its
        /// socket, so the channel's end follows the close frame: that end is
        /// the pane leaving, not the connection failing.
        var retired: Set<Int> = []
        /// Panes Rex closed (by event, by their stream, or by dropping out of
        /// the view). The layout held here is stale until the next view is
        /// read, so a pane in it is not a pane that is still there.
        var closedBlocks: Set<String> = []
        var stream: SSHExecStream?
        var parser: RexDataStream?
        var exitStatus: Int?
        /// The first resize came (or its wait ran out): data may open.
        var armed = false
        /// The switch loop is running.
        var switching = false
        var ended = false
        var geometry: Geometry?
        /// Panes whose program exited, with its exit status. Rex closes such a
        /// pane by default; until it does, the pane stays where it is.
        var exitCodes: [String: Int] = [:]

        var layout: RexSessionLayout?
        var revision: Int?
        /// The highest revision a `session_view_changed` announced.
        var wanted = -1
        var reading = false
        var labels: [String: String]
        var titles: [String: String] = [:]
        var titlesAsked: Set<String> = []
    }

    let sessionID: String
    /// The strip and minimap, newest only. Ends with the connection.
    let updates: AsyncStream<RexSessionState>
    private let updateSink: AsyncStream<RexSessionState>.Continuation
    private let transport: any RexTransport
    private let control: RexControl
    private let queue: SSHTerminalEventQueue
    private let core: Mutex<State>

    private init(transport: any RexTransport, control: RexControl, target: RexPaneTarget, queue: SSHTerminalEventQueue) {
        self.transport = transport
        self.control = control
        self.queue = queue
        sessionID = target.sessionID
        core = Mutex(State(requested: target.blockID, labels: [target.blockID: target.label]))
        (updates, updateSink) = AsyncStream.makeStream(of: RexSessionState.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Says hello on the control connection already running on `transport`,
    /// attaches to the pane's session (which starts its events, and answers
    /// with its view), and takes the pane. Cancelling it closes the
    /// connection, so a background cancel leaves nothing open.
    static func open(
        transport: any RexTransport,
        control: RexControl,
        target: RexPaneTarget,
        queue: SSHTerminalEventQueue
    ) async throws -> RexSessionConnection {
        try await withTaskCancellationHandler {
            control.attach { try await transport.send($0) }
            try await control.open()
            let connection = RexSessionConnection(transport: transport, control: control, target: target, queue: queue)
            control.onEvent { [weak connection] frame in
                if let event = RexEvent(frame: frame) { connection?.receive(event) }
            }
            let attached = try await control.call("session.attach", ["session_id": target.sessionID])
            struct Attached: Decodable { let view: RexView? }
            if let view = try? JSONDecoder().decode(Attached.self, from: attached).view {
                connection.core.withLock { _ = connection.apply(view: view, to: &$0) }
            }
            _ = try await control.call("session.own_block", [
                "session_id": target.sessionID, "block_ids": [target.blockID], "mode": "take",
            ])
            connection.core.withLock { _ = $0.owned.insert(target.blockID) }
            try Task.checkCancellation()
            control.onEnd { [weak connection] error in connection?.end(error.localizedDescription) }
            Task { [weak connection] in
                try? await Task.sleep(for: firstResizeWait)
                connection?.arm()
            }
            return connection
        } onCancel: {
            transport.close()
        }
    }

    // MARK: - What the screen reads and asks for

    /// What the strip and minimap show now.
    var state: RexSessionState { core.withLock { Self.snapshot($0) } }

    /// Shows `blockID`: the screen's one way to change pane, for a tap, a
    /// swipe, and VoiceOver alike. A pane the view does not list is ignored.
    func show(_ blockID: String) {
        let start = core.withLock { state -> Bool in
            guard !state.ended, blockID != state.requested, !state.closedBlocks.contains(blockID) else { return false }
            if let layout = state.layout, !layout.contains(blockID) { return false }
            state.requested = blockID
            publish(state)
            return startSwitching(&state)
        }
        if start { Task { await runSwitches() } }
    }

    /// Shows the pane `delta` places along the strip from the one last asked
    /// for, so two quick swipes go two panes. False past either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard let next = state.pane(offsetBy: delta) else { return false }
        show(next)
        return true
    }

    // MARK: - SSHTerminalConnection

    func send(_ bytes: Data) async throws {
        do {
            _ = try await control.call("com.superlogical.terminal.write", blockCall([
                // Keys, pastes, and SGR mouse reports are UTF-8; only legacy X10
                // mouse coordinates past column 95 are not, and they arrive mangled.
                "data": String(decoding: bytes, as: UTF8.self),
            ]))
        } catch RexClientError.refused {
            // The pane closed before this terminal heard: it is leaving, and
            // the session goes on. Anything else is the connection failing.
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        let geometry = Geometry(
            columns: columns, rows: rows,
            cellWidth: pixelWidth >= columns && pixelHeight >= rows ? pixelWidth / columns : nil,
            cellHeight: pixelWidth >= columns && pixelHeight >= rows ? pixelHeight / rows : nil
        )
        core.withLock { $0.geometry = geometry }
        do {
            _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments))
        } catch RexClientError.refused {
            // A pane that closed meanwhile, as for a write.
        }
        arm()
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        try await transport.run(command, input: input)
    }

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        try await transport.openStream(command: command, inboundFlow: nil, sink: sink)
    }

    func checkAlive() async throws { try await transport.checkAlive() }

    func close() {
        core.withLock { state in
            state.ended = true
            state.generation += 1
            state.stream = nil
        }
        updateSink.finish()
        transport.close()
    }

    func cancel() async {
        core.withLock { $0.ended = true }
        updateSink.finish()
        await transport.cancel()
    }

    // MARK: - Switching panes

    private func blockCall(_ args: [String: Any], block: String? = nil) -> [String: Any] {
        let target = block ?? core.withLock { $0.requested }
        return ["session_id": sessionID, "block_id": target, "args": args]
    }

    /// Data may open: the first time, for the pane asked for; after that,
    /// again for any pane asked for since.
    private func arm() {
        let start = core.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.armed = true
            return startSwitching(&state)
        }
        if start { Task { await runSwitches() } }
    }

    /// Decides, under the lock, whether the caller starts the switch loop:
    /// data is allowed, the pane on screen is not the one asked for, and no
    /// loop is running.
    private func startSwitching(_ state: inout State) -> Bool {
        guard state.armed, !state.ended, !state.switching, state.streamBlock != state.requested else { return false }
        state.switching = true
        return true
    }

    /// Switches until the data connection carries the pane asked for last,
    /// then hands back every pane taken and not shown (a switch overtaken
    /// after its pane was taken would otherwise leave it at this screen's
    /// size). Both run in this loop, so no switch starts while a hand-back
    /// is in flight.
    private func runSwitches() async {
        enum Work { case done, show(String), handBack([String]) }
        while true {
            let work = core.withLock { state -> Work in
                guard !state.ended, state.armed else {
                    state.switching = false
                    return .done
                }
                if state.streamBlock != state.requested { return .show(state.requested) }
                if let shown = state.streamBlock {
                    let behind = state.owned.subtracting([shown])
                    if !behind.isEmpty {
                        state.owned = [shown]
                        return .handBack(Array(behind))
                    }
                }
                state.switching = false
                return .done
            }
            let block: String
            switch work {
            case .done:
                return
            case .handBack(let behind):
                // Best effort: a pane that closed has nothing to give back.
                _ = try? await control.call("session.disown_block", ["session_id": sessionID, "block_ids": behind])
                continue
            case .show(let next):
                block = next
            }
            do {
                try await switchData(to: block)
            } catch {
                // Rex refused the pane: it closed before this terminal heard.
                // Anything else is the connection failing.
                enum Recovery { case carryOn, ended, failed }
                let recovery = core.withLock { state -> Recovery in
                    guard case RexClientError.refused = error, !state.ended else { return .failed }
                    // A newer request replaced this one while it waited; it stands.
                    guard state.requested == block else { return .carryOn }
                    state.closedBlocks.insert(block)
                    // Back to the pane on screen if it is still there, else the
                    // first pane that is; with none left there is nothing to show.
                    let streaming = state.streamBlock.flatMap { shown in
                        !state.closedBlocks.contains(shown) && !state.retired.contains(state.generation) ? shown : nil
                    }
                    let live = state.layout?.panes.map(\.blockID).first { !state.closedBlocks.contains($0) }
                    guard let next = streaming ?? live else { return .ended }
                    state.requested = next
                    publish(state)
                    return .carryOn
                }
                switch recovery {
                case .carryOn:
                    break
                case .ended:
                    core.withLock { $0.switching = false }
                    end("The pane closed in Rex.")
                    return
                case .failed:
                    core.withLock { $0.switching = false }
                    end(error.localizedDescription)
                    return
                }
            }
        }
    }

    /// Takes `block` for size (if this client has not), sizes it to the
    /// screen, then swaps the data connection. A request overtaken while this
    /// waits on Rex returns before it touches the stream.
    private func switchData(to block: String) async throws {
        func wanted() -> Bool { core.withLock { !$0.ended && $0.requested == block } }
        if core.withLock({ !$0.owned.contains(block) }) {
            _ = try await control.call("session.own_block", [
                "session_id": sessionID, "block_ids": [block], "mode": "take",
            ])
            core.withLock { _ = $0.owned.insert(block) }
        }
        // The pane takes this screen's size before its snapshot is made.
        if let geometry = core.withLock({ $0.geometry }) {
            _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: block))
        }
        guard wanted() else { return }
        let answer = try await control.call("data.connect", [
            "session_id": sessionID, "block_id": block,
            "data_ref_id": "terminal", "subprotocol": Self.dataSubprotocol,
        ])
        struct Ticket: Decodable { let ticket: String }
        guard let ticket = try? JSONDecoder().decode(Ticket.self, from: answer),
              let bytes = Self.base64URL(ticket.ticket), bytes.count == 16 else {
            throw RexClientError.unreadable("a data ticket")
        }
        guard wanted() else { return }
        let parser = RexDataStream(ticket: bytes)
        // From here the old pane's stream is dead to the grid: its events
        // carry the generation they were opened under.
        let (old, generation) = core.withLock { state -> (SSHExecStream?, Int) in
            state.generation += 1
            let old = state.stream
            state.stream = nil
            state.parser = parser
            state.streamBlock = block
            state.exitStatus = nil
            return (old, state.generation)
        }
        old?.close()
        let stream = try await transport.openStream(command: RexBridge.command, inboundFlow: queue.flow) { [weak self] event in
            self?.receiveData(event, generation: generation)
        }
        let kept = core.withLock { state -> Bool in
            guard !state.ended, state.generation == generation else { return false }
            state.stream = stream
            return true
        }
        guard kept else {
            stream.close()
            return
        }
        try await stream.send(parser.upgradeRequest)
    }

    /// The data connection's events, on the SSH event loop and in order, so
    /// the snapshot and output reach the queue in the order Rex sent them.
    /// EOF comes before the bridge's exit status; `.closed` follows both.
    /// Events of a connection that was replaced (`generation`) are dropped.
    private func receiveData(_ event: SSHPTYEvent, generation mine: Int) {
        switch event {
        case .data(let bytes):
            let (outputs, stream, block) = core.withLock { state -> ([RexDataStream.Output], SSHExecStream?, String?) in
                guard !state.ended, state.generation == mine, var parser = state.parser else { return ([], nil, nil) }
                let outputs = parser.receive(bytes)
                state.parser = parser
                return (outputs, state.stream, state.streamBlock)
            }
            for output in outputs {
                switch output {
                case .send(let frame):
                    Task { [weak self] in
                        do { try await stream?.send(frame) } catch { self?.end(error.localizedDescription) }
                    }
                case .snapshot(let snapshot): queue.pushSnapshot(snapshot)
                case .output(let bytes): queue.push(.data(bytes))
                case .exited(let code):
                    if let block { core.withLock { $0.exitCodes[block] = code } }
                case .paneClosed:
                    // The bridge's end follows this frame; it is not a failure.
                    core.withLock { _ = $0.retired.insert(mine) }
                    if let block { closed(block, reason: "The pane closed in Rex.") }
                case .ended(let reason): end(reason)
                }
            }
        case .exitStatus(let status):
            core.withLock { if $0.generation == mine, !$0.retired.contains(mine) { $0.exitStatus = status } }
        case .closed:
            let reason = core.withLock { state -> String? in
                guard !state.ended, state.generation == mine, !state.retired.contains(mine) else { return nil }
                return RexBridge.failure(exitStatus: state.exitStatus).localizedDescription
            }
            if let reason { end(reason) }
        case .eof, .exitSignal, .writabilityChanged:
            break
        }
    }

    private func end(_ reason: String) {
        let first = core.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.ended = true
            return true
        }
        guard first else { return }
        updateSink.finish()
        queue.end(reason)
    }

    /// `block` is gone from the host. If it is the pane on screen, move to its
    /// neighbour (the next, else the one before); with none left the terminal
    /// ends with `reason`.
    private func closed(_ block: String, reason: String) {
        let order = core.withLock { $0.layout?.panes.map(\.blockID) ?? [block] }
        leave(block, order: order, surviving: Set(order), reason: reason)
    }

    /// The pane on screen is `block`, and it is gone: show the neighbour it
    /// had in `order` among `surviving`, or end the terminal with `reason`.
    /// Nothing happens for a pane that is not on screen.
    private func leave(_ block: String, order: [String], surviving: Set<String>, reason: String) {
        // `surviving` comes from a view that may be stale: what Rex has closed since is not in it.
        let (onScreen, alive) = core.withLock { state -> (Bool, Set<String>) in
            state.closedBlocks.insert(block)
            return (!state.ended && state.requested == block, surviving.subtracting(state.closedBlocks))
        }
        guard onScreen else { return }
        if let next = RexSessionLayout.neighbour(of: block, in: order, surviving: alive) {
            show(next)
        } else {
            // The last pane: its program's exit status is what the person wants to know.
            let exited = core.withLock { state in
                state.exitCodes[block].map { "\(Self.name(of: block, in: state)) exited with status \($0)." }
            }
            end(exited ?? reason)
        }
    }

    // MARK: - The session's view

    private func receive(_ event: RexEvent) {
        guard event.session == sessionID else { return }
        switch event {
        case .viewChanged(_, let revision):
            core.withLock { $0.wanted = max($0.wanted, revision) }
            readView()
        case .title(_, let block, let title):
            core.withLock { state in
                state.titles[block] = title
                publish(state)
            }
        case .blockClosed(_, let block):
            closed(block, reason: "The pane closed in Rex.")
        case .sessionDestroyed:
            end("The Rex session was closed.")
        default:
            break
        }
    }

    /// Reads the view again if an event announced a newer one than the one
    /// applied: one read at a time, again if another event came meanwhile.
    private func readView() {
        let start = core.withLock { state -> Bool in
            guard !state.ended, !state.reading, state.wanted > (state.revision ?? -1) else { return false }
            state.reading = true
            return true
        }
        guard start else { return }
        Task { [weak self] in
            while let self {
                let answer = try? await control.call("session.view", ["session_id": sessionID])
                let decoded = answer.flatMap { try? JSONDecoder().decode(RexView.self, from: $0) }
                let (again, gone) = core.withLock { state -> (Bool, (String, [String], Set<String>)?) in
                    var gone: (String, [String], Set<String>)?
                    if let decoded { gone = apply(view: decoded, to: &state) }
                    // A read that failed waits for the next event.
                    let again = decoded != nil && !state.ended && state.wanted > (state.revision ?? -1)
                    if !again { state.reading = false }
                    return (again, gone)
                }
                if let gone { leave(gone.0, order: gone.1, surviving: gone.2, reason: "The pane closed in Rex.") }
                if !again { return }
            }
        }
    }

    /// Applies a view unless a newer one already is (replies can overtake each
    /// other), publishes it, and asks for the titles of panes not yet read. A
    /// view without a revision counts as at least the newest one announced.
    /// Returns the pane on screen, with its neighbours, if the view no longer
    /// lists it.
    @discardableResult
    private func apply(view: RexView, to state: inout State) -> (String, [String], Set<String>)? {
        if let revision = view.revision, let applied = state.revision, revision < applied { return nil }
        state.revision = view.revision ?? max(state.revision ?? -1, state.wanted)
        let layout = RexSessionLayout(view: view)
        let before = state.layout?.panes.map(\.blockID)
        // A pane the new view no longer lists is closed.
        if let before { state.closedBlocks.formUnion(Set(before).subtracting(layout.panes.map(\.blockID))) }
        state.layout = layout
        for pane in layout.panes {
            if let label = pane.label { state.labels[pane.blockID] = label }
        }
        publish(state)
        for pane in layout.panes where state.titlesAsked.insert(pane.blockID).inserted {
            readTitle(of: pane.blockID)
        }
        guard !layout.contains(state.requested), let before, before.contains(state.requested) else { return nil }
        return (state.requested, before, Set(layout.panes.map(\.blockID)))
    }

    private func readTitle(of block: String) {
        Task { [weak self] in
            guard let self else { return }
            let answer = try? await control.call("com.superlogical.terminal.title", blockCall([:], block: block))
            struct Title: Decodable { let title: String? }
            guard let title = answer.flatMap({ try? JSONDecoder().decode(Title.self, from: $0).title }) else { return }
            // A title event that came first is newer.
            core.withLock { state in
                guard state.titles[block] == nil else { return }
                state.titles[block] = title
                publish(state)
            }
        }
    }

    private static func name(of block: String, in state: State) -> String {
        RexSnapshot.Pane(
            blockID: block, label: state.labels[block], title: state.titles[block], pwd: nil, records: []
        ).displayName
    }

    private static func snapshot(_ state: State) -> RexSessionState {
        // Until a view has been read, the pane that was asked for is the only one known.
        let order = state.layout?.panes.map(\.blockID) ?? [state.requested]
        return RexSessionState(
            panes: order.map { .init(blockID: $0, name: name(of: $0, in: state)) },
            shown: state.requested,
            minimap: state.layout?.minimap(around: state.requested) ?? []
        )
    }

    private func publish(_ state: State) {
        updateSink.yield(Self.snapshot(state))
    }

    /// Rex writes tickets as base64url without padding.
    static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
