import Darwin
import Foundation
import NIOCore
import NIOSSH
import Synchronization

enum SSHPTYEvent: Sendable, Equatable {
    case data(Data)
    case eof
    case exitStatus(Int)
    case exitSignal(String)
    case writabilityChanged(Bool)
    case closed
}

typealias SSHPTYByteSink = @Sendable (SSHPTYEvent) -> Void

/// Consumer-owned flow control for inbound terminal output.
///
/// The PTY child channel reads on demand. While the consumer is paused no new
/// read is issued, so received bytes stay in NIOSSH's window-limited buffer, no
/// window adjust is sent, and the remote stops at the end of the receive window.
/// Pause and resume may be called from any thread.
final class SSHPTYInboundFlow: Sendable {
    private struct State {
        var paused = false
        var wake: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func pause() { state.withLock { $0.paused = true } }

    func resume() {
        let wake: (@Sendable () -> Void)? = state.withLock { state in
            guard state.paused else { return nil }
            state.paused = false
            return state.wake
        }
        wake?()
    }

    fileprivate var isPaused: Bool { state.withLock { $0.paused } }
    fileprivate func attach(_ wake: (@Sendable () -> Void)?) { state.withLock { $0.wake = wake } }
}

struct SSHPTYConfiguration: Sendable {
    let username: String
    let authentication: SSHAuthentication
    let savedHostKey: SSHHostKey?

    init(username: String, authentication: SSHAuthentication, savedHostKey: SSHHostKey?, inboundFlow: SSHPTYInboundFlow? = nil) {
        self.username = username
        self.authentication = authentication
        self.savedHostKey = savedHostKey
        self.inboundFlow = inboundFlow
    }

    var term = "xterm-256color"
    var columns = 80
    var rows = 24
    var pixelWidth = 0
    var pixelHeight = 0
    /// Optional consumer backpressure. Without it output is read as it arrives.
    var inboundFlow: SSHPTYInboundFlow?
    /// Runs this command on the PTY instead of the login shell, the same
    /// exec-with-TTY request as OpenSSH `RemoteCommand` + `RequestTTY yes`
    /// (`ssh -t host 'command'`). The session ends when the command exits.
    var command: String?
}

/// Owns one `SSHConnection` and exactly one interactive PTY child channel on
/// it. It never retries or retains input for replay. Callers may write only
/// while the child channel is writable; backpressure is surfaced as an error
/// and through `writabilityChanged` events.
final class SSHPTYSession: @unchecked Sendable {
    static let requestTimeout: TimeAmount = .seconds(20)

    private struct Channels {
        let connection: SSHConnection
        let terminal: Channel
        let keepalive: RepeatedTask
    }

    private let channels: Mutex<Channels?>

    private init(connection: SSHConnection, terminal: Channel) {
        let parent = connection.channel
        // This also works over tailscale_dial's socketpair: opening a child
        // requires a real SSH reply, unlike TCP probes or window-change. No
        // PTY/shell/exec is requested, so sshd starts no process. Backgrounding
        // closes the parent and cancels the timer with it.
        let keepalive = parent.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(60), delay: .seconds(60)) { task in
            guard parent.isActive else { task.cancel(); return }
            Self.probe(parent, timeout: .seconds(15))
        }
        parent.closeFuture.whenComplete { _ in keepalive.cancel() }
        channels = Mutex(Channels(connection: connection, terminal: terminal, keepalive: keepalive))
    }

    /// Owns the pre-dial authentication boundary. No sign-in deadline or socket
    /// exists while device presence is pending, and cancellation cannot dial.
    static func connect(
        username: String,
        savedHostKey: SSHHostKey?,
        inboundFlow: SSHPTYInboundFlow? = nil,
        command: String? = nil,
        prepareAuthentication: @Sendable () async throws -> SSHAuthentication,
        dial: @Sendable () async throws -> Int32,
        sink: @escaping SSHPTYByteSink
    ) async throws -> SSHPTYSession {
        try Task.checkCancellation()
        let authentication = try await prepareAuthentication()
        try Task.checkCancellation()
        let socket = try await dial()
        if Task.isCancelled { Darwin.close(socket); throw CancellationError() }
        var configuration = SSHPTYConfiguration(
            username: username, authentication: authentication,
            savedHostKey: savedHostKey, inboundFlow: inboundFlow
        )
        configuration.command = command
        return try await connect(configuration: configuration, socket: socket, sink: sink)
    }

    /// Takes ownership of an already-connected direct socket. The socket is
    /// deliberately not obtained from `TailnetTransportRoute`'s SOCKS path.
    static func connect(
        configuration: SSHPTYConfiguration,
        socket: Int32,
        sink: @escaping SSHPTYByteSink
    ) async throws -> SSHPTYSession {
        let connection = try await SSHConnection.open(
            username: configuration.username,
            authentication: configuration.authentication,
            savedHostKey: configuration.savedHostKey,
            socket: socket
        )
        let parent = connection.channel
        let loop = parent.eventLoop
        do {
            return try await withTaskCancellationHandler {
                let ready = loop.makePromise(of: Void.self)
                let openingCompleted = NIOLoopBoundBox.makeBoxSendingValue(false, eventLoop: loop)
                let requestDeadline = loop.scheduleTask(in: requestTimeout) {
                    // Completing an already-ready promise is a no-op, but
                    // closing its parent is not. The timer and completion own
                    // this decision on the same event loop.
                    guard !openingCompleted.value else { return }
                    openingCompleted.value = true
                    ready.fail(SSHConnectionError.requestTimedOut)
                    connection.close()
                }
                ready.futureResult.whenComplete { _ in
                    openingCompleted.value = true
                    requestDeadline.cancel()
                }
                defer { requestDeadline.cancel() }
                let terminal = try await openTerminal(
                    on: parent,
                    configuration: configuration,
                    ready: ready,
                    sink: sink
                )
                try await ready.futureResult.get()
                return SSHPTYSession(connection: connection, terminal: terminal)
            } onCancel: {
                connection.close()
            }
        } catch {
            connection.close()
            if Task.isCancelled { throw CancellationError() }
            throw SSHConnectionError(mapping: error)
        }
    }

    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        let terminal = try terminalChannel()
        let promise = terminal.eventLoop.makePromise(of: Void.self)
        terminal.eventLoop.execute {
            guard terminal.isActive else {
                promise.fail(SSHConnectionError.connectionClosed)
                return
            }
            guard terminal.isWritable else {
                promise.fail(SSHConnectionError.notWritable)
                return
            }
            var buffer = terminal.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            terminal.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                promise: promise
            )
        }
        do {
            try await promise.futureResult.get()
        } catch {
            throw SSHConnectionError(mapping: error)
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        guard columns > 0, rows > 0, pixelWidth >= 0, pixelHeight >= 0 else {
            throw SSHConnectionError.notConnected
        }
        let terminal = try terminalChannel()
        let promise = terminal.eventLoop.makePromise(of: Void.self)
        terminal.eventLoop.execute {
            guard terminal.isActive else {
                promise.fail(SSHConnectionError.connectionClosed)
                return
            }
            terminal.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: columns,
                    terminalRowHeight: rows,
                    terminalPixelWidth: pixelWidth,
                    terminalPixelHeight: pixelHeight
                ),
                promise: promise
            )
        }
        do {
            try await promise.futureResult.get()
        } catch {
            throw SSHConnectionError(mapping: error)
        }
    }

    /// Opens and closes an empty session channel. Success needs a real SSH
    /// round trip; failure or timeout closes the whole connection, because a
    /// peer that cannot answer a channel open cannot carry the terminal either.
    @discardableResult
    private static func probe(_ parent: Channel, timeout: TimeAmount) -> EventLoopFuture<Void> {
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        let deadline = parent.eventLoop.scheduleTask(in: timeout) {
            opened.fail(SSHConnectionError.requestTimedOut)
        }
        opened.futureResult.whenComplete { result in
            deadline.cancel()
            switch result {
            case .success(let probe): probe.close(promise: nil)
            case .failure: parent.close(promise: nil)
            }
        }
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    // Even a late channel-open response after the timeout must
                    // close its child; it never acquires a shell or credentials.
                    child.pipeline.addHandler(SSHKeepaliveProbeHandler())
                }
            } catch { opened.fail(error) }
        }
        return opened.futureResult.map { _ in }
    }

    /// Checks on demand (e.g. after a network path change) that the peer still
    /// answers. A failed check has already closed the connection.
    func checkAlive(timeout: TimeAmount = .seconds(8)) async throws {
        guard let parent = channels.withLock({ $0?.connection.channel }) else { throw SSHConnectionError.notConnected }
        do { try await Self.probe(parent, timeout: timeout).get() } catch { throw SSHConnectionError(mapping: error) }
    }

    /// Runs one command next to the terminal on the same connection. Used for
    /// structured remote APIs (e.g. `herdr api snapshot`) and uploads.
    func run(
        _ command: String,
        input: Data = Data(),
        maximumOutputBytes: Int = 2 * 1024 * 1024,
        timeout: TimeAmount = .seconds(10)
    ) async throws -> SSHExecResult {
        guard let connection = channels.withLock({ $0?.connection }) else { throw SSHConnectionError.notConnected }
        return try await connection.run(command, input: input, maximumOutputBytes: maximumOutputBytes, timeout: timeout)
    }

    /// Closes both channels. Input is not retained and cannot be replayed by a
    /// later connection.
    func cancel() async {
        let owned = channels.withLock { channels -> Channels? in
            defer { channels = nil }
            return channels
        }
        guard let owned else { return }
        owned.keepalive.cancel()
        owned.terminal.close(promise: nil)
        owned.connection.close()
        _ = try? await owned.connection.channel.closeFuture.get()
    }

    deinit {
        let owned = channels.withLock { channels -> Channels? in
            defer { channels = nil }
            return channels
        }
        owned?.keepalive.cancel()
        owned?.terminal.close(promise: nil)
        owned?.connection.close()
    }

    private func terminalChannel() throws -> Channel {
        guard let terminal = channels.withLock({ $0?.terminal }) else {
            throw SSHConnectionError.notConnected
        }
        return terminal
    }

    /// Opens the session child channel. `ready` is completed by the child
    /// handler once installed; if opening fails before that, it is failed here
    /// because nobody else would complete it and NIO traps in Debug on a
    /// promise dropped uncompleted.
    static func openTerminal(
        on parent: Channel,
        configuration: SSHPTYConfiguration,
        ready: EventLoopPromise<Void>,
        sink: @escaping SSHPTYByteSink
    ) async throws -> Channel {
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SSHPTYChannelHandler(configuration: configuration, ready: ready, sink: sink)
                        )
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
        do {
            return try await opened.futureResult.get()
        } catch {
            ready.fail(error)
            throw error
        }
    }
}

private final class SSHKeepaliveProbeHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func channelActive(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private final class SSHPTYChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private enum OpeningState {
        case waitingForPTY
        case waitingForShell
        case ready
    }

    /// Deliberately contains no authentication material. The child outlives
    /// sign-in and must not retain a password with its PTY geometry.
    private struct TerminalConfiguration {
        let term: String
        let columns: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let inboundFlow: SSHPTYInboundFlow?
        let command: String?
    }
    private let configuration: TerminalConfiguration
    private let ready: EventLoopPromise<Void>
    private let sink: SSHPTYByteSink
    private var openingState = OpeningState.waitingForPTY
    private var reportedEOF = false
    /// True from a `read()` until the batch it asks for has been delivered.
    private var readOutstanding = false
    /// Exit reports wait for the next delivered read batch (or close). Requests
    /// bypass NIOSSH's data buffer, so reporting one immediately could pass
    /// output that arrived before it but is not delivered yet.
    private var heldExitEvents = [SSHPTYEvent]()

    init(configuration: SSHPTYConfiguration, ready: EventLoopPromise<Void>, sink: @escaping SSHPTYByteSink) {
        self.configuration = TerminalConfiguration(
            term: configuration.term, columns: configuration.columns, rows: configuration.rows,
            pixelWidth: configuration.pixelWidth, pixelHeight: configuration.pixelHeight,
            inboundFlow: configuration.inboundFlow, command: configuration.command
        )
        self.ready = ready
        self.sink = sink
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Without half-closure, the server's EOF closes the whole channel and
        // a following exit-status request is lost.
        do {
            guard let options = context.channel.syncOptions else {
                throw ChannelError.operationUnsupported
            }
            try options.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            // Reads are issued on demand so the consumer can apply backpressure.
            try options.setOption(ChannelOptions.autoRead, value: false)
            if let flow = configuration.inboundFlow {
                let eventLoop = context.eventLoop
                let handler = NIOLoopBound(self, eventLoop: eventLoop)
                let box = NIOLoopBound(context, eventLoop: eventLoop)
                flow.attach {
                    eventLoop.execute {
                        guard box.value.channel.isActive else { return }
                        handler.value.requestRead(context: box.value)
                    }
                }
            }
        } catch {
            ready.fail(error)
            context.close(promise: nil)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: configuration.term,
            terminalCharacterWidth: configuration.columns,
            terminalRowHeight: configuration.rows,
            terminalPixelWidth: configuration.pixelWidth,
            terminalPixelHeight: configuration.pixelHeight,
            terminalModes: .init([:])
        )
        let requestWrite = context.eventLoop.makePromise(of: Void.self)
        requestWrite.futureResult.whenFailure { [ready] error in ready.fail(error) }
        context.triggerUserOutboundEvent(request, promise: requestWrite)
        context.fireChannelActive()
        requestRead(context: context)
    }

    private func requestRead(context: ChannelHandlerContext) {
        guard !readOutstanding, configuration.inboundFlow?.isPaused != true else { return }
        readOutstanding = true
        context.read()
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // Everything buffered has now been delivered to the sink.
        readOutstanding = false
        flushHeldExitEvents()
        context.fireChannelReadComplete()
        requestRead(context: context)
    }

    private func flushHeldExitEvents() {
        let held = heldExitEvents
        heldExitEvents.removeAll()
        for event in held { sink(event) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch openingState {
            case .waitingForPTY:
                openingState = .waitingForShell
                let requestWrite = context.eventLoop.makePromise(of: Void.self)
                requestWrite.futureResult.whenFailure { [ready] error in ready.fail(error) }
                if let command = configuration.command {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                        promise: requestWrite
                    )
                } else {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ShellRequest(wantReply: true),
                        promise: requestWrite
                    )
                }
            case .waitingForShell:
                openingState = .ready
                ready.succeed(())
                sink(.writabilityChanged(context.channel.isWritable))
            case .ready:
                context.fireUserInboundEventTriggered(event)
            }
        case is ChannelFailureEvent:
            switch openingState {
            case .waitingForPTY:
                ready.fail(SSHConnectionError.ptyRequestRejected)
            case .waitingForShell:
                ready.fail(configuration.command == nil
                    ? SSHConnectionError.shellRequestRejected : SSHConnectionError.commandRequestRejected)
            case .ready:
                context.fireUserInboundEventTriggered(event)
            }
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            heldExitEvents.append(.exitStatus(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            heldExitEvents.append(.exitSignal(signal.signalName))
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            reportEOF()
            context.fireUserInboundEventTriggered(event)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        sink(.data(Data(Array(buffer.readableBytesView))))
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        sink(.writabilityChanged(context.channel.isWritable))
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        ready.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready.fail(ChannelError.eof)
        flushHeldExitEvents()
        reportEOF()
        sink(.closed)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        configuration.inboundFlow?.attach(nil)
        ready.fail(ChannelError.ioOnClosedChannel)
    }

    private func reportEOF() {
        guard !reportedEOF else { return }
        reportedEOF = true
        sink(.eof)
    }
}