import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Signs in to macOS Remote Login (sshd) with a password over an already
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
        defer { channel.close(promise: nil) }

        return try await withTaskCancellationHandler {
            do {
                let signInDeadline = loop.scheduleTask(in: signInTimeout) {
                    authenticated.fail(SSHPreflightFailure.signInTimedOut)
                }
                defer { signInDeadline.cancel() }
                try await authenticated.futureResult.get()

                let output = loop.makePromise(of: String.self)
                let probeDeadline = loop.scheduleTask(in: probeTimeout) {
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
            return .handshakeFailed("this Mac offers no SSH algorithms Oppi supports")
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
/// Shared by Check a Mac and the interactive terminal. Never logs credentials.
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
