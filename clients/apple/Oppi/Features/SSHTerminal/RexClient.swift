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
/// sign-in or network access of its own. The fallback when Rex is not
/// reached over Tailscale (`RexRoutePlan`).
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
    /// The stream under the socket failed, and why (a network error, or the
    /// signal that ended the bridge).
    case lost(String)
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
        case .lost(let reason): "The connection to Rex was lost: \(reason)"
        case .timedOut: "Rex did not answer in time."
        case .refused(_, let message): "Rex refused: \(message)"
        case .unreadable(let detail): "Rex sent something Oppi cannot read: \(detail)"
        }
    }
}

/// Rex's control connection (`/api/control`, `rex.control.v1`) over a
/// `RexSocket`: one hello, then JSON requests matched to their responses by
/// id. Events go to `onEvent` when one is set, and are skipped otherwise.
///
/// Thread-safe: `receive` runs on the socket's thread, requests on any task.
final class RexControl: Sendable {
    /// The API revision this client was written against, from the server's
    /// own API page.
    static let apiRevision = 7
    /// No Rex request this client makes takes long; one with no answer by
    /// then is abandoned, and a late answer is dropped.
    static let requestTimeout: Duration = .seconds(15)

    private struct State {
        var socket: (any RexSocket)?
        var nextID = 0
        /// A result that arrived before its caller waited for it.
        var early: [String: Result<Data, any Error>] = [:]
        var waiting: [String: CheckedContinuation<Data, any Error>] = [:]
        /// Requests given up on, and why; an answer that comes later is dropped.
        var abandoned: [String: any Error] = [:]
        var ended: (any Error)?
        var onEnd: (@Sendable (any Error) -> Void)?
        var onEvent: (@Sendable ([String: Any]) -> Void)?
    }

    private static let welcomeID = "welcome"
    private let state = Mutex(State())
    private let timeout: Duration

    init(requestTimeout: Duration = RexControl.requestTimeout) {
        timeout = requestTimeout
    }

    /// Where requests go: the socket whose events reach `receive`.
    func attach(_ socket: any RexSocket) { state.withLock { $0.socket = socket } }

    /// Closes the socket; the connection ends when it reports its end.
    func close() { state.withLock { $0.socket }?.close() }

    /// Called once when the connection ends, with why.
    func onEnd(_ handler: @escaping @Sendable (any Error) -> Void) {
        let ended = state.withLock { state -> (any Error)? in
            state.onEnd = handler
            return state.ended
        }
        if let ended { handler(ended) }
    }

    /// Called for every server event, as Rex framed it (`{"type":"event","seq":…,"payload":{…}}`),
    /// on the socket's thread and in the order Rex sent them. A single pane
    /// does not set one: the connection only receives events once it has
    /// attached to a session or to the whole server.
    func onEvent(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        state.withLock { $0.onEvent = handler }
    }

    /// Says hello on the attached socket. Returns once Rex welcomed this
    /// client, within `timeout` (the request timeout by default).
    func open(timeout: Duration? = nil) async throws {
        let hello = try Self.json([
            "type": "hello",
            "api_revision": Self.apiRevision,
            "client": ["kind": "app", "platform": "ios", "name": "Oppi"],
        ])
        _ = try await exchange(id: Self.welcomeID, message: hello, timeout: timeout ?? self.timeout)
    }

    /// Calls a method and returns its result's JSON.
    func call(_ method: String, _ payload: [String: Any]) async throws -> Data {
        let id = state.withLock { state -> String in
            state.nextID += 1
            return String(state.nextID)
        }
        let request = try Self.json(["type": "request", "id": id, "method": method, "payload": payload])
        return try await exchange(id: id, message: request, timeout: timeout)
    }

    /// Feeds what the socket reports. Its end ends the connection, with its reason.
    func receive(_ event: RexSocketEvent) {
        switch event {
        case .message(let message): handle(message)
        case .ended(let error): end(error)
        case .writable: break
        }
    }

    private func handle(_ message: RexSocketMessage) {
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

    /// Sends `message`, then waits for the result filed under `id`, at most
    /// `timeout`.
    private func exchange(id: String, message: Data, timeout: Duration) async throws -> Data {
        let socket = try state.withLock { state -> any RexSocket in
            if let ended = state.ended { throw ended }
            guard let socket = state.socket else { throw RexClientError.connectionClosed }
            return socket
        }
        try await socket.send(.text(String(decoding: message, as: UTF8.self)))
        let timer = Task { [weak self] in
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

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
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
    }

    private var terminal: RexTerminalStream?
    private var over = false

    /// HELLO with the ticket `data.connect` issued: the first message on the open socket.
    static func hello(ticket: Data) -> RexSocketMessage { .binary(RexDataHandshake.hello(ticket: ticket)) }

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
                case .snapshotRecords(let records): .snapshotRecords(records)
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

/// How this device reaches one host's Rex, and opens its WebSockets: over the
/// SSH bridge, an exec stream of `RexBridge.command` per socket, or over a TLS
/// stream to Rex's Tailscale serving. Either way this side frames the
/// WebSocket (`RexPipeSocket`). `RexRoutePlan` picks the route.
struct RexLink: Sendable {
    typealias OpenStream = @Sendable (
        _ command: String, _ inboundFlow: SSHPTYInboundFlow?, _ sink: @escaping SSHPTYByteSink
    ) async throws -> SSHExecStream
    /// Opens a byte stream to Rex's Tailscale serving at a URL, within a
    /// timeout (`RexTLSStream.open`).
    typealias OpenDirect = @Sendable (
        _ url: URL, _ inboundFlow: SSHPTYInboundFlow?, _ timeout: Duration, _ sink: @escaping SSHPTYByteSink
    ) async throws -> SSHExecStream

    let route: RexRoute
    /// Opens an exec stream on the host's SSH connection.
    let openStream: OpenStream
    let openDirect: OpenDirect

    init(route: RexRoute = .ssh, openStream: @escaping OpenStream, openDirect: @escaping OpenDirect = RexTLSStream.open) {
        self.route = route
        self.openStream = openStream
        self.openDirect = openDirect
    }

    /// Opens one of Rex's sockets within `timeout`; `onEvent` hears everything
    /// after the upgrade.
    func open(
        _ endpoint: RexEndpoint,
        inboundFlow: SSHPTYInboundFlow? = nil,
        timeout: Duration = RexControl.requestTimeout,
        onEvent: @escaping @Sendable (RexSocketEvent) -> Void
    ) async throws -> any RexSocket {
        switch route {
        case .ssh:
            try await RexPipeSocket.open(
                endpoint, timeout: timeout,
                openStream: { [openStream] sink in try await openStream(RexBridge.command, inboundFlow, sink) },
                onEvent: onEvent
            )
        case .tailscale(let url):
            try await RexPipeSocket.open(
                endpoint, host: Self.hostHeader(url), timeout: timeout,
                openStream: { [openDirect] sink in try await openDirect(url, inboundFlow, timeout, sink) },
                onEvent: onEvent
            )
        }
    }

    /// A control connection Rex has welcomed over this link, the upgrade and
    /// the welcome each within `timeout`. `onWritable` hears the control
    /// socket's writability, which typing waits on. Cancelling closes it, and
    /// so does a hello that fails: no bridge or stream is left behind.
    func connect(
        timeout: Duration = RexControl.requestTimeout,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> RexControl {
        let control = RexControl()
        let socket = try await open(.control, timeout: timeout) { event in
            if case .writable(let writable) = event { onWritable?(writable) }
            control.receive(event)
        }
        control.attach(socket)
        do {
            try await withTaskCancellationHandler {
                try await control.open(timeout: timeout)
            } onCancel: {
                socket.close()
            }
        } catch {
            socket.close()
            throw error
        }
        return control
    }

    /// `Host` for an upgrade to Rex at `url`: its name, and its port when the
    /// URL names one.
    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? "localhost"
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// What a Rex terminal needs of its host: a data socket per pane beside the
/// control connection, side commands and streams on SSH, and the connection's
/// own lifecycle. `RexHostTransport` is one; tests and previews stand in for
/// the host with another.
protocol RexTransport: Sendable {
    /// Which way Rex's sockets go.
    var route: RexRoute { get }
    func openData(
        inboundFlow: SSHPTYInboundFlow?, onEvent: @escaping @Sendable (RexSocketEvent) -> Void
    ) async throws -> any RexSocket
    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream
    func run(_ command: String, input: Data) async throws -> SSHExecResult
    func checkAlive() async throws
    func close()
    func cancel() async
}

/// A Rex terminal's signed-in SSH connection, which runs no shell: Rex's
/// control connection and each pane's data connection go over its `RexLink`,
/// and side commands (uploads, the theme, keybindings) run beside them. It
/// probes the peer as a shell's connection does (`SSHConnection.startKeepalive`).
final class RexHostTransport: RexTransport {
    let link: RexLink
    var route: RexRoute { link.route }
    private let connection: SSHConnection
    private let control: RexControl

    private init(connection: SSHConnection, link: RexLink, control: RexControl) {
        self.connection = connection
        self.link = link
        self.control = control
        // Ends with the connection.
        connection.startKeepalive()
        // Side commands need the SSH connection: when it goes, the terminal
        // goes with it, whatever carries Rex.
        connection.channel.closeFuture.whenComplete { _ in control.close() }
    }

    /// Opens Rex's control connection by `plan`'s route (the bridge on
    /// `connection` without one) and says hello.
    static func open(
        connection: SSHConnection,
        plan: RexRoutePlan? = nil,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (RexHostTransport, RexControl) {
        let (link, control) = try await RexLink.connect(
            plan: plan,
            openStream: { try await connection.openStream(command: $0, inboundFlow: $1, sink: $2) },
            run: { try await connection.run($0, maximumOutputBytes: 64 * 1024, timeout: .seconds(10)) },
            onWritable: onWritable
        )
        return (RexHostTransport(connection: connection, link: link, control: control), control)
    }

    func openData(
        inboundFlow: SSHPTYInboundFlow?, onEvent: @escaping @Sendable (RexSocketEvent) -> Void
    ) async throws -> any RexSocket {
        try await link.open(.data, inboundFlow: inboundFlow, onEvent: onEvent)
    }

    func openStream(command: String, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        try await connection.openStream(command: command, inboundFlow: inboundFlow, sink: sink)
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        // An upload over a slow link needs longer than an API call.
        try await connection.run(
            command, input: input, maximumOutputBytes: 2 * 1024 * 1024,
            timeout: input.count > 64 * 1024 ? .seconds(120) : .seconds(10)
        )
    }

    /// One SSH round trip, and over Tailscale one Rex round trip too: either
    /// failing closes the connection, as a failed probe does.
    func checkAlive() async throws {
        try await connection.checkAlive()
        guard case .tailscale = route else { return }
        do {
            _ = try await control.call("server.status", [:])
        } catch {
            close()
            throw error
        }
    }

    func close() {
        control.close()
        connection.close()
    }

    func cancel() async {
        close()
        _ = try? await connection.channel.closeFuture.get()
    }
}

/// One Rex session shown as a terminal, over the connection to its host:
/// one control connection, attached to the session, and one data connection
/// for the pane on screen.
///
/// The shown pane's output comes on the data connection, which first opens on
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
/// the grid and never ends the terminal. The pane switcher and minimap follow
/// `session.view`, read again at each `session_view_changed` (at most one read
/// at a time, again if another came meanwhile, an older answer dropped).
///
/// Typing goes to the pane as `com.superlogical.terminal.write`, one call at a
/// time (the channel waits for each), so keys keep their order. Side commands
/// (uploads, the Ghostty theme, keybindings) run on the same SSH connection as
/// for a shell, since the pane is on the same host.
final class RexSessionConnection: SSHTerminalConnection, Sendable {
    /// A screen that never sizes the terminal still gets its pane.
    static let firstResizeWait: Duration = .milliseconds(1500)

    /// The last size the screen asked for, which each pane taken is given
    /// before its snapshot is made.
    private struct Geometry: Equatable, Sendable {
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
        /// The size each owned pane was last given, so a switch does not
        /// size again a pane the screen just sized (the first pane, on the
        /// first layout).
        var sized: [String: Geometry] = [:]
        /// The pane the data connection carried before the switch now under
        /// way, to go back to if Rex refuses the new one.
        var fallback: String?
        var generation = 0
        /// Generations whose pane Rex closed. The socket's end follows the
        /// close frame (over the bridge, `nc` exits when Rex closes its
        /// socket): that end is the pane leaving, not the connection failing.
        var retired: Set<Int> = []
        /// Panes Rex closed (by event, by their stream, or by dropping out of
        /// the view). The layout held here is stale until the next view is
        /// read, so a pane in it is not a pane that is still there.
        var closedBlocks: Set<String> = []
        var stream: (any RexSocket)?
        var parser: RexDataStream?
        /// The first resize came (or its wait ran out): data may open.
        var armed = false
        /// The switch loop is running.
        var switching = false
        var ended = false
        var geometry: Geometry?
        /// Panes whose program exited, with its exit status. Rex closes such a
        /// pane by default; until it does, the pane stays where it is.
        var exitCodes: [String: Int] = [:]
        /// When the shown pane's stream was asked for, until its snapshot came.
        var snapshotAsked: ContinuousClock.Instant?

        var layout: RexSessionLayout?
        var revision: Int?
        /// The highest revision a `session_view_changed` announced.
        var wanted = -1
        var reading = false
        var labels: [String: String]
        var titles: [String: String] = [:]
        var titlesAsked: Set<String> = []
        /// Each pane's OSC 7501 records, from one read and then its events.
        var records: [String: [SSHTerminalPaneRecord]] = [:]
        /// Panes whose records an event already set: an older read does not overwrite them.
        var recordsTouched: Set<String> = []
    }

    let sessionID: String
    /// The pane switcher and minimap, newest only. Ends with the connection.
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

    /// Over a control connection Rex has welcomed on `transport`, attaches to
    /// the pane's session (which starts its events, and answers with its
    /// view), and takes the pane. Cancelling it closes the connection, so a
    /// background cancel leaves nothing open.
    static func open(
        transport: any RexTransport,
        control: RexControl,
        target: RexPaneTarget,
        queue: SSHTerminalEventQueue
    ) async throws -> RexSessionConnection {
        try await withTaskCancellationHandler {
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

    /// What the pane switcher and minimap show now.
    var state: RexSessionState { core.withLock { Self.snapshot($0) } }

    /// Which way Rex is reached.
    var route: RexRoute { transport.route }

    /// Shows `blockID`: the screen's one way to change pane, for a tap, a
    /// swipe, and VoiceOver alike. A pane the view does not list is ignored
    /// (false); true means the pane is now the one asked for.
    @discardableResult
    func show(_ blockID: String) -> Bool {
        let (accepted, start) = core.withLock { state -> (Bool, Bool) in
            guard !state.ended, blockID != state.requested, !state.closedBlocks.contains(blockID) else { return (false, false) }
            if let layout = state.layout, !layout.contains(blockID) { return (false, false) }
            state.requested = blockID
            publish(state)
            return (true, startSwitching(&state))
        }
        if start { Task { await runSwitches() } }
        return accepted
    }

    /// Shows the pane `delta` places along the strip from the one last asked
    /// for, so two quick swipes go two panes. False past either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard let next = state.pane(offsetBy: delta) else { return false }
        return show(next)
    }

    /// Opens a shell in a new split after the pane last asked for and returns
    /// its block id, once the session's view lists it (so `show` takes it). It
    /// starts in the anchor's folder when Rex has one (`pwd`, which a shell
    /// reports with OSC 7), else Rex's default. Display only: `focus` is false,
    /// so the host's own focus stays where it is. Rex creates all of it or none
    /// of it; a refusal (the anchor closed, the session full) throws.
    func newPane() async throws -> String {
        let anchor = core.withLock { $0.requested }
        var shell: [String: Any] = ["flavor": Self.shellFlavor]
        let pwd = try? await control.call("com.superlogical.terminal.pwd", blockCall([:], block: anchor))
        if let folder = pwd.flatMap({ try? JSONDecoder().decode(Pwd.self, from: $0).pwd }).flatMap(Self.folder(fromPwd:)) {
            shell["options"] = ["cwd": folder]
        }
        let answer = try await control.call("session.new_split", [
            "session_id": sessionID, "anchor_id": anchor, "direction": "horizontal", "side": "after",
            "focus": false, "layout": ["block": shell],
        ])
        struct Created: Decodable { let block_ids: [String?]? }
        guard let block = (try? JSONDecoder().decode(Created.self, from: answer))?.block_ids?.compactMap({ $0 }).first else {
            throw RexClientError.unreadable("the new pane's block")
        }
        // The view event that lists it may not have arrived yet: read it now.
        let view = try await control.call("session.view", ["session_id": sessionID])
        let decoded = try JSONDecoder().decode(RexView.self, from: view)
        let gone = core.withLock { apply(view: decoded, to: &$0) }
        if let gone { leave(gone.0, order: gone.1, surviving: gone.2, reason: "The pane closed in Rex.") }
        guard core.withLock({ $0.layout?.contains(block) == true }) else {
            throw RexClientError.unreadable("a view without the new pane")
        }
        return block
    }

    private struct Pwd: Decodable { let pwd: String? }

    static let shellFlavor = "com.superlogical.terminal.shell"

    /// The folder a `pwd` answer names: a path, or the `file://` URL a program
    /// reports with OSC 7. Nil for anything else (Rex gave none).
    static func folder(fromPwd pwd: String) -> String? {
        if pwd.hasPrefix("/") { return pwd }
        guard pwd.hasPrefix("file://"), let path = URL(string: pwd)?.path, path.hasPrefix("/") else { return nil }
        return path
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
        let target = core.withLock { state -> String in
            state.geometry = geometry
            return state.requested
        }
        do {
            _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: target))
            core.withLock { state in
                if state.owned.contains(target) { state.sized[target] = geometry }
            }
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
        let stream = core.withLock { state -> (any RexSocket)? in
            state.ended = true
            state.generation += 1
            defer { state.stream = nil }
            return state.stream
        }
        updateSink.finish()
        stream?.close()
        transport.close()
    }

    func cancel() async {
        let stream = core.withLock { state -> (any RexSocket)? in
            state.ended = true
            return state.stream
        }
        updateSink.finish()
        stream?.close()
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
                        for block in behind { state.sized[block] = nil }
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
                    // Back to the pane on screen if it is still there (the one
                    // before this switch, if its stream already gave way), else
                    // the first pane that is; with none left there is nothing to show.
                    let streaming: String? = if state.streamBlock == block {
                        state.fallback.flatMap { state.closedBlocks.contains($0) ? nil : $0 }
                    } else {
                        state.streamBlock.flatMap { shown in
                            !state.closedBlocks.contains(shown) && !state.retired.contains(state.generation) ? shown : nil
                        }
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
    /// screen (unless it already has this size), then swaps the data
    /// connection. The new connection's channel, its bridge, and its
    /// WebSocket upgrade need no ticket, so they open while `data.connect`
    /// issues one; HELLO waits for it. The pane before stops reaching the grid
    /// once the swap starts (it is under the transition's cover by then). A
    /// request overtaken while this waits on Rex closes the new connection
    /// before it says HELLO.
    private func switchData(to block: String) async throws {
        func wanted() -> Bool { core.withLock { !$0.ended && $0.requested == block } }
        if core.withLock({ !$0.owned.contains(block) }) {
            _ = try await control.call("session.own_block", [
                "session_id": sessionID, "block_ids": [block], "mode": "take",
            ])
            core.withLock { _ = $0.owned.insert(block) }
        }
        // The pane takes this screen's size before its snapshot is made.
        if let geometry = core.withLock({ state in state.sized[block] == state.geometry ? nil : state.geometry }) {
            _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: block))
            core.withLock { $0.sized[block] = geometry }
        }
        guard wanted() else { return }
        core.withLock { $0.snapshotAsked = .now }
        let ticketAnswer = Task { [control, sessionID] in
            try await control.call("data.connect", [
                "session_id": sessionID, "block_id": block,
                "data_ref_id": "terminal", "subprotocol": RexEndpoint.data.subprotocol,
            ])
        }
        let parser = RexDataStream()
        // From here the old pane's stream is dead to the grid: its events
        // carry the generation they were opened under.
        let (old, generation) = core.withLock { state -> ((any RexSocket)?, Int) in
            state.generation += 1
            let old = state.stream
            // The pane on screen before the first of switches that overtake
            // each other: a pane overtaken before HELLO never drew.
            if state.fallback == nil { state.fallback = state.streamBlock }
            state.stream = nil
            state.parser = parser
            state.streamBlock = block
            return (old, state.generation)
        }
        old?.close()
        /// This connection will never say HELLO: its end is not the pane's.
        func abandon(_ stream: (any RexSocket)?) {
            core.withLock { state in
                guard state.generation == generation else { return }
                state.retired.insert(generation)
                state.stream = nil
            }
            stream?.close()
        }
        // The socket opens and upgrades while the ticket is issued.
        let stream: any RexSocket
        do {
            stream = try await transport.openData(inboundFlow: queue.flow) { [weak self] event in
                self?.receiveData(event, generation: generation)
            }
        } catch {
            ticketAnswer.cancel()
            throw error
        }
        let kept = core.withLock { state -> Bool in
            guard !state.ended, state.generation == generation else { return false }
            state.stream = stream
            return true
        }
        guard kept else {
            ticketAnswer.cancel()
            stream.close()
            return
        }
        let bytes: Data
        do {
            struct Ticket: Decodable { let ticket: String }
            let answer = try await ticketAnswer.value
            guard let ticket = try? JSONDecoder().decode(Ticket.self, from: answer),
                  let decoded = Self.base64URL(ticket.ticket), decoded.count == 16 else {
                throw RexClientError.unreadable("a data ticket")
            }
            bytes = decoded
        } catch {
            ticketAnswer.cancel()
            abandon(stream)
            throw error
        }
        guard wanted() else {
            abandon(stream)
            return
        }
        let current = core.withLock { state -> Bool in
            guard !state.ended, state.generation == generation else { return false }
            state.fallback = nil
            return true
        }
        guard current else { return }
        try await stream.send(RexDataStream.hello(ticket: bytes))
    }

    /// The data connection's events, on the socket's thread and in order, so
    /// the snapshot and output reach the queue in the order Rex sent them.
    /// Events of a connection that was replaced (`generation`) are dropped.
    private func receiveData(_ event: RexSocketEvent, generation mine: Int) {
        switch event {
        case .message(let message):
            let (outputs, block) = core.withLock { state -> ([RexDataStream.Output], String?) in
                guard !state.ended, state.generation == mine, var parser = state.parser else { return ([], nil) }
                let outputs = parser.receive(message)
                state.parser = parser
                return (outputs, state.streamBlock)
            }
            for output in outputs {
                switch output {
                case .snapshot(let snapshot):
                    // The screen is up (READY); its history follows.
                    if let asked = core.withLock({ state in defer { state.snapshotAsked = nil }; return state.snapshotAsked }) {
                        let elapsed = ContinuousClock.now - asked
                        RexRouteLog.snapshot(route, milliseconds: Int(elapsed / .milliseconds(1)), bytes: snapshot.count)
                    }
                    queue.pushSnapshot(snapshot, block: block)
                case .snapshotRecords(let records): queue.pushSnapshotRecords(records, block: block)
                case .output(let bytes): queue.push(.data(bytes))
                case .exited(let code):
                    if let block { core.withLock { $0.exitCodes[block] = code } }
                case .paneClosed:
                    // The socket's end follows this frame; it is not a failure.
                    core.withLock { _ = $0.retired.insert(mine) }
                    if let block { closed(block, reason: "The pane closed in Rex.") }
                case .ended(let reason): end(reason)
                }
            }
        case .ended(let error):
            let current = core.withLock { !$0.ended && $0.generation == mine && !$0.retired.contains(mine) }
            if current { end(error.localizedDescription) }
        case .writable:
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
        case .status(_, let block, let record):
            changeRecords(of: block) { records in
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = record
                } else {
                    records.append(record)
                }
            }
        case .statusRemoved(_, let block, let ids):
            changeRecords(of: block) { $0.removeAll { ids.contains($0.id) } }
        case .childExited(_, let block):
            // The program is gone; so is whatever it reported.
            changeRecords(of: block) { $0 = [] }
        case .blockClosed(_, let block):
            closed(block, reason: "The pane closed in Rex.")
        case .sessionDestroyed:
            end("The Rex session was closed.")
        default:
            break
        }
    }

    private func changeRecords(of block: String, _ change: (inout [SSHTerminalPaneRecord]) -> Void) {
        core.withLock { state in
            var records = state.records[block] ?? []
            change(&records)
            state.records[block] = records
            state.recordsTouched.insert(block)
            publish(state)
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
            readDetails(of: pane.blockID)
        }
        guard !layout.contains(state.requested), let before, before.contains(state.requested) else { return nil }
        return (state.requested, before, Set(layout.panes.map(\.blockID)))
    }

    /// Reads a pane's title and the status its program reports, once. A read
    /// that fails (an older Rex) leaves its field out.
    private func readDetails(of block: String) {
        Task { [weak self] in
            guard let self else { return }
            async let titleAnswer = try? control.call("com.superlogical.terminal.title", blockCall([:], block: block))
            async let statusAnswer = try? control.call("com.superlogical.terminal.program_status", blockCall([:], block: block))
            struct Title: Decodable { let title: String? }
            struct Status: Decodable { let records: [SSHTerminalPaneRecord]? }
            let title = await titleAnswer.flatMap { try? JSONDecoder().decode(Title.self, from: $0).title }
            let records = await statusAnswer.flatMap { try? JSONDecoder().decode(Status.self, from: $0).records }
            // An event that came first is newer.
            core.withLock { state in
                if let title, state.titles[block] == nil { state.titles[block] = title }
                if let records, !state.recordsTouched.contains(block) { state.records[block] = records }
                publish(state)
            }
        }
    }

    private static func name(of block: String, in state: State) -> String {
        RexSnapshot.Pane(
            blockID: block, label: state.labels[block], title: state.titles[block], pwd: nil, records: []
        ).displayName
    }

    /// What the pane's icon starts from while its program reports status
    /// (`RexSessionState.programName`); nil for a plain shell.
    private static func program(of block: String, in state: State) -> String? {
        RexSessionState.program(title: state.titles[block], records: state.records[block] ?? [], label: state.labels[block])
    }

    private static func snapshot(_ state: State) -> RexSessionState {
        // Until a view has been read, the pane that was asked for is the only one known.
        let panes: [RexSessionState.Pane] = state.layout?.panes.map {
            .init(
                blockID: $0.blockID, name: name(of: $0.blockID, in: state), windowID: $0.windowID, windowName: $0.windowName,
                program: program(of: $0.blockID, in: state), records: state.records[$0.blockID] ?? []
            )
        } ?? [.init(
            blockID: state.requested, name: name(of: state.requested, in: state), program: program(of: state.requested, in: state),
            records: state.records[state.requested] ?? []
        )]
        return RexSessionState(
            panes: panes,
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
