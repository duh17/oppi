import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Signs in to OpenSSH (macOS Remote Login or Linux sshd) with a password over an already
/// connected socket (a `tailscale_dial` socketpair end) and runs
/// `SSHPreflightProbe` once. No PTY, shell session, or port forwarding.
///
/// The host key is checked before the password is offered: an unknown or
/// changed key ends the connection with `unknownHostKey` / `hostKeyMismatch`.
enum SSHPreflightClient {
    struct Request: Sendable {
        let username: String
        let password: String
        /// The key the user trusted for this host, if any.
        let savedHostKey: SSHHostKey?
    }

    static let signInTimeout: TimeAmount = .seconds(20)
    static let probeTimeout: TimeAmount = .seconds(20)
    /// The probe prints a few hundred bytes; anything past this is not ours.
    static let maxProbeOutput = 64 * 1024

    /// Takes ownership of `socket`. Cancelling the task closes the SSH
    /// connection. Throws `SSHPreflightFailure` or `CancellationError`.
    static func run(_ request: Request, socket: Int32) async throws -> SSHPreflightReport {
        let channel = try await openAuthenticated(request, socket: socket)
        defer { channel.close(promise: nil) }

        return try await withTaskCancellationHandler {
            do {
                let output = channel.eventLoop.makePromise(of: String.self)
                let probeDeadline = channel.eventLoop.scheduleTask(in: probeTimeout) {
                    output.fail(SSHPreflightFailure.probeTimedOut)
                }
                defer { probeDeadline.cancel() }
                openProbeChannel(on: channel, output: output)
                return try SSHPreflightProbe.parse(try await output.futureResult.get())
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw Self.failure(error)
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// Signs in, confirms Oppi is serving HTTPS, then runs `oppi pair --json`.
    /// The pair command is not sent unless status says HTTPS. The invite body
    /// is not logged. Takes ownership of `socket`.
    static func mintInvite(_ request: Request, socket: Int32) async throws -> TailscalePairingInvite {
        let channel = try await openAuthenticated(request, socket: socket)
        defer { channel.close(promise: nil) }

        return try await withTaskCancellationHandler {
            do {
                let status = try await exec(
                    on: channel,
                    stdin: SSHPairMint.statusScript,
                    maxOutput: maxProbeOutput,
                    timedOut: .probeTimedOut
                )
                guard status.exitStatus == 0, SSHPairMint.servesHTTPS(status.stdout) else {
                    throw SSHPreflightFailure.serverNotServingHTTPS
                }
                let minted = try await exec(
                    on: channel,
                    stdin: SSHPairMint.pairScript,
                    maxOutput: SSHPairMint.maxInviteOutput,
                    timedOut: .probeTimedOut
                )
                guard minted.exitStatus == 0 else { throw SSHPreflightFailure.inviteRefused }
                return try SSHPairMint.invite(from: minted.stdout)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw Self.failure(error)
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// Host key is checked before the password is offered.
    private static func openAuthenticated(_ request: Request, socket: Int32) async throws -> Channel {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let ssh = NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: SSHPasswordAuthDelegate(
                                    username: request.username,
                                    password: request.password
                                ),
                                serverAuthDelegate: HostKeyDelegate(saved: request.savedHostKey)
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandlers(
                            ssh,
                            SignInWatcher(authenticated: authenticated)
                        )
                    }
                }
                .withConnectedSocket(socket)
                .get()
        } catch {
            authenticated.fail(error)
            throw Self.failure(error)
        }

        let signInDeadline = loop.scheduleTask(in: signInTimeout) {
            authenticated.fail(SSHPreflightFailure.signInTimedOut)
        }
        defer { signInDeadline.cancel() }
        do {
            try await authenticated.futureResult.get()
        } catch {
            channel.close(promise: nil)
            if Task.isCancelled { throw CancellationError() }
            throw Self.failure(error)
        }
        return channel
    }

    fileprivate struct ExecOutput: Sendable {
        var stdout: String
        var exitStatus: Int?
    }

    private static func exec(
        on channel: Channel,
        stdin: String,
        maxOutput: Int,
        timedOut: SSHPreflightFailure
    ) async throws -> ExecOutput {
        let output = channel.eventLoop.makePromise(of: ExecOutput.self)
        let deadline = channel.eventLoop.scheduleTask(in: probeTimeout) {
            output.fail(timedOut)
        }
        defer { deadline.cancel() }
        openExecChannel(on: channel, stdin: stdin, maxOutput: maxOutput, output: output)
        return try await output.futureResult.get()
    }

    private static func openExecChannel(
        on channel: Channel,
        stdin: String,
        maxOutput: Int,
        output: EventLoopPromise<ExecOutput>
    ) {
        channel.eventLoop.execute {
            let opened = channel.eventLoop.makePromise(of: Channel.self)
            opened.futureResult.whenFailure { output.fail($0) }
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ExecHandler(stdin: stdin, maxOutput: maxOutput, output: output)
                        )
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
    }

    private static func openProbeChannel(on channel: Channel, output: EventLoopPromise<String>) {
        channel.eventLoop.execute {
            let opened = channel.eventLoop.makePromise(of: Channel.self)
            opened.futureResult.whenFailure { output.fail($0) }
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(ProbeHandler(output: output))
                    }
                }
            } catch {
                opened.fail(error)
            }
        }
    }

    private static func failure(_ error: any Error) -> SSHPreflightFailure {
        if let failure = error as? SSHPreflightFailure { return failure }
        if let error = error as? NIOSSHError, error.type == .keyExchangeNegotiationFailure {
            return .handshakeFailed("this machine offers no SSH algorithms Oppi supports")
        }
        // Darwin fails fcntl with EINVAL on a socket whose peer already hung up.
        if error is ChannelError || error is NIOFcntlFailedError {
            return .handshakeFailed("the connection closed")
        }
        return .handshakeFailed(String(describing: error))
    }
}

// MARK: - Delegates

/// Compares the presented host key to the trusted one before any password is sent.
private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
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
            validationCompletePromise.fail(SSHPreflightFailure.unknownHostKey(presented))
        case .mismatch(let saved):
            validationCompletePromise.fail(SSHPreflightFailure.hostKeyMismatch(saved: saved, presented: presented))
        }
    }
}

/// Offers the password once. A second request means the server rejected it.
/// Shared by the machine setup check and the interactive terminal. Never logs credentials.
final class SSHPasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var password: String?
    private var offered = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHPreflightFailure.passwordNotAllowed)
            return
        }
        guard !offered else {
            nextChallengePromise.fail(SSHPreflightFailure.authenticationFailed)
            return
        }
        offered = true
        let credential = password ?? ""
        password = nil
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .password(.init(password: credential))
        ))
    }
}

// MARK: - Handlers

/// Completes `authenticated` on sign-in, or fails it with the first error
/// (including a delegate's `SSHPreflightFailure`) or when the connection ends.
private final class SignInWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
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

/// Execs `SSHPreflightProbe.command`, writes the script to its stdin, and
/// collects stdout until the channel closes.
private final class ProbeHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let output: EventLoopPromise<String>
    private var stdout = ByteBuffer()

    init(output: EventLoopPromise<String>) {
        self.output = output
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Keep reading after the server's EOF until it closes the channel.
        try? context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: SSHPreflightProbe.command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            // The exec started: send the script, then EOF so `sh -s` runs it.
            let script = context.channel.allocator.buffer(string: SSHPreflightProbe.script)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(script))), promise: nil)
            context.close(mode: .output, promise: nil)
        case is ChannelFailureEvent:
            output.fail(SSHPreflightFailure.probeRefused)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }
        guard stdout.readableBytes + bytes.readableBytes <= SSHPreflightClient.maxProbeOutput else {
            output.fail(SSHPreflightFailure.probeIncomplete)
            context.close(promise: nil)
            return
        }
        stdout.writeBuffer(&bytes)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        output.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        output.succeed(String(buffer: stdout))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        output.fail(ChannelError.ioOnClosedChannel)
    }
}

/// Execs `/bin/sh -s`, writes a fixed script, and collects stdout plus exit status.
/// Used only for the SSH pair mint. The setup probe keeps its own handler.
private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let stdin: String
    private let maxOutput: Int
    private let output: EventLoopPromise<SSHPreflightClient.ExecOutput>
    private var stdout = ByteBuffer()
    private var exitStatus: Int?
    private var finished = false

    init(stdin: String, maxOutput: Int, output: EventLoopPromise<SSHPreflightClient.ExecOutput>) {
        self.stdin = stdin
        self.maxOutput = maxOutput
        self.output = output
    }

    func handlerAdded(context: ChannelHandlerContext) {
        try? context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: SSHPreflightProbe.command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            let script = context.channel.allocator.buffer(string: stdin)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(script))), promise: nil)
            context.close(mode: .output, promise: nil)
        case is ChannelFailureEvent:
            finish(context: context, result: .failure(SSHPreflightFailure.probeRefused))
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }
        guard stdout.readableBytes + bytes.readableBytes <= maxOutput else {
            finish(context: context, result: .failure(SSHPreflightFailure.inviteInvalid))
            return
        }
        stdout.writeBuffer(&bytes)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(context: context, result: .failure(error))
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(context: context, result: .success(.init(stdout: String(buffer: stdout), exitStatus: exitStatus)))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(context: context, result: .failure(ChannelError.ioOnClosedChannel))
    }

    private func finish(context: ChannelHandlerContext, result: Result<SSHPreflightClient.ExecOutput, any Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success(let value): output.succeed(value)
        case .failure(let error): output.fail(error)
        }
        context.close(promise: nil)
    }
}
