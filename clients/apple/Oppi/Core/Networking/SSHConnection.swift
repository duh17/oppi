import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security

/// The one credential an SSH sign-in offers. Each is offered once.
enum SSHAuthentication: Sendable {
    case deviceKey(SSHIdentity)
    case password(String)

    fileprivate func delegate(username: String) -> any NIOSSHClientUserAuthenticationDelegate {
        switch self {
        case .deviceKey(let identity): PublicKeyAuthDelegate(username: username, identity: identity)
        case .password(let password): PasswordAuthDelegate(username: username, password: password)
        }
    }
}

/// Output of a one-shot command on an open connection. No PTY is requested.
struct SSHExecResult: Sendable, Equatable {
    let output: Data
    let errorOutput: Data
    /// Nil when the server closed the channel without reporting a status.
    let exitStatus: Int?
}

/// Every SSH connection and terminal failure. Check a Machine maps these to
/// its own setup wording (`SSHPreflightClient`).
enum SSHConnectionError: Error, Equatable, Sendable {
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

    init(mapping error: any Error) {
        if let failure = error as? SSHConnectionError {
            self = failure
        } else if SSHIdentityKeyStoreError.securityStatus(error) == errSecInteractionNotAllowed {
            self = .keyExchangeFailed(SSHIdentityKeyStoreError.authenticationExpired.localizedDescription)
        } else if let ssh = error as? NIOSSHError, ssh.type == .keyExchangeNegotiationFailure {
            self = .unsupportedAlgorithms
        } else if error is ChannelError || error is NIOFcntlFailedError {
            // Darwin fails fcntl with EINVAL on a socket whose peer already hung up.
            self = .connectionClosed
        } else {
            self = .keyExchangeFailed(String(describing: error))
        }
    }

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

/// One signed-in SSH connection over an already-connected socket (a tailnet
/// socketpair end or a direct TCP socket). It is the only place Oppi verifies
/// a host key and offers a credential: the presented key must match the saved
/// one before the credential is sent once, and sign-in must finish within
/// `signInTimeout`. Check a Machine runs one-shot commands on it; the SSH
/// Terminal adds its PTY and keepalive children (`SSHPTYSession`).
struct SSHConnection: Sendable {
    static let signInTimeout: TimeAmount = .seconds(20)
    /// NIOSSH advertises a 64-packet receive window. The 128 KiB default makes
    /// that 8 MiB, which one read can deliver at once; the minimum keeps it at
    /// 2 MiB so the terminal's read backpressure bounds what its consumer holds.
    static let maximumPacketSize = 32 * 1024

    /// The SSH parent channel. Child session channels open on it.
    let channel: Channel

    /// Takes ownership of `socket`. Cancelling the task, including during
    /// sign-in, closes the connection and throws `CancellationError`; every
    /// other failure is an `SSHConnectionError`.
    static func open(
        username: String,
        authentication: SSHAuthentication,
        savedHostKey: SSHHostKey?,
        socket: Int32
    ) async throws -> SSHConnection {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        var client = SSHClientConfiguration(
                            userAuthDelegate: authentication.delegate(username: username),
                            serverAuthDelegate: HostKeyDelegate(saved: savedHostKey)
                        )
                        client.maximumPacketSize = maximumPacketSize
                        let ssh = NIOSSHHandler(
                            role: .client(client),
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
            throw SSHConnectionError(mapping: error)
        }

        do {
            try await withTaskCancellationHandler {
                let deadline = loop.scheduleTask(in: signInTimeout) {
                    authenticated.fail(SSHConnectionError.signInTimedOut)
                }
                defer { deadline.cancel() }
                try await authenticated.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            channel.close(promise: nil)
            if Task.isCancelled { throw CancellationError() }
            throw SSHConnectionError(mapping: error)
        }
        return SSHConnection(channel: channel)
    }

    /// Runs one command in its own exec channel, without a PTY and without new
    /// authentication, and collects its output. `input` is written to the
    /// command's stdin, which then closes. Stdout and stderr together may not
    /// exceed `maximumOutputBytes`.
    func run(
        _ command: String,
        input: Data = Data(),
        maximumOutputBytes: Int,
        timeout: TimeAmount
    ) async throws -> SSHExecResult {
        let parent = channel
        let result = parent.eventLoop.makePromise(of: SSHExecResult.self)
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        opened.futureResult.whenFailure { result.fail($0) }
        let deadline = parent.eventLoop.scheduleTask(in: timeout) {
            result.fail(SSHConnectionError.requestTimedOut)
            opened.futureResult.whenSuccess { $0.close(promise: nil) }
        }
        result.futureResult.whenComplete { _ in deadline.cancel() }
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ExecHandler(command: command, input: input, limit: maximumOutputBytes, result: result)
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
            throw SSHConnectionError(mapping: error)
        }
    }

    func close() {
        channel.close(promise: nil)
    }
}

// MARK: - Delegates

/// Compares the presented host key to the trusted one before any credential is sent.
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
            validationCompletePromise.fail(SSHConnectionError.unknownHostKey(presented))
        case .mismatch(let saved):
            validationCompletePromise.fail(SSHConnectionError.hostKeyMismatch(saved: saved, presented: presented))
        }
    }
}

/// Offers the password once. A second request means the server rejected it.
/// Never logs credentials.
private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
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
            nextChallengePromise.fail(SSHConnectionError.passwordNotAllowed)
            return
        }
        guard !offered else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
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
            nextChallengePromise.fail(SSHConnectionError.publicKeyNotAllowed)
            return
        }
        guard !offered else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
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

// MARK: - Handlers

/// Completes `authenticated` on sign-in, or fails it with the first error
/// (including a delegate's `SSHConnectionError`) or when the connection ends.
private final class SignInWatcher: ChannelInboundHandler {
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

/// One exec request without a PTY. Once the command starts, `input` is written
/// to stdin and stdin is closed; stdout and stderr are collected until the
/// server closes the channel.
private final class ExecHandler: ChannelInboundHandler {
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
            result.fail(SSHConnectionError.commandRequestRejected)
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
            result.fail(SSHConnectionError.commandOutputTooLarge)
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
