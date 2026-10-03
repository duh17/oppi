import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security
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

enum SSHPTYAuthentication: Sendable {
    case deviceKey(SSHIdentity)
    case password(String)

    func delegate(username: String) -> any NIOSSHClientUserAuthenticationDelegate {
        switch self {
        case .deviceKey(let identity): PublicKeyAuthDelegate(username: username, identity: identity)
        case .password(let password): SSHPasswordAuthDelegate(username: username, password: password)
        }
    }
}

struct SSHPTYConfiguration: Sendable {
    let username: String
    let authentication: SSHPTYAuthentication
    let savedHostKey: SSHHostKey?

    init(username: String, authentication: SSHPTYAuthentication, savedHostKey: SSHHostKey?, inboundFlow: SSHPTYInboundFlow? = nil) {
        self.username = username
        self.authentication = authentication
        self.savedHostKey = savedHostKey
        self.inboundFlow = inboundFlow
    }

    init(username: String, identity: SSHIdentity, savedHostKey: SSHHostKey?, inboundFlow: SSHPTYInboundFlow? = nil) {
        self.init(username: username, authentication: .deviceKey(identity), savedHostKey: savedHostKey, inboundFlow: inboundFlow)
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

/// Output of a one-shot command on an open connection. No PTY is requested.
struct SSHExecResult: Sendable, Equatable {
    let output: Data
    let errorOutput: Data
    /// Nil when the server closed the channel without reporting a status.
    let exitStatus: Int?
}

enum SSHPTYSessionError: Error, Equatable, Sendable {
    case unknownHostKey(SSHHostKey)
    case hostKeyMismatch(saved: SSHHostKey, presented: SSHHostKey)
    case publicKeyNotAllowed
    case passwordNotAllowed
    case unsupportedAlgorithms
    case authenticationFailed
    case signInTimedOut
    case keyExchangeFailed(String)
    case ptyRequestRejected
    case shellRequestRejected
    case commandRequestRejected
    case commandOutputTooLarge
    case requestTimedOut
    case notConnected
    case notWritable
    case connectionClosed

    var message: String {
        switch self {
        case .unknownHostKey:
            "Confirm this host's SSH fingerprint before signing in. No credentials were sent."
        case .hostKeyMismatch:
            "The SSH host key changed. No credentials were sent."
        case .publicKeyNotAllowed:
            "The SSH server does not offer public-key authentication."
        case .passwordNotAllowed:
            "The SSH server does not offer password authentication. Keyboard-interactive is not supported."
        case .unsupportedAlgorithms:
            "The SSH server offered no supported algorithm. Oppi supports Ed25519/ECDSA keys, Curve25519/ECDH key exchange and AES-GCM; RSA-only and legacy servers are not supported."
        case .authenticationFailed:
            "The SSH server rejected the username or credential."
        case .signInTimedOut:
            "SSH sign-in timed out."
        case .keyExchangeFailed(let reason):
            "SSH key exchange failed: \(reason)"
        case .ptyRequestRejected:
            "The SSH server rejected the PTY request."
        case .shellRequestRejected:
            "The SSH server rejected the shell request."
        case .commandRequestRejected:
            "The SSH server rejected the command request."
        case .commandOutputTooLarge:
            "The remote command produced more output than Oppi accepts."
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
        let keepalive: RepeatedTask
    }

    private let channels: Mutex<Channels?>

    private init(parent: Channel, terminal: Channel) {
        // This also works over tailscale_dial's socketpair: opening a child
        // requires a real SSH reply, unlike TCP probes or window-change. No
        // PTY/shell/exec is requested, so sshd starts no process. Backgrounding
        // closes the parent and cancels the timer with it.
        let keepalive = parent.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(60), delay: .seconds(60)) { task in
            guard parent.isActive else { task.cancel(); return }
            SSHPTYSession.probe(parent, timeout: .seconds(15))
        }
        parent.closeFuture.whenComplete { _ in keepalive.cancel() }
        channels = Mutex(Channels(parent: parent, terminal: terminal, keepalive: keepalive))
    }

    /// Owns the pre-dial authentication boundary. No sign-in deadline or socket
    /// exists while device presence is pending, and cancellation cannot dial.
    static func connect(
        username: String,
        savedHostKey: SSHHostKey?,
        inboundFlow: SSHPTYInboundFlow? = nil,
        command: String? = nil,
        prepareAuthentication: @Sendable () async throws -> SSHPTYAuthentication,
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
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let parent: Channel
        do {
            parent = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        var client = SSHClientConfiguration(
                            userAuthDelegate: configuration.authentication.delegate(username: configuration.username),
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
                let openingCompleted = NIOLoopBoundBox.makeBoxSendingValue(false, eventLoop: loop)
                let requestDeadline = loop.scheduleTask(in: requestTimeout) {
                    // Completing an already-ready promise is a no-op, but
                    // closing its parent is not. The timer and completion own
                    // this decision on the same event loop.
                    guard !openingCompleted.value else { return }
                    openingCompleted.value = true
                    ready.fail(SSHPTYSessionError.requestTimedOut)
                    parent.close(promise: nil)
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

    /// Opens and closes an empty session channel. Success needs a real SSH
    /// round trip; failure or timeout closes the whole connection, because a
    /// peer that cannot answer a channel open cannot carry the terminal either.
    @discardableResult
    private static func probe(_ parent: Channel, timeout: TimeAmount) -> EventLoopFuture<Void> {
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        let deadline = parent.eventLoop.scheduleTask(in: timeout) {
            opened.fail(SSHPTYSessionError.requestTimedOut)
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
        guard let parent = channels.withLock({ $0?.parent }) else { throw SSHPTYSessionError.notConnected }
        do { try await Self.probe(parent, timeout: timeout).get() } catch { throw Self.mapFailure(error) }
    }

    /// Runs one command in its own exec channel on this connection, without a
    /// PTY and without new authentication, and collects its output. Used for
    /// structured remote APIs (e.g. `herdr api snapshot`) next to the terminal.
    /// `input` is written to the command's stdin, which then closes.
    func run(
        _ command: String,
        input: Data = Data(),
        maximumOutputBytes: Int = 2 * 1024 * 1024,
        timeout: TimeAmount = .seconds(10)
    ) async throws -> SSHExecResult {
        guard let parent = channels.withLock({ $0?.parent }) else { throw SSHPTYSessionError.notConnected }
        let result = parent.eventLoop.makePromise(of: SSHExecResult.self)
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        opened.futureResult.whenFailure { result.fail($0) }
        let deadline = parent.eventLoop.scheduleTask(in: timeout) {
            result.fail(SSHPTYSessionError.requestTimedOut)
            opened.futureResult.whenSuccess { $0.close(promise: nil) }
        }
        result.futureResult.whenComplete { _ in deadline.cancel() }
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SSHExecHandler(command: command, input: input, limit: maximumOutputBytes, result: result)
                        )
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try await result.futureResult.get()
            } onCancel: {
                result.fail(CancellationError())
                opened.futureResult.whenSuccess { $0.close(promise: nil) }
            }
        } catch is CancellationError {
            throw CancellationError()
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
        owned.keepalive.cancel()
        owned.terminal.close(promise: nil)
        owned.parent.close(promise: nil)
        _ = try? await owned.parent.closeFuture.get()
    }

    deinit {
        let owned = channels.withLock { channels -> Channels? in
            defer { channels = nil }
            return channels
        }
        owned?.keepalive.cancel()
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
        if SSHIdentityKeyStoreError.securityStatus(error) == errSecInteractionNotAllowed {
            return .keyExchangeFailed(SSHIdentityKeyStoreError.authenticationExpired.localizedDescription)
        }
        if let preflight = error as? SSHPreflightFailure {
            switch preflight {
            case .passwordNotAllowed: return .passwordNotAllowed
            case .authenticationFailed: return .authenticationFailed
            default: return .keyExchangeFailed("SSH authentication failed")
            }
        }
        if let ssh = error as? NIOSSHError, ssh.type == .keyExchangeNegotiationFailure {
            return .unsupportedAlgorithms
        }
        if error is ChannelError || error is NIOFcntlFailedError {
            return .connectionClosed
        }
        return .keyExchangeFailed(String(describing: error))
    }
}

/// One exec request without a PTY. Once the command starts, `input` is written
/// to stdin and stdin is closed; stdout and stderr are collected until the
/// server closes the channel.
private final class SSHExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let input: Data
    private let limit: Int
    private let result: EventLoopPromise<SSHExecResult>
    private var output = ByteBuffer()
    private var errorOutput = ByteBuffer()
    private var exitStatus: Int?

    init(command: String, input: Data, limit: Int, result: EventLoopPromise<SSHExecResult>) {
        self.command = command
        self.input = input
        self.limit = limit
        self.result = result
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Keep reading after the server's EOF so a following exit status lands.
        try? context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = context.eventLoop.makePromise(of: Void.self)
        request.futureResult.whenFailure { [result] error in result.fail(error) }
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: request)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard !input.isEmpty else {
                context.close(mode: .output, promise: nil)
                return
            }
            // The SSH child channel queues writes past the peer's window, so
            // one write is enough; EOF follows the last byte.
            let data = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: input)))
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(data)).whenComplete { [result] outcome in
                switch outcome {
                case .success: channel.close(mode: .output, promise: nil)
                case .failure(let error):
                    result.fail(error)
                    channel.close(promise: nil)
                }
            }
        case is ChannelFailureEvent:
            result.fail(SSHPTYSessionError.commandRequestRejected)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = message.data else { return }
        guard output.readableBytes + errorOutput.readableBytes + bytes.readableBytes <= limit else {
            result.fail(SSHPTYSessionError.commandOutputTooLarge)
            context.close(promise: nil)
            return
        }
        if message.type == .channel { output.writeBuffer(&bytes) } else { errorOutput.writeBuffer(&bytes) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        result.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        result.succeed(SSHExecResult(
            output: Data(Array(output.readableBytesView)), errorOutput: Data(Array(errorOutput.readableBytesView)),
            exitStatus: exitStatus
        ))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        result.fail(ChannelError.ioOnClosedChannel)
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
                ready.fail(SSHPTYSessionError.ptyRequestRejected)
            case .waitingForShell:
                ready.fail(configuration.command == nil
                    ? SSHPTYSessionError.shellRequestRejected : SSHPTYSessionError.commandRequestRejected)
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
