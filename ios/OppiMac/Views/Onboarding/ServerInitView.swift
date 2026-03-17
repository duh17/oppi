import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "ServerInitView")

/// Step 3: Initialize the server config and start the server.
///
/// Runs `node <cli> init --yes` then starts the server process
/// and waits for /health to respond.
struct ServerInitView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var phase: InitPhase = .idle
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Server Setup")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Oppi will create its configuration and start the local server.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                InitStepRow(
                    label: "Creating config",
                    done: phase.rawValue > InitPhase.creatingConfig.rawValue,
                    active: phase == .creatingConfig
                )
                InitStepRow(
                    label: "Starting server",
                    done: phase.rawValue > InitPhase.startingServer.rawValue,
                    active: phase == .startingServer
                )
                InitStepRow(
                    label: "Waiting for health check",
                    done: phase == .ready,
                    active: phase == .waitingHealth
                )

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            HStack {
                Button("Back") {
                    onBack()
                }
                .disabled(phase.isRunning)

                Spacer()

                if phase == .idle || error != nil {
                    Button("Initialize & Start") {
                        startInit()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if phase == .ready {
                    Button("Continue") {
                        onContinue()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Init sequence

    private func startInit() {
        error = nil
        phase = .creatingConfig

        Task.detached {
            do {
                // Step 1: Run `oppi init --yes`
                try await runServerInit()

                await MainActor.run { phase = .startingServer }

                // Step 2: Start the server process
                await MainActor.run {
                    processManager.startWithDefaults()
                }

                await MainActor.run { phase = .waitingHealth }

                // Step 3: Wait for /health
                let healthy = try await waitForHealth()

                await MainActor.run {
                    if healthy {
                        phase = .ready
                    } else {
                        error = "Server did not become healthy after 30 seconds"
                        phase = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    phase = .idle
                }
            }
        }
    }

    private nonisolated func runServerInit() async throws {
        guard let nodePath = await MainActor.run(body: { ServerProcessManager.resolveNodePath() }) else {
            throw InitError.nodeNotFound
        }
        guard let cliPath = await MainActor.run(body: { ServerProcessManager.resolveServerCLIPath() }) else {
            throw InitError.cliNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [cliPath, "init", "--yes"]

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw InitError.initFailed(errText)
        }

        logger.info("Server init completed successfully")
    }

    private nonisolated func waitForHealth() async throws -> Bool {
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath

        // Read token from newly created config
        guard let token = await MainActor.run(body: {
            MacAPIClient.readOwnerToken(dataDir: dataDir)
        }) else {
            throw InitError.noToken
        }

        let baseURL = URL(string: "https://localhost:7749")!
        let client = await MainActor.run {
            MacAPIClient(baseURL: baseURL, token: token)
        }

        // Poll for up to 30 seconds
        for _ in 0..<15 {
            let healthy = await client.checkHealth()
            if healthy {
                return true
            }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }
}

// MARK: - Types

private enum InitPhase: Int {
    case idle = 0
    case creatingConfig = 1
    case startingServer = 2
    case waitingHealth = 3
    case ready = 4

    var isRunning: Bool {
        self == .creatingConfig || self == .startingServer || self == .waitingHealth
    }
}

private enum InitError: LocalizedError {
    case nodeNotFound
    case cliNotFound
    case initFailed(String)
    case noToken

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: "Node.js not found"
        case .cliNotFound: "Server CLI not found"
        case .initFailed(let msg): "Server init failed: \(msg)"
        case .noToken: "Could not read owner token from config"
        }
    }
}

// MARK: - Step row

private struct InitStepRow: View {
    let label: String
    let done: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if active {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }

            Text(label)
                .foregroundStyle(active || done ? .primary : .secondary)
        }
    }
}
