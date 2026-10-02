import Foundation
import NIOCore
import NIOPosix
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
    let identity: SSHIdentity
    let savedHostKey: SSHHostKey?
    var term = "xterm-256color"
    var columns = 80
    var rows = 24
    var pixelWidth = 0
    var pixelHeight = 0
    /// Optional consumer backpressure. Without it output is read as it arrives.
    var inboundFlow: SSHPTYInboundFlow?
}

enum SSHPTYSessionError: Error, Equatable, Sendable {
    case unknownHostKey(SSHHostKey)
    case hostKeyMismatch(saved: SSHHostKey, presented: SSHHostKey)
    case publicKeyNotAllowed
    case authenticationFailed
    case signInTimedOut
    case keyExchangeFailed(String)
    case ptyRequestRejected
    case shellRequestRejected
    case requestTimedOut
    case notConnected
    case notWritable
    case connectionClosed

    var message: String {
        switch self {
        case .unknownHostKey:
            "Confirm this host's SSH fingerprint before signing in. No user key was offered."
        case .hostKeyMismatch:
            "The SSH host key changed. No user key was offered."
        case .publicKeyNotAllowed:
            "The SSH server does not offer public-key authentication."
        case .authenticationFailed:
            "The SSH server rejected this public key."
        case .signInTimedOut:
            "SSH public-key sign-in timed out."
        case .keyExchangeFailed(let reason):
            "SSH key exchange failed: \(reason)"
        case .ptyRequestRejected:
            "The SSH server rejected the PTY request."
        case .shellRequestRejected:
            "The SSH server rejected the shell request."
        case .requestTimedOut:
            "The SSH server did not finish opening the terminal."
        case .notConnected:
            "The SSH terminal is not connected."
        case .notWritable:
            "The SSH terminal is applying backpressure. Wait until it becomes writable."
        case .connectionClosed:
            "The SSH connection closed."
        }
    }
}

/// Owns one direct SSH connection and exactly one interactive PTY child
/// channel. It never retries or retains input for replay. Callers may write
/// only while the child channel is writable; backpressure is surfaced as an
/// error and through `writabilityChanged` events.
final class SSHPTYSession: @unchecked Sendable {
    static let signInTimeout: TimeAmount = .seconds(20)
    static let requestTimeout: TimeAmount = .seconds(20)

    private struct Channels {
        let parent: Channel
        let terminal: Channel
    }

    private let channels: Mutex<Channels?>

    private init(parent: Channel, terminal: Channel) {
        channels = Mutex(Channels(parent: parent, terminal: terminal))
    }

    /// Takes ownership of an already-connected direct socket. The socket is
    /// deliberately not obtained from `TailnetTransportRoute`'s SOCKS path.
    static func connect(
        configuration: SSHPTYConfiguration,
        socket: Int32,
        sink: @escaping SSHPTYByteSink
    ) async throws -> SSHPTYSession {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let parent: Channel
        do {
            parent = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        var client = SSHClientConfiguration(
                            userAuthDelegate: PublicKeyAuthDelegate(
                                username: configuration.username,
                                identity: configuration.identity
                            ),
                            serverAuthDelegate: PTYHostKeyDelegate(saved: configuration.savedHostKey)
                        )
                        // NIOSSH advertises a 64-packet receive window. The 128 KiB
                        // default makes that 8 MiB, which one read can deliver at
                        // once; the minimum keeps it at 2 MiB so read backpressure
                        // bounds what the consumer must hold.
                        client.maximumPacketSize = 32 * 1024
                        let ssh = NIOSSHHandler(
                            role: .client(client),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandlers(
                            ssh,
                            PTYSignInWatcher(authenticated: authenticated)
                        )
                    }
                }
                .withConnectedSocket(socket)
                .get()
        } catch {
            authenticated.fail(error)
            throw mapFailure(error)
        }

        do {
            return try await withTaskCancellationHandler {
                let signInDeadline = loop.scheduleTask(in: signInTimeout) {
                    authenticated.fail(SSHPTYSessionError.signInTimedOut)
                }
                defer { signInDeadline.cancel() }
                try await authenticated.futureResult.get()

                let ready = loop.makePromise(of: Void.self)
                let terminal = try await openTerminal(
                    on: parent,
                    configuration: configuration,
                    ready: ready,
                    sink: sink
                )
                // Only fails `ready`: if the timeout wins, the catch below
                // closes the parent. Closing the terminal here would also kill a
                // session that became ready at the deadline and was returned.
                let requestDeadline = loop.scheduleTask(in: requestTimeout) {
                    ready.fail(SSHPTYSessionError.requestTimedOut)
                }
                defer { requestDeadline.cancel() }
                try await ready.futureResult.get()
                return SSHPTYSession(parent: parent, terminal: terminal)
            } onCancel: {
                parent.close(promise: nil)
            }
        } catch {
            parent.close(promise: nil)
            if Task.isCancelled { throw CancellationError() }
            throw mapFailure(error)
        }
    }

    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        let terminal = try terminalChannel()
        let promise = terminal.eventLoop.makePromise(of: Void.self)
        terminal.eventLoop.execute {
            guard terminal.isActive else {
                promise.fail(SSHPTYSessionError.connectionClosed)
                return
            }
            guard terminal.isWritable else {
                promise.fail(SSHPTYSessionError.notWritable)
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
            throw Self.mapFailure(error)
        }
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        guard columns > 0, rows > 0, pixelWidth >= 0, pixelHeight >= 0 else {
            throw SSHPTYSessionError.notConnected
        }
        let terminal = try terminalChannel()
        let promise = terminal.eventLoop.makePromise(of: Void.self)
        terminal.eventLoop.execute {
            guard terminal.isActive else {
                promise.fail(SSHPTYSessionError.connectionClosed)
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
            throw Self.mapFailure(error)
        }
    }

    /// Closes both channels. Input is not retained and cannot be replayed by a
    /// later connection.
    func cancel() async {
        let owned = channels.withLock { channels -> Channels? in
            defer { channels = nil }
            return channels
        }
        guard let owned else { return }
        owned.terminal.close(promise: nil)
        owned.parent.close(promise: nil)
        _ = try? await owned.parent.closeFuture.get()
    }

    deinit {
        let owned = channels.withLock { channels -> Channels? in
            defer { channels = nil }
            return channels
        }
        owned?.terminal.close(promise: nil)
        owned?.parent.close(promise: nil)
    }

    private func terminalChannel() throws -> Channel {
        guard let terminal = channels.withLock({ $0?.terminal }) else {
            throw SSHPTYSessionError.notConnected
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

    static func mapFailure(_ error: any Error) -> SSHPTYSessionError {
        if let failure = error as? SSHPTYSessionError { return failure }
        if let ssh = error as? NIOSSHError, ssh.type == .keyExchangeNegotiationFailure {
            return .keyExchangeFailed("no mutually supported algorithms")
        }
        if error is ChannelError || error is NIOFcntlFailedError {
            return .connectionClosed
        }
        return .keyExchangeFailed(String(describing: error))
    }
}

private final class PTYHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let saved: SSHHostKey?

    init(saved: SSHHostKey?) {
        self.saved = saved
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = SSHHostKey(openSSH: String(openSSHPublicKey: hostKey))
        switch SSHHostKeyVerdict.evaluate(saved: saved, presented: presented) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .unknown:
            validationCompletePromise.fail(SSHPTYSessionError.unknownHostKey(presented))
        case .mismatch(let saved):
            validationCompletePromise.fail(SSHPTYSessionError.hostKeyMismatch(saved: saved, presented: presented))
        }
    }
}

/// Offers exactly one public key and fails closed for every other method.
private final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let identity: SSHIdentity
    private var offered = false

    init(username: String, identity: SSHIdentity) {
        self.username = username
        self.identity = identity
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHPTYSessionError.publicKeyNotAllowed)
            return
        }
        guard !offered else {
            nextChallengePromise.fail(SSHPTYSessionError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: identity.privateKey))
        ))
    }
}

private final class PTYSignInWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(ChannelError.eof)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        authenticated.fail(ChannelError.ioOnClosedChannel)
    }
}

private final class SSHPTYChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private enum OpeningState {
        case waitingForPTY
        case waitingForShell
        case ready
    }

    private let configuration: SSHPTYConfiguration
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
        self.configuration = configuration
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
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ShellRequest(wantReply: true),
                    promise: requestWrite
                )
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
                ready.fail(SSHPTYSessionError.ptyRequestRejected)
            case .waitingForShell:
                ready.fail(SSHPTYSessionError.shellRequestRejected)
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
