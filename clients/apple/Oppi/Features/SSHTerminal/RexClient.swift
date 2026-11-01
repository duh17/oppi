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
    /// Why side commands cannot run, or nil on a host with SSH beside Rex.
    var sideCommandsUnavailable: String? { get }
}

extension RexTransport {
    var sideCommandsUnavailable: String? { nil }
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
/// one control connection attached to the session, and one data connection per
/// pane the screen keeps live.
///
/// A pane's data connection first opens on the first resize, so the snapshot
/// Rex starts the shown pane with is already at this screen's size. This client
/// takes the pane it shows (`session.own_block`, take), so that pane follows
/// the phone's size; a neighbour streams untaken, at the size its owner gave
/// it, until it is shown (Rex streams a pane to a client that does not own
/// it). A pane whose lane closes is handed back
/// (`session.disown_block`), and when the connection drops Rex hands the rest
/// back to the client in line, such as the Mac app. That client can take a
/// pane back meanwhile (the Mac app has taken the panes of a session whose
/// layout changed, after a new split) and size it for its own window, which the
/// program then draws for, while a resize from this client waits until it owns
/// the pane again. Rex announces each new owner (`block_owner_changed`): a pane
/// another client took is no longer `owned`, and while the page shows the
/// session (`setOnScreen`) the shown pane is taken back and sized again
/// (`reclaim`). Neighbours wait until they are shown; nothing is taken back off
/// the page. It never focuses anything: the host's own focus stays where it is.
///
/// Showing another pane (`show`) moves what typing and sizing go to, and takes
/// that pane (on a page that shows, `paneToReclaim`): the
/// pane's stream is already open when the screen keeps it live
/// (`keepLive` — the shown pane and its neighbours, `maximumLivePanes`), so its
/// engine already has its screen and nothing is reloaded. Lanes open and close
/// one at a time, so a fast double swipe ends on the last pane asked for, and
/// the stream of a pane whose lane closed is dropped by generation: it is never
/// fed to the grid and never ends the terminal. The pane switcher and minimap
/// follow `session.view`, read again at each `session_view_changed` (at most one
/// read at a time, again if another came meanwhile, an older answer dropped).
///
/// Typing goes to the pane as `com.superlogical.terminal.write`, one call at a
/// time (the channel waits for each), so keys keep their order. Side commands
/// (uploads, the Ghostty theme, keybindings) run on the same SSH connection as
/// for a shell, since the pane is on the same host.
final class RexSessionConnection: SSHTerminalConnection, Sendable {
    /// A screen that never sizes the terminal still gets its pane.
    static let firstResizeWait: Duration = .milliseconds(1500)
    /// The most panes one Rex screen keeps streaming: the pane it shows and its
    /// two neighbours in strip order. Each has an engine, a renderer's worth of
    /// screen, and its own data stream, so the number is the memory and battery
    /// budget of a swipe (`SSHTerminalPanePreview` draws the incoming one).
    static let maximumLivePanes = 3
    /// Takes back of one pane between two actions of this phone's user (a
    /// switch, the page showing, typing, a resize): a client that takes the
    /// pane again each time would otherwise trade it with this one forever,
    /// redrawing the program on both.
    static let maximumReclaims = 2

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

    /// One pane's data connection: its socket, the parser that splits its
    /// snapshot from its output, and the generation its events carry so a
    /// replaced stream's bytes are dropped.
    private struct Lane: Sendable {
        var stream: (any RexSocket)?
        /// The parser that splits this pane's snapshot from its output. Set when
        /// the lane is made, so a lane always has one.
        var parser: RexDataStream
        var generation: Int
        /// Its reader, pooled with the terminal's queue's backpressure.
        var flow: SSHPTYInboundFlow?
    }

    private struct State: Sendable {
        /// The pane asked for last: typing and sizing go here.
        var requested: String
        /// The panes the screen keeps streaming: the shown one and, while the
        /// screen shows this session, its neighbours (at most
        /// `maximumLivePanes`). Each has a lane; nothing else does.
        var live: Set<String> = []
        /// Panes this client has taken for size and not handed back. A live
        /// pane missing here is a neighbour it never took, or one another
        /// client took from it (`block_owner_changed`).
        var owned: Set<String> = []
        /// This client, as `session.attach` names it: the owner Rex announces
        /// when a take is this client's own.
        var me: String?
        /// The page shows this session and the app is active: only then is a
        /// pane another client took taken back (`paneToReclaim`).
        var onScreen = false
        /// Takes back per pane since this phone's user last acted
        /// (`userActed`), at most `maximumReclaims`.
        var reclaims: [String: Int] = [:]
        /// The size each owned pane was last given, so a switch does not
        /// size again a pane the screen just sized (the first pane, on the
        /// first layout).
        var sized: [String: Geometry] = [:]
        /// One lane per live pane, by block.
        var lanes: [String: Lane] = [:]
        /// Panes whose lane could not open (Rex refused it, its stream failed,
        /// or its snapshot was unreadable). A pane that leaves the window is
        /// forgotten here, so a way back tries again.
        var deadLanes: Set<String> = []
        /// How many times a pane's lane was opened since it was last shown,
        /// so a pane that keeps failing cannot spin.
        var attempts: [String: Int] = [:]
        var nextGeneration = 0
        /// Generations whose pane Rex closed. The socket's end follows the
        /// close frame (over the bridge, `nc` exits when Rex closes its
        /// socket): that end is the pane leaving, not the connection failing.
        var retired: Set<Int> = []
        /// Panes Rex closed (by event, by their stream, or by dropping out of
        /// the view). The layout held here is stale until the next view is
        /// read, so a pane in it is not a pane that is still there.
        var closedBlocks: Set<String> = []
        /// Sockets and readers whose lane is gone, released outside the lock.
        var graveyard: [(any RexSocket)?] = []
        var retiredFlows: [SSHPTYInboundFlow] = []
        /// The first resize came (or its wait ran out): data may open.
        var armed = false
        /// The lane loop is running.
        var switching = false
        var ended = false
        var geometry: Geometry?
        /// The pane whose stream last said HELLO: the one that was on screen
        /// before the switch now under way, which recovery goes back to.
        var lastServed: String?
        /// Panes whose program exited, with its exit status. Rex closes such a
        /// pane by default; until it does, the pane stays where it is.
        var exitCodes: [String: Int] = [:]
        /// When a pane's stream was asked for, until its snapshot came.
        var snapshotAsked: [String: ContinuousClock.Instant] = [:]

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

        /// The panes whose lanes should exist: the window, minus the panes Rex
        /// closed and the ones whose lane failed, never more than
        /// `RexSessionConnection.maximumLivePanes`, always including the pane
        /// on screen.
        var wantedLanes: Set<String> {
            var wanted = live.subtracting(closedBlocks).subtracting(deadLanes)
            if !closedBlocks.contains(requested) { wanted.insert(requested) }
            if let layout { wanted = wanted.filter { layout.contains($0) } }
            return capped(wanted)
        }

        /// Panes to open a lane for, the pane on screen first. A pane whose
        /// lane failed twice while it was in the window waits for the window to
        /// leave it and come back.
        var lanesToOpen: [String] {
            let wanted = wantedLanes
            return ordered(wanted).filter { lanes[$0] == nil && !deadLanes.contains($0) && (attempts[$0] ?? 0) < 2 }
        }

        /// Lanes to close: panes the window no longer keeps.
        var lanesToClose: [String] {
            let wanted = wantedLanes
            return lanes.keys.filter { !wanted.contains($0) }
        }

        /// The shown pane, when this client does not own it and should take
        /// it: another client took it, or it streamed untaken as a neighbour
        /// until it was shown. The page shows the session, the pane has a lane
        /// (one without takes it as it opens), and the takes since the user
        /// last acted are under the cap. A neighbour waits until it is shown.
        var paneToReclaim: String? {
            guard onScreen, lanes[requested] != nil, !owned.contains(requested), wantedLanes.contains(requested),
                  reclaims[requested, default: 0] < RexSessionConnection.maximumReclaims else { return nil }
            return requested
        }

        var laneWork: Bool {
            !lanesToOpen.isEmpty || !lanesToClose.isEmpty || paneToReclaim != nil
                || !owned.subtracting(wantedLanes).isEmpty
        }

        /// Forgets `block`'s lane, queuing its socket and its reader for release
        /// outside the lock (`reap`).
        mutating func dropLane(_ block: String) {
            graveyard.append(lanes[block]?.stream)
            lanes[block]?.flow.map { retiredFlows.append($0) }
            lanes[block] = nil
            reclaims[block] = nil
        }

        /// `blocks` in strip order, nearest the pane on screen first.
        func ordered(_ blocks: Set<String>) -> [String] {
            let order = layout?.panes.map(\.blockID) ?? []
            let start = order.firstIndex(of: requested)
            func distance(_ block: String) -> Int {
                guard let start, let at = order.firstIndex(of: block) else { return Int.max }
                return abs(at - start)
            }
            func position(_ block: String) -> Int { order.firstIndex(of: block) ?? Int.max }
            return blocks.sorted { left, right in
                (distance(left), position(left)) < (distance(right), position(right))
            }
        }

        /// `blocks` kept to `RexSessionConnection.maximumLivePanes`, the pane on
        /// screen and the ones nearest it.
        func capped(_ blocks: Set<String>) -> Set<String> {
            guard blocks.count > RexSessionConnection.maximumLivePanes else { return blocks }
            var kept: Set<String> = [requested]
            for block in ordered(blocks) where kept.count < RexSessionConnection.maximumLivePanes { kept.insert(block) }
            return kept
        }
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
            // Read apart: a view this client cannot read must not lose who it is.
            struct Attached: Decodable { let client_id: String? }
            struct Viewed: Decodable { let view: RexView? }
            let me = (try? JSONDecoder().decode(Attached.self, from: attached))?.client_id
            connection.core.withLock { $0.me = me }
            if let view = (try? JSONDecoder().decode(Viewed.self, from: attached))?.view {
                connection.core.withLock { _ = connection.apply(view: view, to: &$0) }
            }
            // Owned before the take is answered: another client's take Rex
            // announces meanwhile must find it (`ownerChanged`).
            connection.core.withLock { _ = $0.owned.insert(target.blockID) }
            _ = try await control.call("session.own_block", [
                "session_id": target.sessionID, "block_ids": [target.blockID], "mode": "take",
            ])
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
            state.live.insert(blockID)
            // A pane asked for gets its stream again, even if one failed before.
            state.deadLanes.remove(blockID)
            state.attempts[blockID] = nil
            // The user chose it: another client's take is taken back again.
            state.reclaims[blockID] = nil
            state.live = state.capped(state.live)
            publish(state)
            return (true, startSwitching(&state))
        }
        if start { Task { await runLanes() } }
        return accepted
    }

    /// The screen says which panes to keep streaming: the shown one and its
    /// neighbours (`RexSessionModel.keepLivePanes`), or the shown one alone when
    /// the screen goes away. Idempotent, so the screen can call it as often as
    /// its state changes.
    func keepLive(_ blocks: Set<String>) {
        let start = core.withLock { state -> Bool in
            guard !state.ended else { return false }
            var next = state.capped(blocks.union([state.requested]))
            if let layout = state.layout { next = next.filter { layout.contains($0) } }
            guard next != state.live else { return false }
            // A pane that leaves the window is forgotten, so a way back to it
            // tries its stream again.
            for block in state.live.subtracting(next) {
                state.deadLanes.remove(block)
                state.attempts[block] = nil
            }
            state.live = next
            return startSwitching(&state)
        }
        if start { Task { await runLanes() } }
    }

    /// The page shows this session with the app active, or stops doing so.
    /// Showing it again is the user's action: the shown pane, if another
    /// client took it meanwhile, is taken back.
    func setOnScreen(_ onScreen: Bool) {
        let start = core.withLock { state -> Bool in
            guard state.onScreen != onScreen else { return false }
            state.onScreen = onScreen
            guard onScreen else { return false }
            state.reclaims[state.requested] = nil
            return startSwitching(&state)
        }
        if start { Task { await runLanes() } }
    }

    /// The user typed or the screen resized: the shown pane may be taken back
    /// again (`maximumReclaims`).
    private func userActed() {
        let start = core.withLock { state -> Bool in
            guard state.reclaims[state.requested] != nil else { return false }
            state.reclaims[state.requested] = nil
            return startSwitching(&state)
        }
        if start { Task { await runLanes() } }
    }

    /// A pane's lane has failed: drop it and let the screen fall back to that
    /// pane's card if a swipe reaches it.
    func dropLane(_ block: String) {
        let start = core.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.dropLane(block)
            state.deadLanes.insert(block)
            return startSwitching(&state)
        }
        reap()
        if start { Task { await runLanes() } }
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
        userActed()
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
        // The shown pane and the panes this phone still owns are this
        // screen's size; a neighbour it never took keeps its owner's. Rex lays
        // out a pane at the size its owner asks for, and holds this one's for
        // a pane it does not own until it does.
        let (targets, shown) = core.withLock { state -> ([String], String) in
            state.geometry = geometry
            return ([state.requested] + state.owned.subtracting([state.requested]).sorted(), state.requested)
        }
        // After the size is set, so a take back it starts sends this one.
        userActed()
        for target in targets {
            do {
                _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: target))
                core.withLock { state in
                    // A newer size went out meanwhile: this one is not the pane's.
                    if state.owned.contains(target), state.geometry == geometry { state.sized[target] = geometry }
                }
            } catch RexClientError.refused {
                // A pane that closed meanwhile, as for a write.
            } catch {
                // The pane on screen failing is this terminal failing, as it
                // always was; a neighbour only loses its lane.
                guard target == shown else { dropLane(target); continue }
                throw error
            }
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

    var sideCommandsUnavailable: String? { transport.sideCommandsUnavailable }

    func close() {
        let streams = endLanes()
        updateSink.finish()
        streams.forEach { $0?.close() }
        transport.close()
    }

    func cancel() async {
        let streams = endLanes()
        updateSink.finish()
        streams.forEach { $0?.close() }
        await transport.cancel()
    }

    /// The connection is over: every pane's stream ends with it. Nothing opens
    /// another (the loop's `ended` check), and a stream that ends anyway is not
    /// the pane's.
    private func endLanes() -> [(any RexSocket)?] {
        core.withLock { state in
            state.ended = true
            state.nextGeneration += 1
            for block in Array(state.lanes.keys) { state.dropLane(block) }
            state.deadLanes = []
            defer { state.graveyard = [] }
            return state.graveyard
        }
    }

    // MARK: - Switching panes

    private func blockCall(_ args: [String: Any], block: String? = nil) -> [String: Any] {
        let target = block ?? core.withLock { $0.requested }
        return ["session_id": sessionID, "block_id": target, "args": args]
    }

    /// Data may open: the first time, for the panes the screen keeps live;
    /// after that, again for whatever changed since.
    private func arm() {
        let start = core.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.armed = true
            return startSwitching(&state)
        }
        if start { Task { await runLanes() } }
    }

    /// Decides, under the lock, whether the caller starts the lane loop: data
    /// is allowed, the set of lanes it wants is not the set it has, and no
    /// loop is running.
    private func startSwitching(_ state: inout State) -> Bool {
        guard state.armed, !state.ended, !state.switching, state.laneWork else { return false }
        state.switching = true
        return true
    }

    /// Opens and closes lanes until they are exactly the panes the screen keeps
    /// live: one open at a time, then the panes that dropped out of the window
    /// handed back. A pane taken for a lane that then goes quiet is handed back
    /// here too, so nothing stays owned at this screen's size.
    private func runLanes() async {
        while true {
            enum Work {
                case done
                case open(String)
                case close([String])
                case reclaim(String)
                case handBack([String])
            }
            let work = core.withLock { state -> Work in
                guard !state.ended, state.armed else {
                    state.switching = false
                    return .done
                }
                let extra = state.lanesToClose
                if !extra.isEmpty { return .close(extra) }
                if let taken = state.paneToReclaim {
                    // Marked before the call, so this pass cannot pick it again.
                    state.owned.insert(taken)
                    state.sized[taken] = nil
                    state.reclaims[taken, default: 0] += 1
                    return .reclaim(taken)
                }
                if let next = state.lanesToOpen.first { return .open(next) }
                // A pane taken for size that no lane carries goes back.
                let behind = state.owned.subtracting(state.wantedLanes)
                if !behind.isEmpty {
                    state.owned = behind.isEmpty ? state.owned : state.owned.subtracting(behind)
                    for block in behind { state.sized[block] = nil }
                    return .handBack(Array(behind))
                }
                state.switching = false
                return .done
            }
            switch work {
            case .done:
                reap()
                return
            case .handBack(let behind):
                reap()
                // Best effort: a pane that closed has nothing to give back.
                _ = try? await control.call("session.disown_block", ["session_id": sessionID, "block_ids": behind])
            case .close(let blocks):
                core.withLock { state in
                    for block in blocks { state.dropLane(block) }
                }
                reap()
                // Best effort, as a hand-back: the pane may be gone already.
                _ = try? await control.call("session.disown_block", ["session_id": sessionID, "block_ids": blocks])
                core.withLock { state in for block in blocks { state.owned.remove(block); state.sized[block] = nil } }
            case .reclaim(let block):
                await reclaim(block)
            case .open(let block):
                do {
                    try await openLane(block)
                } catch {
                    guard recover(from: error, opening: block) else { return }
                }
                reap()
            }
        }
    }

    /// `block`'s lane could not open. Rex refusing it means the pane closed
    /// before this terminal heard; for the pane on screen that moves to its
    /// neighbour, as it always has, and anything else is the connection
    /// failing. A pane off screen only loses its lane.
    private func recover(from error: any Error, opening block: String) -> Bool {
        enum Recovery { case carryOn, ended, failed }
        let recovery = core.withLock { state -> Recovery in
            state.dropLane(block)
            state.deadLanes.insert(block)
            // A pane off screen only loses its lane, whatever went wrong: the
            // terminal goes on showing the pane it has.
            guard state.requested == block else { return .carryOn }
            guard case RexClientError.refused = error, !state.ended else { return .failed }
            state.closedBlocks.insert(block)
            // Back to the pane that was on screen if it is still there, else the
            // nearest one by strip order, preferring a pane whose lane is open
            // (the best evidence Rex still has it); with none left there is
            // nothing to show. Lanes and ownership are about streams: a lane that
            // closed because the window moved on is not a pane that went away.
            let order = state.layout?.panes.map(\.blockID) ?? []
            let alive = Set(order).subtracting(state.closedBlocks)
            let streaming = alive.intersection(state.lanes.keys)
            let before = state.lastServed.flatMap { alive.contains($0) ? $0 : nil }
            let next = before ?? state.ordered(streaming).first ?? state.ordered(alive).first
            guard let next else { return .ended }
            state.requested = next
            state.live.insert(next)
            state.live = state.capped(state.live)
            publish(state)
            return .carryOn
        }
        switch recovery {
        case .carryOn:
            return true
        case .ended:
            core.withLock { $0.switching = false }
            end("The pane closed in Rex.")
            return false
        case .failed:
            core.withLock { $0.switching = false }
            end(error.localizedDescription)
            return false
        }
    }

    /// Takes `block` for size if it is the shown pane on a page that shows
    /// (and this client has not taken it), sizes a pane this client owns to the screen (unless it
    /// already has this size), and opens a data connection for it. A
    /// neighbour streams untaken, at its owner's size, until it is shown: Rex
    /// streams a pane to a client that does not own it. The connection's
    /// channel, its bridge, and its WebSocket upgrade need no ticket, so they
    /// open while `data.connect` issues one; HELLO waits for it. Another
    /// pane's lane is untouched: a switch shows a pane that is already
    /// streaming. A request overtaken while this waits on Rex closes the new
    /// connection before it says HELLO.
    private func openLane(_ block: String) async throws {
        func wanted() -> Bool { core.withLock { !$0.ended && $0.wantedLanes.contains(block) } }
        /// This screen's size, for a pane this client owns that does not have it yet.
        func unsized() -> Geometry? {
            core.withLock { state in
                guard state.owned.contains(block), let geometry = state.geometry, state.sized[block] != geometry else { return nil }
                return geometry
            }
        }
        // Off the page nothing is taken, not even the shown pane (one a pane
        // closing in Rex moved to): `paneToReclaim` takes it when the page returns.
        let take = core.withLock { state -> Bool in
            guard state.onScreen, state.requested == block, !state.owned.contains(block) else { return false }
            // Owned before the take is answered: another client's take Rex
            // announces meanwhile must find it (`ownerChanged`).
            state.owned.insert(block)
            return true
        }
        if take {
            do {
                _ = try await control.call("session.own_block", [
                    "session_id": sessionID, "block_ids": [block], "mode": "take",
                ])
            } catch {
                core.withLock { _ = $0.owned.remove(block) }
                throw error
            }
        }
        // The pane takes this screen's size before its snapshot is made.
        if let geometry = unsized() {
            _ = try await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: block))
            core.withLock { state in
                if state.owned.contains(block), state.geometry == geometry { state.sized[block] = geometry }
            }
        }
        guard wanted() else { return }
        core.withLock { state in
            state.snapshotAsked[block] = .now
            state.attempts[block, default: 0] += 1
        }
        let ticketAnswer = Task { [control, sessionID] in
            try await control.call("data.connect", [
                "session_id": sessionID, "block_id": block,
                "data_ref_id": "terminal", "subprotocol": RexEndpoint.data.subprotocol,
            ])
        }
        let parser = RexDataStream()
        let flow = queue.makeFlow()
        let generation = core.withLock { state -> Int in
            state.nextGeneration += 1
            state.lanes[block] = Lane(stream: nil, parser: parser, generation: state.nextGeneration, flow: flow)
            return state.nextGeneration
        }
        /// This connection will never say HELLO: its end is not the pane's.
        func abandon(_ stream: (any RexSocket)?) {
            core.withLock { state in
                guard state.lanes[block]?.generation == generation else { return }
                state.retired.insert(generation)
                state.dropLane(block)
            }
            stream?.close()
        }
        // The socket opens and upgrades while the ticket is issued.
        let stream: any RexSocket
        do {
            stream = try await transport.openData(inboundFlow: flow) { [weak self] event in
                self?.receiveData(event, block: block, generation: generation)
            }
        } catch {
            ticketAnswer.cancel()
            core.withLock { state in
                guard state.lanes[block]?.generation == generation else { return }
                state.dropLane(block)
            }
            reap()
            throw error
        }
        let kept = core.withLock { state -> Bool in
            guard !state.ended, state.lanes[block]?.generation == generation else { return false }
            state.lanes[block]?.stream = stream
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
            guard !state.ended, state.lanes[block]?.generation == generation else { return false }
            state.deadLanes.remove(block)
            return true
        }
        guard current else { return }
        try await stream.send(RexDataStream.hello(ticket: bytes))
        // A rotation or keyboard resize that landed while this lane opened was
        // not for a lane yet: give the pane the size the screen has now.
        if let geometry = unsized() {
            _ = try? await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: block))
            core.withLock { state in
                if state.owned.contains(block), state.geometry == geometry { state.sized[block] = geometry }
            }
        }
    }

    /// Another client took `block` and sized it for its own window: take it
    /// again and give it this screen's size. Best effort, as a hand-back: a
    /// pane that closed meanwhile has nothing to take, and its lane hears so.
    private func reclaim(_ block: String) async {
        _ = try? await control.call("session.own_block", [
            "session_id": sessionID, "block_ids": [block], "mode": "take",
        ])
        // A resize that landed since the pane was marked owned sized it already.
        guard let geometry = core.withLock({ state in state.sized[block] == state.geometry ? nil : state.geometry }) else { return }
        _ = try? await control.call("com.superlogical.terminal.resize", blockCall(geometry.arguments, block: block))
        core.withLock { state in
            // A newer size went out meanwhile: this one is not the pane's.
            if state.owned.contains(block), state.geometry == geometry { state.sized[block] = geometry }
        }
    }

    /// Rex announced `block`'s owner. Another client (or none) owning a pane
    /// this one owned means its resizes wait and the program draws for that
    /// client's window: the pane is no longer `owned`, and the lane loop takes
    /// it back if it is the shown pane on a page that shows (`paneToReclaim`).
    /// This client's own takes are announced too: the pane is its own again
    /// (a take another client made in between may have been announced first),
    /// unless it has been handed back since.
    private func ownerChanged(_ block: String, owner: String?) {
        let start = core.withLock { state -> Bool in
            guard !state.ended, let me = state.me else { return false }
            if owner == me {
                if state.wantedLanes.contains(block) { state.owned.insert(block) }
                return false
            }
            guard state.owned.remove(block) != nil else { return false }
            state.sized[block] = nil
            return startSwitching(&state)
        }
        if start { Task { await runLanes() } }
    }

    /// Closes the sockets of lanes that are gone, outside the lock: a socket's
    /// close can call back into this connection.
    private func reap() {
        let (sockets, flows) = core.withLock { state -> ([(any RexSocket)?], [SSHPTYInboundFlow]) in
            defer {
                state.graveyard = []
                state.retiredFlows = []
            }
            return (state.graveyard, state.retiredFlows)
        }
        for socket in sockets { socket?.close() }
        for flow in flows { queue.retire(flow) }
    }

    /// A lane's events, on the socket's thread and in order, so a pane's
    /// snapshot and output reach the queue in the order Rex sent them. Events
    /// of a stream that was replaced (`generation`) are dropped.
    private func receiveData(_ event: RexSocketEvent, block: String, generation mine: Int) {
        switch event {
        case .message(let message):
            let outputs = core.withLock { state -> [RexDataStream.Output] in
                guard !state.ended, var lane = state.lanes[block], lane.generation == mine else { return [] }
                var parser = lane.parser
                let outputs = parser.receive(message)
                lane.parser = parser
                state.lanes[block] = lane
                return outputs
            }
            for output in outputs {
                switch output {
                case .snapshot(let snapshot):
                    // The screen is up (READY); its history follows.
                    if let asked = core.withLock({ $0.snapshotAsked.removeValue(forKey: block) }) {
                        let elapsed = ContinuousClock.now - asked
                        RexRouteLog.snapshot(route, milliseconds: Int(elapsed / .milliseconds(1)), bytes: snapshot.count)
                    }
                    core.withLock { state in
                        // It drew on screen: this is the pane a recovery goes back
                        // to. A neighbour's snapshot is not.
                        if block == state.requested, !state.closedBlocks.contains(block) { state.lastServed = block }
                    }
                    queue.pushSnapshot(snapshot, block: block)
                case .snapshotRecords(let records): queue.pushSnapshotRecords(records, block: block)
                case .output(let bytes): queue.pushData(bytes, block: block)
                case .exited(let code): core.withLock { $0.exitCodes[block] = code }
                case .paneClosed:
                    // The socket's end follows this frame; it is not a failure.
                    core.withLock { _ = $0.retired.insert(mine) }
                    closed(block, reason: "The pane closed in Rex.")
                case .ended(let reason):
                    laneEnded(block, generation: mine, reason: reason)
                }
            }
        case .ended(let error):
            let current = core.withLock { !$0.ended && $0.lanes[block]?.generation == mine && !$0.retired.contains(mine) }
            if current { laneEnded(block, generation: mine, reason: error.localizedDescription) }
        case .writable:
            break
        }
    }

    /// One lane's stream is over. The pane on screen ends the terminal with the
    /// reason, as it always has; a pane off screen only loses its lane, and the
    /// screen falls back to that pane's card if a swipe reaches it.
    private func laneEnded(_ block: String, generation mine: Int, reason: String) {
        let onScreen = core.withLock { state -> Bool in
            guard !state.ended, state.lanes[block]?.generation == mine else { return false }
            state.dropLane(block)
            state.deadLanes.insert(block)
            return state.requested == block
        }
        reap()
        guard onScreen else { return }
        end(reason)
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
            // Its lane goes with it; the socket closes outside the lock.
            state.dropLane(block)
            state.deadLanes.insert(block)
            state.live.remove(block)
            state.owned.remove(block)
            state.sized[block] = nil
            return (!state.ended && state.requested == block, surviving.subtracting(state.closedBlocks))
        }
        reap()
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
        case .ownerChanged(_, let block, let owner):
            ownerChanged(block, owner: owner)
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
            live: Set(state.lanes.keys),
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
