import Foundation
import NIOCore

/// Set Up a Computer's SSH commands: signs in to OpenSSH (macOS Remote Login or
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
    /// Install & Start downloads Node.js and Oppi's package, then waits up to
    /// 90 s for the first start (it may probe Tailscale certificates), so it
    /// may take minutes on a slow link. Past this the run is stopped.
    static let installTimeout: TimeAmount = .minutes(Int64(SSHPreflightFailure.installTimeoutMinutes))
    /// npm and download progress can be chatty; this only stops a runaway.
    static let maxInstallOutput = 32 * 1024 * 1024

    /// Takes ownership of `socket`. Cancelling the task closes the SSH
    /// connection. Throws `SSHPreflightFailure` or `CancellationError`.
    static func run(_ request: Request, socket: Int32) async throws -> SSHPreflightReport {
        try await signedIn(request, socket: socket, outputTooLarge: .probeIncomplete) { connection in
            try await probe(on: connection)
        }
    }

    /// Signs in, confirms Oppi is serving HTTPS, then runs `oppi pair --json`.
    /// The pair command is not sent unless status says HTTPS. The invite body
    /// is not logged. Takes ownership of `socket`.
    static func mintInvite(_ request: Request, socket: Int32) async throws -> TailscalePairingInvite {
        try await signedIn(request, socket: socket, outputTooLarge: .inviteInvalid) { connection in
            try await mint(on: connection)
        }
    }

    /// What Install & Start ends with: the machine checked again, and an
    /// invite when Oppi answers.
    enum InstallOutcome: Sendable {
        case ready(SSHPreflightReport, TailscalePairingInvite)
        /// The installer finished, but the fresh check does not find Oppi
        /// answering over HTTPS, so no invite was minted.
        case notAnswering(SSHPreflightReport)
    }

    /// Install & Start on one signed-in connection: runs `script` (the bundled
    /// `install.sh`) with progress, then checks the machine again and, when
    /// Oppi answers, mints an invite through the same status-then-pair path
    /// as `mintInvite`. `progress` gets the folded state after each
    /// progress line, in order. Takes ownership of `socket`.
    static func install(
        _ request: Request,
        script: Data,
        socket: Int32,
        progress: @escaping @MainActor @Sendable (SSHInstallProgress) -> Void
    ) async throws -> InstallOutcome {
        // The installer's own overflow maps in `installFailure`; past it, an
        // over-long reply is the fresh check's, as for `run`.
        try await signedIn(request, socket: socket, outputTooLarge: .probeIncomplete) { connection in
            let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
            try await withThrowingTaskGroup(of: Int?.self) { group in
                group.addTask {
                    defer { continuation.finish() }
                    do {
                        return try await connection.run(
                            SSHInstallScript.command,
                            input: script,
                            maximumOutputBytes: maxInstallOutput,
                            timeout: installTimeout,
                            onOutput: { continuation.yield($0) }
                        ).exitStatus
                    } catch let error as SSHConnectionError {
                        throw installFailure(error)
                    }
                }
                var lines = SSHInstallLineBuffer()
                var state = SSHInstallProgress()
                for await chunk in chunks {
                    var changed = false
                    for line in lines.append(chunk) {
                        guard let event = SSHInstallEvent.parse(line) else { continue }
                        state.apply(event)
                        changed = true
                    }
                    if changed { await progress(state) }
                }
                let exitStatus = try await group.next() ?? nil
                if case .failure(let failure) = state.verdict(exitStatus: exitStatus) { throw failure }
            }
            let report = try await probe(on: connection)
            guard report.canPairOverSSH else { return .notAnswering(report) }
            do {
                return .ready(report, try await mint(on: connection))
            } catch SSHPreflightFailure.serverNotServingHTTPS {
                return .notAnswering(report)
            }
        }
    }

    /// A dropped connection or the deadline mid-install say so in install
    /// words; everything else maps as for the other commands.
    private static func installFailure(_ error: SSHConnectionError) -> any Error {
        switch error {
        case .requestTimedOut: SSHPreflightFailure.installTimedOut
        case .connectionClosed: SSHPreflightFailure.installInterrupted
        case .commandOutputTooLarge: SSHPreflightFailure.installIncomplete(exitStatus: nil)
        default: error
        }
    }

    private static func probe(on connection: SSHConnection) async throws -> SSHPreflightReport {
        let probe = try await connection.run(
            SSHPreflightProbe.command,
            input: Data(SSHPreflightProbe.script.utf8),
            maximumOutputBytes: maxProbeOutput,
            timeout: commandTimeout
        )
        return try SSHPreflightProbe.parse(String(decoding: probe.output, as: UTF8.self))
    }

    private static func mint(on connection: SSHConnection) async throws -> TailscalePairingInvite {
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
        case .unsupportedAlgorithms: .handshakeFailed("this computer offers no SSH algorithms Oppi supports")
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
