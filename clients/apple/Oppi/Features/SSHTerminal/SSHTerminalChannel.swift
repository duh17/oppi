import Foundation
import GhosttyVt
import Observation
import Network
import Synchronization
import UIKit
import UniformTypeIdentifiers

protocol SSHTerminalConnection: Sendable {
    func send(_ bytes: Data) async throws
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
    /// One-shot command on the same connection, outside the terminal's PTY.
    /// `input` becomes its stdin.
    func run(_ command: String, input: Data) async throws -> SSHExecResult
    /// A long-lived command beside the terminal, no PTY: its output streams to
    /// `sink` as it arrives, and `SSHExecStream.send` writes its stdin. The
    /// stream ends with the command, `close()`, or the connection.
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream
    /// One SSH round trip. Throwing means the connection is gone.
    func checkAlive() async throws
    /// Submits the close to the connection and returns without waiting. It
    /// is the only close that is on the wire when a caller cannot await, such
    /// as an iOS background-task expiration handler.
    func close()
    /// `close()`, then waits until the connection is closed.
    func cancel() async
    /// Why this connection has no side commands, or nil when it has them: a
    /// Rex reached over Tailscale alone has no SSH beside it, so uploads, the
    /// host's Ghostty colors, keybinding files, and Herdr are not there.
    var sideCommandsUnavailable: String? { get }
}

extension SSHTerminalConnection {
    var sideCommandsUnavailable: String? { nil }
}

/// A side command asked of a terminal that has none (`sideCommandsUnavailable`):
/// it fails at once with the reason, so nothing waits on it.
struct SSHTerminalSideCommandsUnavailable: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

extension SSHPTYSession: SSHTerminalConnection {
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        // An upload over a slow link needs longer than an API call.
        try await run(command, input: input, maximumOutputBytes: 2 * 1024 * 1024,
                      timeout: input.count > 64 * 1024 ? .seconds(120) : .seconds(10))
    }
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        try await openStream(command: command, inboundFlow: nil, sink: sink)
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
        /// The renderable part of a Ghostty snapshot to restore before the
        /// output after it (a Rex pane), with the block it is of: every record
        /// through READY.
        case snapshot(Data, block: String?)
        /// Whole records of that snapshot after READY (older history, image
        /// pixels), through FINISH, with the block they are of.
        case snapshotRecords(Data, block: String?)
        /// The connection ended for a reason its transport names (a Rex pane).
        case ended(String)
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

    /// Called from the NIO event loop, in order with `push`.
    func pushSnapshot(_ snapshot: Data, block: String? = nil) {
        append(.snapshot(snapshot, block: block))
    }

    /// Called from the NIO event loop, in order with `push`.
    func pushSnapshotRecords(_ records: Data, block: String? = nil) {
        append(.snapshotRecords(records, block: block))
    }

    private func append(_ item: Item) {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            state.items.append(item)
            return true
        }
        if accepted { continuation.yield() }
    }

    /// Ends the queue with `reason` after everything queued before it.
    func end(_ reason: String) {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            state.items.append(.ended(reason))
            return true
        }
        guard accepted else { return }
        continuation.yield()
        continuation.finish()
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
/// They land in `$TMPDIR/oppi-ssh-<uid>`, or `/tmp/oppi-ssh-<uid>` when the
/// host sets no `TMPDIR`, owner-only.
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
    ///
    /// Uploads stay in the temp directory the OS cleans: `$TMPDIR`, which
    /// macOS sshd points at the user's own private folder, or `/tmp` on hosts
    /// that set none. The folder is named for the user's uid, so users do not
    /// share one. It is refused unless it is a real directory owned by this
    /// user: a symlink, or a folder another user owns, could be swapped between
    /// this check and the agent reading the file. The folder is owner-only (700)
    /// either way. Another local user can still pre-create the name on a shared
    /// `/tmp` to block uploads; they then fail closed with the reason.
    static func command(fileName: String) -> String {
        let script = "umask 077; "
            + "if [ -n \"${TMPDIR:-}\" ]; then d=\"${TMPDIR%/}/oppi-ssh-$(id -u)\"; else d=\"/tmp/oppi-ssh-$(id -u)\"; fi; "
            + "if [ -L \"$d\" ]; then echo \"refusing a symlinked upload folder: $d\" >&2; exit 1; fi; "
            + "if [ -e \"$d\" ] && [ ! -d \"$d\" ]; then echo \"refusing an upload folder that is not a directory: $d\" >&2; exit 1; fi; "
            + "mkdir -p \"$d\" || exit 1; "
            + "set -- $(ls -lnd \"$d\") && [ \"$3\" = \"$(id -u)\" ] "
            + "|| { echo \"refusing an upload folder owned by another user: $d\" >&2; exit 1; }; "
            + "chmod 700 \"$d\" || { echo \"cannot secure the upload folder: $d\" >&2; exit 1; }; "
            + "cat > \"$d/\(fileName)\" || exit 1; "
            + "printf %s \"$d/\(fileName)\""
        return "sh -c '\(script)'"
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
    /// OSC 7501 program status records reported in this terminal.
    var programStatus: SSHTerminalProgramStatusStore { engine.programStatus }
    /// OSC 9;4 progress in this terminal.
    var progress: SSHTerminalProgressStore { engine.progress }
    /// OSC 9 / OSC 777 notifications and BEL in this terminal.
    var alerts: SSHTerminalAlertFeed { engine.alerts }
    var modifierLatch = SSHTerminalModifierLatch()
    /// The Rex session this terminal shows, when it is a Rex terminal: its
    /// panes, minimap, and the switch between them. Set before `opened`; stays
    /// after the terminal ends, so a reconnect knows the pane shown last.
    @ObservationIgnored var rex: RexSessionModel?
    /// Runs after a pane's snapshot replaced the engine's terminal, with the
    /// block it is of, so the grid knows the screen it holds is that pane's
    /// own (`SSHTerminalPaneTransition`). It runs at READY, when the screen
    /// can draw, not when the pane's older history has all arrived.
    @ObservationIgnored var snapshotRestored: ((String?) -> Void)?
    /// The pane whose snapshot history is arriving.
    @ObservationIgnored private var restoringBlock: String?
    private(set) var connected = false
    private(set) var connecting = true
    /// EOF stops input and terminal replies. The channel stays open so a
    /// following exit status or signal can still become the disconnect reason.
    private(set) var inputClosed = false
    private(set) var reason = "Connecting…"
    private(set) var inputNotice = ""
    /// Display-only; published only when the remote sets a different title.
    private(set) var title = ""
    /// The shell's working directory as a local path: its OSC 7 report, or, in
    /// a terminal Oppi started in Herdr, the focused pane of the host's Herdr
    /// (`SSHTerminalShellFolder`). Empty when neither gives one we can use.
    private(set) var workingDirectory = ""
    /// What the host's own Herdr says its focused pane's folder is; the Herdr
    /// poll sets it and clears it when it stops.
    private(set) var herdrFolder = HerdrLocalFolder.unknown
    /// How long a Herdr folder outlives the last successful snapshot while
    /// reads fail. Two polls (6 s apart) plus the side command's 10 s timeout.
    @ObservationIgnored private let herdrFolderGrace: Duration
    @ObservationIgnored private var herdrFolderRead: ContinuousClock.Instant?
    @ObservationIgnored private var herdrFolderExpiry: Task<Void, Never>?
    /// True while a network path change is being checked.
    private(set) var networkChanged = false
    /// Bumped each time a remote program put text on this device's clipboard.
    private(set) var copies = 0
    /// Characters in the latest remote copy.
    private(set) var lastCopyLength = 0
    /// The registry closed this terminal because Oppi stayed in the background
    /// past the grace period. A terminal on screen reconnects on return.
    private(set) var closedForBackground = false
    /// This terminal's screen is showing and the scene is active. The view
    /// reports it. A remote clipboard write is applied only then.
    @ObservationIgnored var isViewed = false
    /// The connection's cancellation, so a caller that must finish before the
    /// process suspends can wait for it.
    @ObservationIgnored private(set) var teardown: Task<Void, Never>?

    /// A path change is a hint, not proof the SSH stream failed: one SSH round
    /// trip decides. A live connection clears the notice; a dead one closes
    /// with a reason and offers Reconnect. Input is never replayed.
    /// Ends with the calling task: cancellation finishes the path stream, which
    /// stops the monitor.
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
        // `AsyncStream` does not end on its own when its consumer is cancelled.
        await withTaskCancellationHandler {
            for await path in paths {
                if let previous, previous != path, connected { await recheckAfterNetworkChange() }
                previous = path
            }
        } onCancel: {
            continuation.finish()
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
    /// Why this terminal cannot run side commands (`SSHTerminalConnection`),
    /// kept after it ends so a screen still says why.
    private(set) var sideCommandsUnavailable: String?
    /// The startup command running instead of a shell, if any. Exit reasons
    /// name it so a finished `herdr` attach is not reported as a shell exit.
    private(set) var command: String?
    private var writable = true
    private var writabilityRevision = 0
    private var pending = [Data]()
    private var queuedBytes = 0
    private var pump: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// Last size sent on this connection.
    private var remoteGeometry: SSHTerminalGeometry?
    /// Last size handed to the engine: a repeat is not a change.
    private var appliedGeometry: SSHTerminalGeometry?
    /// Latest size a terminal screen laid out. Nil until one has: the PTY
    /// opened at its own default, and the screen's first layout sends the size.
    private var requestedGeometry: SSHTerminalGeometry?
    static let maximumQueuedBytes = 128 * 1024

    /// `answersTerminalQueries` false drops the engine's replies to queries
    /// (device attributes, size reports, the OSC 7501 probe): a Rex pane's
    /// program already got them from Rex's own terminal on the host, and a
    /// second answer would reach it as typed input.
    init(herdrFolderGrace: Duration = .seconds(25), answersTerminalQueries: Bool = true) throws {
        self.herdrFolderGrace = herdrFolderGrace
        weak var target: SSHTerminalChannel?
        engine = try SSHTerminalEngine { reply in
            if answersTerminalQueries { target?.send(reply) }
        }
        engine.copied = { text in target?.copyToClipboard(text) }
        target = self
    }

    func opened(_ connection: any SSHTerminalConnection, command: String? = nil) {
        self.connection = connection
        self.command = command
        sideCommandsUnavailable = connection.sideCommandsUnavailable
        connected = true
        connecting = false
        reason = "Connected"
        remoteGeometry = nil
        if let requestedGeometry { resize(requestedGeometry) }
    }

    /// A remote copy (Herdr's copy-on-select, tmux, an agent's /copy) lands on
    /// this device's clipboard, as it would on the host terminal's. Local only:
    /// a host program must not reach other devices through Universal Clipboard.
    /// A terminal that is off screen, or while Oppi is not in front, drops the
    /// write: nobody is looking at what it would put on the clipboard.
    private func copyToClipboard(_ text: String) {
        guard connected, isViewed else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        lastCopyLength = text.count
        copies &+= 1
    }

    /// The user's own copy from a double-tap or long-press on the grid.
    /// This is not OSC 52, so the remote-clipboard gate does not apply.
    func copyLocalSelection(_ text: String) {
        let clipped = SSHTerminalCopyLimit.clip(text, maxBytes: SSHTerminalEngine.maximumCopyBytes)
        guard !clipped.isEmpty else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: clipped]])
        lastCopyLength = clipped.count
        copies &+= 1
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
    /// drains everything waiting, so consecutive output chunks share terminal
    /// writes. A stuck consumer past the queue cap fails the session.
    func consume(_ queue: SSHTerminalEventQueue) async {
        for await _ in queue.wake {
            await process(queue.drain(), releasingTo: queue)
            if !connected { break }
        }
        queue.finish()
        if connected { close(reason: "The SSH connection closed.") }
    }

    /// Consecutive output chunks are joined into one terminal write of about
    /// this many bytes (two SSH packets), so a burst is parsed in steps the
    /// clock below can check. A step is never smaller than one data item, which
    /// today is at most one SSH packet (32 KiB, `SSHConnection.maximumPacketSize`),
    /// so raising the packet size would weaken the slice budget.
    static let ingestWriteBytes = 64 * 1024
    /// The longest the main actor parses one burst before it yields, so
    /// display-link frames and input run between steps. Half a 120 Hz frame.
    /// A time budget, not a byte one: parse cost per byte differs about 25x
    /// between workloads (SSHTerminalThroughputBench) and again between devices.
    static let ingestSliceBudget = Duration.milliseconds(4)

    /// Events keep their order across yields: the next batch is drained only
    /// after this one finished, and a non-data event is applied only after
    /// every byte queued before it. Interpreted bytes are released before each
    /// yield, so the remote can resume while the main actor is away.
    private func process(_ items: [SSHTerminalEventQueue.Item], releasingTo queue: SSHTerminalEventQueue) async {
        let clock = ContinuousClock()
        var sliceStart = clock.now
        var run = Data()
        var unreleased = 0
        for item in items {
            switch item {
            case .event(.data(let bytes)):
                unreleased += bytes.count
                run.append(bytes)
                guard run.count >= Self.ingestWriteBytes else { continue }
                interpret(run)
                run.removeAll(keepingCapacity: true)
                guard clock.now - sliceStart >= Self.ingestSliceBudget else { continue }
                queue.release(bytes: unreleased)
                unreleased = 0
                await Task.yield()
                sliceStart = clock.now
                // A close while yielded (user, background, registry) ends the burst.
                guard connected else { return }
                continue
            case .event(let event):
                interpret(run)
                run.removeAll()
                self.event(event)
            case .snapshot(let snapshot, let block):
                interpret(run)
                run.removeAll()
                restore(snapshot, block: block)
            case .snapshotRecords(let records, let block):
                interpret(run)
                run.removeAll()
                restoreHistory(records, block: block)
            case .ended(let reason):
                interpret(run)
                run.removeAll()
                close(reason: reason)
            case .overflow:
                interpret(run)
                run.removeAll()
                close(reason: "The terminal stopped consuming remote output. The connection was closed.")
            }
            if !connected { break }
        }
        interpret(run)
        queue.release(bytes: unreleased)
    }

    private var exitSubject: String { command.map { "`\($0)`" } ?? "Shell" }

    /// Runs a structured side command on this terminal's connection.
    func run(_ command: String, input: Data = Data()) async throws -> SSHExecResult {
        if let sideCommandsUnavailable { throw SSHTerminalSideCommandsUnavailable(reason: sideCommandsUnavailable) }
        guard connected, let connection else { throw SSHConnectionError.notConnected }
        return try await connection.run(command, input: input)
    }

    /// Opens a long-lived command on this terminal's connection (`SSHTerminalConnection.openStream`).
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        if let sideCommandsUnavailable { throw SSHTerminalSideCommandsUnavailable(reason: sideCommandsUnavailable) }
        guard connected, let connection else { throw SSHConnectionError.notConnected }
        return try await connection.openStream(command: command, sink: sink)
    }

    /// Saves `data` in a private temporary folder on the host and returns its
    /// path, so a prompt can point an agent at a photo or file from the phone.
    func upload(_ data: Data, fileExtension: String) async throws -> String {
        guard data.count <= SSHTerminalUpload.maximumBytes else { throw SSHTerminalUpload.Failure.tooLarge }
        let name = SSHTerminalUpload.fileName(extension: fileExtension)
        return try SSHTerminalUpload.path(from: try await run(SSHTerminalUpload.command(fileName: name), input: data),
                                          fileName: name)
    }

    /// Starts the grid from a pane's snapshot: its screen and modes, ready to
    /// draw. Its older history follows (`restoreHistory`).
    private func restore(_ snapshot: Data, block: String?) {
        guard connected else { return }
        do {
            try engine.beginRestore(snapshot)
        } catch {
            close(reason: SSHTerminalSnapshotFormat.unreadable)
            return
        }
        restoringBlock = block
        if engine.title != title { title = engine.title }
        refreshWorkingDirectory()
        snapshotRestored?(block)
    }

    /// The snapshot's older history and image pixels. Records of a pane that
    /// is no longer the one restoring (a switch overtook it) are dropped.
    private func restoreHistory(_ records: Data, block: String?) {
        guard connected, block == restoringBlock else { return }
        do {
            try engine.continueRestore(records)
        } catch {
            // The screen drew; a damaged history record still ends the pane,
            // and says the history was the part that failed.
            close(reason: SSHTerminalSnapshotFormat.unreadableHistory)
        }
    }

    private func interpret(_ bytes: Data) {
        guard connected, !bytes.isEmpty else { return }
        engine.receive(bytes)
        if engine.title != title { title = engine.title }
        refreshWorkingDirectory()
    }

    /// A snapshot answered (or, with `.unknown`, the poll stopped).
    func setHerdrFolder(_ folder: HerdrLocalFolder) {
        herdrFolderExpiry?.cancel()
        herdrFolderExpiry = nil
        herdrFolderRead = folder == .unknown ? nil : .now
        guard folder != herdrFolder else { return }
        herdrFolder = folder
        refreshWorkingDirectory()
    }

    /// A snapshot read failed. The last folder stands until `herdrFolderGrace`
    /// after the last good read, so one slow answer does not hide it, and a
    /// Herdr that stays silent does not keep a stale one.
    func herdrReadFailed() {
        guard herdrFolder != .unknown, herdrFolderExpiry == nil, let read = herdrFolderRead else { return }
        herdrFolderExpiry = Task { [weak self, grace = herdrFolderGrace] in
            try? await Task.sleep(until: read + grace, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            herdrFolderExpiry = nil
            setHerdrFolder(.unknown)
        }
    }

    private func refreshWorkingDirectory() {
        let next = SSHTerminalShellFolder.resolve(
            reported: engine.workingDirectory,
            reportedFromOtherHost: engine.workingDirectoryFromOtherHost,
            herdrInFront: SSHTerminalMultiplexerKind.startsDefaultHerdr(command) && engine.alternateScreen,
            herdr: herdrFolder
        )
        if next != workingDirectory { workingDirectory = next }
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

    @discardableResult
    func send(_ bytes: Data) -> Bool {
        guard connected, connection != nil else {
            inputNotice = "Not sent — terminal is disconnected."
            return false
        }
        guard !inputClosed else {
            inputNotice = "Not sent — the remote shell has ended."
            return false
        }
        guard !bytes.isEmpty else { return false }
        guard queuedBytes + bytes.count <= Self.maximumQueuedBytes else {
            inputNotice = "Not sent — input buffer is full."
            return false
        }
        inputNotice = writable ? "" : "Waiting for the SSH channel…"
        pending.append(bytes)
        queuedBytes += bytes.count
        startPump()
        return true
    }

    /// Only explicit terminal keys use the one-shot latch. This is the sole
    /// consumption path: clear it after queue acceptance, never on refusal.
    @discardableResult
    func key(_ key: GhosttyKey, text: String = "", modifiers: GhosttyMods = 0) -> Bool {
        guard connected, !inputClosed else { return send(Data()) }
        let bytes = engine.key(key, text: text, modifiers: modifiers | modifierLatch.modifiers)
        guard send(bytes) else { return false }
        _ = modifierLatch.take()
        return true
    }

    /// Named bindings are sent exactly as configured, without spending the
    /// key latch. One write keeps a chord's strokes together and in order.
    func keys(_ strokes: [SSHTerminalKeyStroke]) {
        guard connected, !inputClosed else { send(Data()); return }
        send(strokes.reduce(into: Data()) { bytes, stroke in
            bytes.append(engine.key(stroke.key, text: stroke.text, modifiers: stroke.modifiers))
        })
    }

    /// ⌘K. Clears locally; sends only the form feed a shell prompt needs.
    func clearScreen() {
        let bytes = engine.clearScreen()
        if !bytes.isEmpty { send(bytes) }
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
        requestedGeometry = geometry
        // Both local and remote grid changes share the same coalesced geometry.
        // The connection's first size goes at once: a Rex pane opens its data
        // connection only once sized, so waiting would delay its screen.
        let coalesce = connected && remoteGeometry == nil ? Duration.zero : .milliseconds(80)
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            if coalesce > .zero {
                do { try await Task.sleep(for: coalesce) } catch { return }
            } else if Task.isCancelled {
                return
            }
            guard let self else { return }
            // A size the grid already has is not a change. Resizing the engine on a
            // repeat forces a full rebuild and bumps `changeCount`, so the grid
            // repaints and every reader of a picture moves on a frame where nothing
            // changed: the password-prompt latch turns off when a keyboard
            // transition releases its held resize and reports the settled size again.
            if geometry != self.appliedGeometry {
                self.appliedGeometry = geometry
                self.engine.resize(geometry)
            }
            // The remote shell already has this size: a repeat would only
            // send another window-change request.
            guard self.connected, let connection = self.connection, geometry != self.remoteGeometry else { return }
            self.remoteGeometry = geometry
            do {
                try await connection.resize(columns: geometry.columns, rows: geometry.rows,
                                            pixelWidth: geometry.pixelWidth, pixelHeight: geometry.pixelHeight)
            } catch {
                if !Task.isCancelled { self.close(reason: "Terminal resize failed: \(Self.message(error))") }
            }
        }
    }

    /// Drops a size not yet applied: it belonged to a screen that is leaving.
    func cancelPendingResize() {
        resizeTask?.cancel()
        resizeTask = nil
    }

    /// Close rather than silently losing bytes while the process is suspended.
    /// Host tmux or Herdr preserves the remote work.
    func closeForBackground() {
        // A reconnect still dialing is closed for the background too.
        guard connected || connecting else { return }
        closedForBackground = true
        close(reason: "Oppi went to the background.")
    }

    func close(reason: String) {
        connected = false
        connecting = false
        self.reason = reason
        herdrFolderExpiry?.cancel()
        herdrFolderExpiry = nil
        pending.removeAll()
        queuedBytes = 0
        engine.close()
        pump?.cancel()
        pump = nil
        resizeTask?.cancel()
        resizeTask = nil
        if let connection {
            // On the wire now; the task only waits for it to finish.
            connection.close()
            teardown = Task { await connection.cancel() }
        }
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
                } catch SSHConnectionError.notWritable {
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
        if let error = error as? SSHConnectionError { return error.message }
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
