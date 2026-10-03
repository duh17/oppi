import Foundation
import GhosttyVt
import Observation
import Network
import Synchronization

protocol SSHTerminalConnection: Sendable {
    func send(_ bytes: Data) async throws
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
    /// One-shot command on the same connection, outside the terminal's PTY.
    /// `input` becomes its stdin.
    func run(_ command: String, input: Data) async throws -> SSHExecResult
    /// One SSH round trip. Throwing means the connection is gone.
    func checkAlive() async throws
    func cancel() async
}

extension SSHPTYSession: SSHTerminalConnection {
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        // An upload over a slow link needs longer than an API call.
        try await run(command, input: input, maximumOutputBytes: 2 * 1024 * 1024,
                      timeout: input.count > 64 * 1024 ? .seconds(120) : .seconds(10))
    }
    func checkAlive() async throws { try await checkAlive(timeout: .seconds(8)) }
}

/// Bounded hand-off from the NIO event loop to the main actor.
///
/// Backpressure comes first: while at least `resumeBelow` bytes await the main
/// actor, the PTY stops reading (`flow`), SSH flow control stops the remote, and
/// the consumer resumes it once it has drained below the mark. Output therefore
/// slows down instead of failing. `limit` is only the fail-loud backstop for a
/// consumer that is stuck: the chunk that crosses it and everything after it are
/// refused with a visible reason, never hidden. Accepted events keep their order.
final class SSHTerminalEventQueue: Sendable {
    enum Item: Sendable, Equatable {
        case event(SSHPTYEvent)
        case overflow
    }

    static let defaultLimit = 4 * 1024 * 1024
    static let defaultResumeBelow = 256 * 1024
    /// Pass in `SSHPTYConfiguration.inboundFlow` so the session obeys this queue.
    let flow = SSHPTYInboundFlow()
    /// Signalled (coalesced) when items are waiting or the queue has ended.
    let wake: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let state = Mutex(State())
    private let limit: Int
    private let resumeBelow: Int

    private struct State {
        var items = [Item]()
        var queuedBytes = 0
        var peakQueuedBytes = 0
        var finished = false
    }

    init(limit: Int = SSHTerminalEventQueue.defaultLimit, resumeBelow: Int = SSHTerminalEventQueue.defaultResumeBelow) {
        self.limit = limit
        self.resumeBelow = resumeBelow
        (wake, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Most bytes ever waiting for the main actor.
    var peakQueuedBytes: Int { state.withLock { $0.peakQueuedBytes } }

    /// Called from the NIO event loop.
    func push(_ event: SSHPTYEvent) {
        let ended: Bool? = state.withLock { state in
            guard !state.finished else { return nil }
            if case .data(let bytes) = event {
                guard state.queuedBytes + bytes.count <= limit else {
                    state.finished = true
                    state.items.append(.overflow)
                    return true
                }
                state.queuedBytes += bytes.count
                state.peakQueuedBytes = max(state.peakQueuedBytes, state.queuedBytes)
                // Under the lock so a concurrent release cannot be overtaken by
                // a stale pause.
                if state.queuedBytes >= resumeBelow { flow.pause() }
            }
            if event == .closed { state.finished = true }
            state.items.append(.event(event))
            return event == .closed
        }
        guard let ended else { return }
        continuation.yield()
        if ended { continuation.finish() }
    }

    /// Stops accepting events, e.g. when the consumer was cancelled.
    func finish() {
        state.withLock { $0.finished = true }
        continuation.finish()
    }

    func drain() -> [Item] {
        state.withLock { state in
            defer { state.items = [] }
            return state.items
        }
    }

    /// The consumer has interpreted `bytes`. Reading resumes below the mark.
    func release(bytes: Int) {
        state.withLock { state in
            state.queuedBytes -= bytes
            if state.queuedBytes < resumeBelow { flow.resume() }
        }
    }
}

/// Composer attachments go to the host as files the agent can read by path.
/// They land in `$TMPDIR/oppi-ssh` (or `/tmp/oppi-ssh`), owner-only.
enum SSHTerminalUpload {
    static let maximumBytes = 32 * 1024 * 1024

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Attachments are limited to 32 MB."
            case .rejected(let message): message
            }
        }
    }

    /// Generated, never user-supplied, so it needs no shell quoting.
    static func fileName(extension ext: String, id: UUID = UUID()) -> String {
        let safe = String(ext.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.prefix(8))
        let stem = "oppi-" + id.uuidString.prefix(8).lowercased()
        return safe.isEmpty ? stem : "\(stem).\(safe)"
    }

    /// `sh -c` so the user's login shell (fish included) only sees one quoted word.
    static func command(fileName: String) -> String {
        "sh -c 'umask 077; d=\"${TMPDIR:-/tmp}\"; d=\"${d%/}/oppi-ssh\"; mkdir -p \"$d\" && cat > \"$d/\(fileName)\" && printf %s \"$d/\(fileName)\"'"
    }

    static func path(from result: SSHExecResult, fileName: String) throws -> String {
        let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitStatus == 0, path.hasPrefix("/"), path.hasSuffix("/" + fileName) else {
            let reason = String(decoding: result.errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.rejected(reason.isEmpty ? "The host did not save the attachment." : "The host did not save the attachment: \(reason.prefix(200))")
        }
        return path
    }
}

/// One generation of terminal IO. A reconnect creates a new owner, so neither
/// queued input nor delayed replies/resize can migrate to another connection.
@MainActor @Observable
final class SSHTerminalChannel {
    let engine: SSHTerminalEngine
    var modifierLatch = SSHTerminalModifierLatch()
    private(set) var connected = false
    private(set) var connecting = true
    /// EOF stops input and terminal replies. The channel stays open so a
    /// following exit status or signal can still become the disconnect reason.
    private(set) var inputClosed = false
    private(set) var reason = "Connecting…"
    private(set) var inputNotice = ""
    /// Display-only; published only when the remote sets a different title.
    private(set) var title = ""
    /// True while a network path change is being checked.
    private(set) var networkChanged = false

    /// A path change is a hint, not proof the SSH stream failed: one SSH round
    /// trip decides. A live connection clears the notice; a dead one closes
    /// with a reason and offers Reconnect. Input is never replayed.
    func watchNetwork() async {
        let monitor = NWPathMonitor()
        let (paths, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            continuation.yield("\(path.status):\(path.isExpensive):\(path.isConstrained):\(interfaces)")
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "oppi.ssh.path"))
        defer { monitor.cancel() }
        var previous: String?
        for await path in paths {
            if let previous, previous != path, connected { await recheckAfterNetworkChange() }
            previous = path
        }
    }

    func recheckAfterNetworkChange() async {
        guard connected, let connection else { return }
        networkChanged = true
        do {
            try await connection.checkAlive()
            networkChanged = false
        } catch {
            networkChanged = false
            if self.connection != nil { close(reason: "The connection did not survive the network change.") }
        }
    }
    private var connection: (any SSHTerminalConnection)?
    /// The startup command running instead of a shell, if any. Exit reasons
    /// name it so a finished `herdr` attach is not reported as a shell exit.
    private(set) var command: String?
    private var writable = true
    private var writabilityRevision = 0
    private var pending = [Data]()
    private var queuedBytes = 0
    private var pump: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    static let maximumQueuedBytes = 128 * 1024

    init() throws {
        weak var target: SSHTerminalChannel?
        engine = try SSHTerminalEngine { reply in target?.send(reply) }
        target = self
    }

    func opened(_ connection: any SSHTerminalConnection, command: String? = nil) {
        self.connection = connection
        self.command = command
        connected = true
        connecting = false
        reason = "Connected"
        resize(engine.geometry)
    }

    func event(_ event: SSHPTYEvent) {
        guard connected else { return }
        switch event {
        case .data(let bytes):
            interpret(bytes)
        case .writabilityChanged(let value):
            writabilityRevision &+= 1
            writable = value
            if value { startPump() }
        case .exitStatus(let status): close(reason: "\(exitSubject) exited with status \(status).")
        case .exitSignal(let signal): close(reason: "\(exitSubject) exited on signal \(signal).")
        case .eof: closeInput()
        case .closed: close(reason: "The SSH connection closed.")
        }
    }

    /// Interprets queued events in order until the session ends. Each wake
    /// drains everything waiting, so consecutive output chunks become one
    /// terminal write. A stuck consumer past the queue cap fails the session.
    func consume(_ queue: SSHTerminalEventQueue) async {
        for await _ in queue.wake {
            process(queue.drain(), releasingTo: queue)
            if !connected { break }
        }
        queue.finish()
        if connected { close(reason: "The SSH connection closed.") }
    }

    private func process(_ items: [SSHTerminalEventQueue.Item], releasingTo queue: SSHTerminalEventQueue) {
        var run = Data()
        var dataBytes = 0
        for item in items {
            switch item {
            case .event(.data(let bytes)):
                dataBytes += bytes.count
                run.append(bytes)
                continue
            case .event(let event):
                interpret(run)
                run.removeAll()
                self.event(event)
            case .overflow:
                interpret(run)
                run.removeAll()
                close(reason: "The terminal stopped consuming remote output. The connection was closed.")
            }
            if !connected { break }
        }
        interpret(run)
        queue.release(bytes: dataBytes)
    }

    private var exitSubject: String { command.map { "`\($0)`" } ?? "Shell" }

    /// Runs a structured side command on this terminal's connection.
    func run(_ command: String, input: Data = Data()) async throws -> SSHExecResult {
        guard connected, let connection else { throw SSHPTYSessionError.notConnected }
        return try await connection.run(command, input: input)
    }

    /// Saves `data` in a private temporary folder on the host and returns its
    /// path, so a prompt can point an agent at a photo or file from the phone.
    func upload(_ data: Data, fileExtension: String) async throws -> String {
        guard data.count <= SSHTerminalUpload.maximumBytes else { throw SSHTerminalUpload.Failure.tooLarge }
        let name = SSHTerminalUpload.fileName(extension: fileExtension)
        return try SSHTerminalUpload.path(from: try await run(SSHTerminalUpload.command(fileName: name), input: data),
                                          fileName: name)
    }

    private func interpret(_ bytes: Data) {
        guard connected, !bytes.isEmpty else { return }
        engine.receive(bytes)
        if engine.title != title { title = engine.title }
    }

    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        pending.removeAll()
        queuedBytes = 0
        engine.close()
        pump?.cancel()
        pump = nil
        reason = "The remote shell ended. Waiting for its exit status…"
    }

    func send(_ bytes: Data) {
        guard connected, connection != nil else {
            inputNotice = "Not sent — terminal is disconnected."
            return
        }
        guard !inputClosed else {
            inputNotice = "Not sent — the remote shell has ended."
            return
        }
        guard !bytes.isEmpty else { return }
        guard queuedBytes + bytes.count <= Self.maximumQueuedBytes else {
            inputNotice = "Not sent — input buffer is full."
            return
        }
        inputNotice = writable ? "" : "Waiting for the SSH channel…"
        pending.append(bytes)
        queuedBytes += bytes.count
        startPump()
    }

    func key(_ key: GhosttyKey, text: String = "", modifiers: GhosttyMods = 0) {
        guard connected, !inputClosed else { send(Data()); return }
        send(engine.key(key, text: text, modifiers: modifiers | modifierLatch.take()))
    }

    /// One write, so a chord's strokes arrive together and in order.
    func keys(_ strokes: [SSHTerminalKeyStroke]) {
        guard connected, !inputClosed else { send(Data()); return }
        guard !strokes.isEmpty else { return }
        let latched = modifierLatch.take()
        send(strokes.enumerated().reduce(into: Data()) { bytes, entry in
            let (index, stroke) = entry
            bytes.append(engine.key(stroke.key, text: stroke.text,
                                    modifiers: stroke.modifiers | (index == 0 ? latched : 0)))
        })
    }

    func mouse(_ input: SSHTerminalEngine.MouseInput, column: Int, row: Int) {
        guard connected, !inputClosed else { return }
        send(engine.mouse(input, column: column, row: row))
    }

    /// Composer send: the text as one paste, then Enter. The user wrote it in
    /// Oppi, so a newline needs no clipboard-style consent; bracketed paste
    /// keeps a multi-line prompt as one prompt in agent TUIs. Empty text is a
    /// bare Enter.
    func submit(_ text: String) throws {
        guard connected, !inputClosed else { send(Data()); throw SSHTerminalError.disconnected }
        var bytes = text.isEmpty ? Data() : try engine.paste(text, confirmed: true)
        bytes.append(engine.key(GHOSTTY_KEY_ENTER))
        send(bytes)
    }

    func paste(_ text: String, confirmed: Bool = false) throws {
        guard connected, !inputClosed else { send(Data()); throw SSHTerminalError.disconnected }
        send(try engine.paste(text, confirmed: confirmed))
    }

    func resize(_ geometry: SSHTerminalGeometry) {
        // Both local and remote grid changes share the same coalesced geometry.
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self else { return }
            self.engine.resize(geometry)
            guard self.connected, let connection = self.connection else { return }
            do {
                try await connection.resize(columns: geometry.columns, rows: geometry.rows,
                                            pixelWidth: geometry.pixelWidth, pixelHeight: geometry.pixelHeight)
            } catch {
                if !Task.isCancelled { self.close(reason: "Terminal resize failed: \(Self.message(error))") }
            }
        }
    }

    func close(reason: String) {
        connected = false
        connecting = false
        self.reason = reason
        pending.removeAll()
        queuedBytes = 0
        engine.close()
        pump?.cancel()
        pump = nil
        resizeTask?.cancel()
        resizeTask = nil
        if let connection { Task { await connection.cancel() } }
        connection = nil
    }

    private func startPump() {
        guard connected, writable, pump == nil, !pending.isEmpty, let connection else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            defer { self.pump = nil }
            while self.connected, self.writable, !self.pending.isEmpty, !Task.isCancelled {
                let bytes = self.pending.removeFirst()
                let writabilityAtSend = self.writabilityRevision
                // Count in-flight bytes too, so an await can't bypass the cap.
                do {
                    try await connection.send(bytes)
                    guard self.connected, !self.inputClosed else { return }
                    self.queuedBytes -= bytes.count
                } catch SSHPTYSessionError.notWritable {
                    guard self.connected, !self.inputClosed, !Task.isCancelled else { return }
                    self.pending.insert(bytes, at: 0)
                    // A rejection describes writability at the attempt, not
                    // after this await. A newer NIO event is authoritative.
                    if self.writabilityRevision == writabilityAtSend {
                        self.writable = false
                    }
                    if !self.writable { return }
                } catch {
                    if !Task.isCancelled { self.close(reason: "SSH write failed: \(Self.message(error))") }
                    return
                }
            }
            if self.pending.isEmpty { self.inputNotice = "" }
        }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? SSHPTYSessionError { return error.message }
        if let error = error as? SSHPreflightFailure {
            switch error {
            case .dialFailed(let reason):
                return "SSH host unreachable: \(reason). Check the hostname, port and that sshd is running."
            case .dialTimedOut:
                return "SSH connection timed out. Check the host, port and network route."
            default: return error.message
            }
        }
        return error.localizedDescription
    }
}
