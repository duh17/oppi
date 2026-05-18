import Foundation
import OSLog

private let pairingLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OppiMac", category: "PairingInviteService")

struct PairingInvite: Decodable {
    let host: String?
    let port: Int?
    let scheme: String?
    let name: String?
    let pairingToken: String?
    let fingerprint: String?
    let tlsCertFingerprint: String?
    let inviteURL: String?

    var serverURL: String? {
        guard let scheme, let host, let port else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    enum CodingKeys: String, CodingKey {
        case host, port, scheme, name, pairingToken, fingerprint, tlsCertFingerprint, inviteURL
    }
}

enum PairingInviteService {
    static func generate() async throws -> PairingInvite {
        let paths = await MainActor.run {
            ServerProcessManager.seedServerRuntimeIfNeeded()
            return (
                runtimePath: ServerProcessManager.resolveRuntimePath(),
                runtimeFailure: ServerProcessManager.runtimeFailureReason(),
                cliPath: ServerProcessManager.resolveServerCLIPath(),
                dataDir: ServerProcessManager.serverDataDir
            )
        }

        guard let runtimePath = paths.runtimePath else {
            throw PairingInviteError.runtimeUnavailable(paths.runtimeFailure)
        }
        guard let cliPath = paths.cliPath else {
            throw PairingInviteError.cliNotFound
        }

        var environment = ProcessRunner.augmentedEnvironment
        environment["OPPI_DATA_DIR"] = paths.dataDir
        environment["OPPI_RUNTIME_BIN"] = runtimePath

        let result = try await ProcessRunner.runCapturingStderr(
            executable: runtimePath,
            arguments: [cliPath, "pair", "--json"],
            environment: environment
        )

        guard result.exitCode == 0 else {
            let errText = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw PairingInviteError.commandFailed(errText)
        }

        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw PairingInviteError.emptyOutput
        }

        let invite = try JSONDecoder().decode(PairingInvite.self, from: data)
        pairingLogger.info("Pairing invite generated: host=\(invite.host ?? "unknown")")
        return invite
    }
}

enum PairingInviteError: LocalizedError {
    case runtimeUnavailable(String)
    case cliNotFound
    case commandFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let message): message
        case .cliNotFound: "Server CLI not found"
        case .commandFailed(let msg): "Pair command failed: \(msg)"
        case .emptyOutput: "No output from pair command"
        }
    }
}
