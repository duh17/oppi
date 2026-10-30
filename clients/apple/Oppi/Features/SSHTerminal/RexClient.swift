import Foundation
import Synchronization

/// The Rex pane a terminal shows: a block in a session on the host's Rex
/// server, and what to call it.
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
    /// `$XDG_RUNTIME_DIR/rex` or `~/.local/state/rex/run` elsewhere. Exit 4, as
    /// the CLI does with autostart off, when no Rex server is listening; a host
    /// without `nc` exits 127.
    static let command = SSHTerminalRemoteShell.word(
        "for s in \"$HOME/Library/Application Support/rex/server.sock\" "
            + "\"${XDG_RUNTIME_DIR:-/nonexistent}/rex/server.sock\" \"$HOME/.local/state/rex/run/server.sock\"; do "
            + "[ -S \"$s\" ] && exec nc -U \"$s\"; done; exit 4"
    )

    static func failure(exitStatus: Int?) -> RexClientError {
        switch exitStatus {
        case 4: .notRunning
        case 127: .bridgeMissing
        default: .connectionClosed
        }
    }
}

enum RexClientError: Error, Equatable, LocalizedError {
    case notRunning
    case bridgeMissing
    case connectionClosed
    case timedOut
    /// The server answered a request with an error.
    case refused(code: String, message: String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Rex is not running on this host."
        case .bridgeMissing: "The host has no nc command to reach Rex's socket."
        case .connectionClosed: "The connection to Rex closed."
        case .timedOut: "Rex did not answer in time."
        case .refused(_, let message): "Rex refused: \(message)"
        case .unreadable(let detail): "Rex sent something Oppi cannot read: \(detail)"
        }
    }
}

/// Rex's control connection (`/api/control`, `rex.control.v1`) over a byte
/// pipe: one hello, then JSON requests matched to their responses by id. A
/// single pane needs no events, so they are skipped. Pings are answered.
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
            default:
                break // Events: a single pane does not follow them.
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
        /// The stream is over, and why. Nothing follows it.
        case ended(String)
    }

    private var codec: RexWebSocketCodec
    private let ticket: Data
    private var terminal: RexTerminalStream?
    private var over = false

    init(ticket: Data, key: String = RexWebSocketCodec.makeKey()) {
        codec = RexWebSocketCodec(subprotocol: RexPaneConnection.dataSubprotocol, key: key)
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
            if code == 4000 { return [.ended("The pane closed in Rex.")] }
            return [.ended(reason.isEmpty ? "Rex ended the pane's stream." : "Rex ended the pane's stream: \(reason).")]
        case .text:
            return []
        }
    }
}

/// One Rex pane shown as a terminal, over the SSH connection to its host.
///
/// The connection's main channel is the control connection; the pane's output
/// comes on a second channel, the data connection, which opens on the first
/// resize so the snapshot Rex starts it with is already at this screen's size.
/// This client owns the pane while it shows it (`session.own_block`, take), so
/// the pane follows the phone's size; when the connection drops Rex hands it
/// back to the client in line, such as the Mac app.
///
/// Typing goes to the pane as `com.superlogical.terminal.write`, one call at a
/// time (the channel waits for each), so keys keep their order. Side commands
/// (uploads, the Ghostty theme, keybindings) run on the same SSH connection as
/// for a shell, since the pane is on the same host.
final class RexPaneConnection: SSHTerminalConnection, Sendable {
    static let dataSubprotocol = "rex.data.terminal.v1"
    /// A screen that never sizes the terminal still gets its pane.
    static let firstResizeWait: Duration = .milliseconds(1500)

    private struct DataState {
        var started = false
        var stream: SSHExecStream?
        var parser: RexDataStream?
        var exitStatus: Int?
        var ended = false
    }

    private let session: SSHPTYSession
    private let control: RexControl
    private let target: RexPaneTarget
    private let queue: SSHTerminalEventQueue
    private let data = Mutex(DataState())

    private init(session: SSHPTYSession, control: RexControl, target: RexPaneTarget, queue: SSHTerminalEventQueue) {
        self.session = session
        self.control = control
        self.target = target
        self.queue = queue
    }

    /// Says hello on the control connection already running on `session`,
    /// attaches to the pane's session, and takes the pane. Cancelling it
    /// closes the connection, so a background cancel leaves nothing open.
    static func open(
        session: SSHPTYSession,
        control: RexControl,
        target: RexPaneTarget,
        queue: SSHTerminalEventQueue
    ) async throws -> RexPaneConnection {
        try await withTaskCancellationHandler {
            control.attach { try await session.send($0) }
            try await control.open()
            _ = try await control.call("session.attach", ["session_id": target.sessionID])
            _ = try await control.call("session.own_block", [
                "session_id": target.sessionID, "block_ids": [target.blockID], "mode": "take",
            ])
            try Task.checkCancellation()
            let pane = RexPaneConnection(session: session, control: control, target: target, queue: queue)
            control.onEnd { [weak pane] error in pane?.end(error.localizedDescription) }
            Task { [weak pane] in
                try? await Task.sleep(for: firstResizeWait)
                await pane?.startData()
            }
            return pane
        } onCancel: {
            session.close()
        }
    }

    func send(_ bytes: Data) async throws {
        _ = try await control.call("com.superlogical.terminal.write", blockCall([
            // Keys, pastes, and SGR mouse reports are UTF-8; only legacy X10
            // mouse coordinates past column 95 are not, and they arrive mangled.
            "data": String(decoding: bytes, as: UTF8.self),
        ]))
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        var args: [String: Any] = ["columns": columns, "rows": rows]
        if pixelWidth >= columns, pixelHeight >= rows {
            args["cell_width_px"] = pixelWidth / columns
            args["cell_height_px"] = pixelHeight / rows
        }
        _ = try await control.call("com.superlogical.terminal.resize", blockCall(args))
        await startData()
    }

    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        try await (session as any SSHTerminalConnection).run(command, input: input)
    }

    func checkAlive() async throws { try await session.checkAlive(timeout: .seconds(8)) }

    func close() {
        data.withLock { $0.ended = true }
        session.close()
    }

    func cancel() async {
        data.withLock { $0.ended = true }
        await session.cancel()
    }

    private func blockCall(_ args: [String: Any]) -> [String: Any] {
        ["session_id": target.sessionID, "block_id": target.blockID, "args": args]
    }

    /// Opens the pane's data connection, once.
    private func startData() async {
        let first = data.withLock { state -> Bool in
            guard !state.started, !state.ended else { return false }
            state.started = true
            return true
        }
        guard first else { return }
        do {
            let answer = try await control.call("data.connect", [
                "session_id": target.sessionID, "block_id": target.blockID,
                "data_ref_id": "terminal", "subprotocol": Self.dataSubprotocol,
            ])
            struct Ticket: Decodable { let ticket: String }
            guard let ticket = try? JSONDecoder().decode(Ticket.self, from: answer),
                  let bytes = Self.base64URL(ticket.ticket), bytes.count == 16 else {
                throw RexClientError.unreadable("a data ticket")
            }
            let parser = RexDataStream(ticket: bytes)
            data.withLock { $0.parser = parser }
            let stream = try await session.openStream(command: RexBridge.command, inboundFlow: queue.flow) { [weak self] event in
                self?.receiveData(event)
            }
            data.withLock { $0.stream = stream }
            try await stream.send(parser.upgradeRequest)
        } catch {
            end(error.localizedDescription)
        }
    }

    /// The data connection's events, on the SSH event loop and in order, so
    /// the snapshot and output reach the queue in the order Rex sent them.
    /// EOF comes before the bridge's exit status; `.closed` follows both.
    private func receiveData(_ event: SSHPTYEvent) {
        switch event {
        case .data(let bytes):
            let (outputs, stream) = data.withLock { state -> ([RexDataStream.Output], SSHExecStream?) in
                guard !state.ended, var parser = state.parser else { return ([], nil) }
                let outputs = parser.receive(bytes)
                state.parser = parser
                return (outputs, state.stream)
            }
            for output in outputs {
                switch output {
                case .send(let frame):
                    Task { [weak self] in
                        do { try await stream?.send(frame) } catch { self?.end(error.localizedDescription) }
                    }
                case .snapshot(let snapshot): queue.pushSnapshot(snapshot)
                case .output(let bytes): queue.push(.data(bytes))
                case .exited(let code): end("\(target.label) exited with status \(code).")
                case .ended(let reason): end(reason)
                }
            }
        case .exitStatus(let status):
            data.withLock { $0.exitStatus = status }
        case .closed:
            end(RexBridge.failure(exitStatus: data.withLock { $0.exitStatus }).localizedDescription)
        case .eof, .exitSignal, .writabilityChanged:
            break
        }
    }

    private func end(_ reason: String) {
        let first = data.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.ended = true
            return true
        }
        guard first else { return }
        queue.end(reason)
    }

    /// Rex writes tickets as base64url without padding.
    static func base64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
