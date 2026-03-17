import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "ServerProcessManager")

/// Manages the lifecycle of a local Oppi server (Node.js child process).
///
/// Handles start, stop, restart, crash detection with auto-restart,
/// and streams stdout/stderr into a capped ring buffer for the Logs view.
@MainActor @Observable
final class ServerProcessManager {

    // MARK: - Types

    enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    enum Stream: Sendable {
        case stdout
        case stderr
    }

    struct LogLine: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let stream: Stream
        let text: String

        init(stream: Stream, text: String) {
            self.id = UUID()
            self.timestamp = Date()
            self.stream = stream
            self.text = text
        }
    }

    // MARK: - Public state

    private(set) var state: State = .stopped
    private(set) var logBuffer: [LogLine] = []

    // MARK: - Configuration

    static let maxLogLines = 5000
    private static let maxRestartAttempts = 3
    private static let restartBackoffSeconds: TimeInterval = 3

    // MARK: - Private

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var restartAttempts = 0
    private var isIntentionalStop = false

    // MARK: - Path resolution

    /// Resolves the server CLI path.
    ///
    /// Search order:
    /// 1. `OPPI_SERVER_PATH` environment variable
    /// 2. Well-known locations (repo-local, homebrew npm global)
    static func resolveServerCLIPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["OPPI_SERVER_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }

        // Well-known locations for dogfood development
        let candidates = [
            // Repo-local (running from within workspace)
            NSString("~/workspace/oppi/server/dist/cli.js").expandingTildeInPath,
            NSString("~/workspace/pios/server/dist/cli.js").expandingTildeInPath,
            // Homebrew npm global
            "/opt/homebrew/lib/node_modules/@anthropic-ai/oppi/dist/cli.js",
            "/usr/local/lib/node_modules/@anthropic-ai/oppi/dist/cli.js",
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolves the Node.js binary path.
    static func resolveNodePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Lifecycle

    /// Start the server using default resolved paths.
    func startWithDefaults() {
        guard let nodePath = Self.resolveNodePath() else {
            state = .failed("Node.js not found")
            logger.error("Node.js binary not found in well-known paths")
            return
        }
        guard let cliPath = Self.resolveServerCLIPath() else {
            state = .failed("Server CLI not found")
            logger.error("Server CLI not found — set OPPI_SERVER_PATH or install the server")
            return
        }
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        start(nodePath: nodePath, cliPath: cliPath, dataDir: dataDir)
    }

    /// Spawn the server process.
    ///
    /// - Parameters:
    ///   - nodePath: Absolute path to the `node` binary.
    ///   - cliPath: Absolute path to the server CLI entry point (`cli.js`).
    ///   - dataDir: Absolute path to the Oppi data directory.
    func start(nodePath: String, cliPath: String, dataDir: String) {
        guard state == .stopped || isFailedState else {
            logger.warning("Cannot start server from state: \(String(describing: self.state))")
            return
        }

        state = .starting
        isIntentionalStop = false
        logger.info("Starting server: node=\(nodePath) cli=\(cliPath) data=\(dataDir)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [cliPath, "serve", "--data-dir", dataDir]

        // Ensure homebrew paths are available for git, pi, etc.
        var env = ProcessRunner.augmentedEnvironment
        env["OPPI_DATA_DIR"] = dataDir
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        setupPipeHandler(stdout, stream: .stdout)
        setupPipeHandler(stderr, stream: .stderr)

        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleTermination(terminatedProcess)
            }
        }

        do {
            try proc.run()
            self.process = proc
            logger.info("Server process launched (pid \(proc.processIdentifier))")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Failed to launch server process: \(error.localizedDescription)")
        }
    }

    /// Gracefully stop the server: SIGTERM, then SIGKILL after 5 seconds.
    func stop() async {
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }

        state = .stopping
        isIntentionalStop = true
        logger.info("Stopping server (pid \(proc.processIdentifier))")

        proc.terminate() // SIGTERM

        // Wait up to 5 seconds for graceful exit
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if proc.isRunning {
            logger.warning("Server did not exit after SIGTERM, sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }

        cleanup()
        state = .stopped
        logger.info("Server stopped")
    }

    /// Stop, then start the server.
    func restart() async {
        restartAttempts = 0
        await stop()
        startWithDefaults()
    }

    /// Notify that the server is healthy (called by health monitor).
    func markRunning() {
        if state == .starting {
            state = .running
            restartAttempts = 0
            logger.info("Server marked as running")
        }
    }

    /// Clear the log buffer.
    func clearLogs() {
        logBuffer.removeAll()
    }

    // MARK: - Private

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    private func setupPipeHandler(_ pipe: Pipe, stream: Stream) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }

            let lines = text.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { LogLine(stream: stream, text: $0) }

            Task { @MainActor [weak self] in
                self?.appendLogLines(lines)
            }
        }
    }

    private func appendLogLines(_ lines: [LogLine]) {
        logBuffer.append(contentsOf: lines)
        if logBuffer.count > Self.maxLogLines {
            logBuffer.removeFirst(logBuffer.count - Self.maxLogLines)
        }
    }

    private func handleTermination(_ proc: Process) {
        let status = proc.terminationStatus
        logger.info("Server process exited with status \(status)")

        cleanup()

        guard !isIntentionalStop else {
            state = .stopped
            return
        }

        // Unexpected exit — attempt auto-restart
        if restartAttempts < Self.maxRestartAttempts {
            restartAttempts += 1
            let attempt = restartAttempts
            state = .failed("Crashed (exit \(status)), restarting (attempt \(attempt)/\(Self.maxRestartAttempts))...")
            logger.warning("Auto-restart attempt \(attempt)/\(Self.maxRestartAttempts) in \(Self.restartBackoffSeconds)s")

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.restartBackoffSeconds))
                self?.startWithDefaults()
            }
        } else {
            state = .failed("Crashed (exit \(status)) — max restart attempts reached")
            logger.error("Server crashed and max restart attempts (\(Self.maxRestartAttempts)) exhausted")
        }
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
    }
}
