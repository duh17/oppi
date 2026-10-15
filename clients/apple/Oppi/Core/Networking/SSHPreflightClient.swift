import Foundation
import NIOCore

/// Check a Machine's SSH commands: signs in to OpenSSH (macOS Remote Login or
/// Linux sshd) with a password over an `SSHConnection` and runs either the
/// setup probe or the pair-mint scripts. No PTY, shell session, or port
/// forwarding.
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

    static let commandTimeout: TimeAmount = .seconds(20)
    /// The probe prints a few hundred bytes; anything past this is not ours.
    static let maxProbeOutput = 64 * 1024

    /// Takes ownership of `socket`. Cancelling the task closes the SSH
    /// connection. Throws `SSHPreflightFailure` or `CancellationError`.
    static func run(_ request: Request, socket: Int32) async throws -> SSHPreflightReport {
        try await signedIn(request, socket: socket, outputTooLarge: .probeIncomplete) { connection in
            let probe = try await connection.run(
                SSHPreflightProbe.command,
                input: Data(SSHPreflightProbe.script.utf8),
                maximumOutputBytes: maxProbeOutput,
                timeout: commandTimeout
            )
            return try SSHPreflightProbe.parse(String(decoding: probe.output, as: UTF8.self))
        }
    }

    /// Signs in, confirms Oppi is serving HTTPS, then runs `oppi pair --json`.
    /// The pair command is not sent unless status says HTTPS. The invite body
    /// is not logged. Takes ownership of `socket`.
    static func mintInvite(_ request: Request, socket: Int32) async throws -> TailscalePairingInvite {
        try await signedIn(request, socket: socket, outputTooLarge: .inviteInvalid) { connection in
            let status = try await connection.run(
                SSHPreflightProbe.command,
                input: Data(SSHPairMint.statusScript.utf8),
                maximumOutputBytes: maxProbeOutput,
                timeout: commandTimeout
            )
            guard status.exitStatus == 0, SSHPairMint.servesHTTPS(String(decoding: status.output, as: UTF8.self)) else {
                throw SSHPreflightFailure.serverNotServingHTTPS
            }
            let minted = try await connection.run(
                SSHPreflightProbe.command,
                input: Data(SSHPairMint.pairScript.utf8),
                maximumOutputBytes: SSHPairMint.maxInviteOutput,
                timeout: commandTimeout
            )
            guard minted.exitStatus == 0 else { throw SSHPreflightFailure.inviteRefused }
            return try SSHPairMint.invite(from: String(decoding: minted.output, as: UTF8.self))
        }
    }

    /// Runs `body` on a password-signed-in connection and closes it afterwards.
    /// Connection failures become this screen's wording; `outputTooLarge` is
    /// what an over-long command output means for this operation.
    private static func signedIn<Result: Sendable>(
        _ request: Request,
        socket: Int32,
        outputTooLarge: SSHPreflightFailure,
        _ body: (SSHConnection) async throws -> Result
    ) async throws -> Result {
        do {
            let connection = try await SSHConnection.open(
                username: request.username,
                authentication: .password(request.password),
                savedHostKey: request.savedHostKey,
                socket: socket
            )
            defer { connection.close() }
            return try await body(connection)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard let error = error as? SSHConnectionError else { throw error }
            throw failure(error, outputTooLarge: outputTooLarge)
        }
    }

    private static func failure(_ error: SSHConnectionError, outputTooLarge: SSHPreflightFailure) -> SSHPreflightFailure {
        switch error {
        case .unknownHostKey(let presented): .unknownHostKey(presented)
        case .hostKeyMismatch(let saved, let presented): .hostKeyMismatch(saved: saved, presented: presented)
        case .passwordNotAllowed: .passwordNotAllowed
        case .authenticationFailed: .authenticationFailed
        case .signInTimedOut: .signInTimedOut
        case .unsupportedAlgorithms: .handshakeFailed("this machine offers no SSH algorithms Oppi supports")
        case .connectionClosed: .handshakeFailed("the connection closed")
        case .keyExchangeFailed(let reason): .handshakeFailed(reason)
        case .commandRequestRejected: .probeRefused
        case .requestTimedOut: .probeTimedOut
        case .commandOutputTooLarge: outputTooLarge
        // Not produced by a password sign-in plus one-shot exec.
        case .publicKeyNotAllowed, .ptyRequestRejected, .shellRequestRejected, .notConnected, .notWritable:
            .handshakeFailed(error.message)
        }
    }
}
