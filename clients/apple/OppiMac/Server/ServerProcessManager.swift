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

    #if DEBUG
    /// Test-only: override state for unit test setup.
    func _setStateForTesting(_ newState: State) { state = newState }

    /// Test-only: inject log lines for buffer cap / clear testing.
    func _appendLogLinesForTesting(_ lines: [LogLine]) { appendLogLines(lines) }
    #endif

    // MARK: - Configuration

    static let maxLogLines = 5000
    private static let maxRestartAttempts = 3
    private static let restartBackoffSeconds: TimeInterval = 3

    // MARK: - Private

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var logFileHandle: FileHandle?
    private var restartAttempts = 0
    private var isIntentionalStop = false

    /// Maximum size for the persistent log file before rotation (5 MB).
    private static let maxLogFileSize: UInt64 = 5 * 1024 * 1024

    // MARK: - Path resolution

    /// Resolves the server CLI path.
    ///
    /// Search order:
    /// 1. `OPPI_SERVER_PATH` environment variable
    /// 2. App bundle (release builds copy server runtime into Resources/)
    /// 3. Well-known dev paths (repo-local workspaces)
    /// 4. Homebrew npm global
    static func resolveServerCLIPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["OPPI_SERVER_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }

        // App bundle — release builds embed the server runtime in Resources/
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = (resourcePath as NSString).appendingPathComponent("server/dist/cli.js")
            if FileManager.default.fileExists(atPath: bundledPath) {
                return bundledPath
            }
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

    /// Kill any existing server process and stale Bonjour advertisements.
    ///
    /// On launch the Mac app may find orphaned `node cli.js serve` or `dns-sd`
    /// processes from a prior app instance. This cleans them up so we can spawn
    /// a fresh server with full lifecycle control (termination handler, pipes, logs).
    static func killExistingServer() {
        // Find server processes matching our CLI pattern.
        // Use pgrep to avoid false positives from other node processes.
        let serverPids = pidsMatching(pattern: "node.*cli\\.js.*serve")
        for pid in serverPids {
            logger.info("Killing existing server process (pid \(pid))")
            kill(pid, SIGTERM)
        }

        // Find stale dns-sd Bonjour advertisements for oppi.
        let dnsPids = pidsMatching(pattern: "dns-sd.*_oppi._tcp")
        for pid in dnsPids {
            logger.info("Killing stale dns-sd process (pid \(pid))")
            kill(pid, SIGTERM)
        }

        // Brief wait for processes to exit.
        if !serverPids.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            // Force-kill any survivors.
            for pid in serverPids {
                if kill(pid, 0) == 0 { // still alive
                    logger.warning("Force-killing server process (pid \(pid))")
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// Find PIDs matching a grep pattern via pgrep.
    private static func pidsMatching(pattern: String) -> [pid_t] {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", pattern]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ProcessInfo.processInfo.processIdentifier } // exclude self
    }

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
    ///   - nodePath: Absolute path to the `node` (or `tsx`) binary.
    ///   - cliPath: Absolute path to the server CLI entry point.
    ///   - dataDir: Absolute path to the Oppi data directory.
    ///   - extraArgs: Additional arguments inserted before the CLI path
    ///     (e.g. `["watch"]` for tsx watch mode).
    func start(nodePath: String, cliPath: String, dataDir: String, extraArgs: [String] = []) {
        guard state == .stopped || isFailedState else {
            logger.warning("Cannot start server from state: \(String(describing: self.state))")
            return
        }

        state = .starting
        isIntentionalStop = false
        logger.info("Starting server: node=\(nodePath) cli=\(cliPath) data=\(dataDir) extra=\(extraArgs)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = extraArgs + [cliPath, "serve", "--data-dir", dataDir]

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

        openLogFile()

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
    ///
    /// Accepts `.starting` (normal startup), `.stopped` (adopt existing server),
    /// and `.failed` (recovery after crash auto-restart).
    func markRunning() {
        switch state {
        case .running:
            return
        case .stopping:
            // Don't override an intentional stop in progress.
            return
        case .starting, .stopped, .failed:
            let previous = state
            state = .running
            restartAttempts = 0
            logger.info("Server marked as running (was \(String(describing: previous)))")
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

    // MARK: - Persistent log file

    /// Path to the persistent server log file.
    static var logFilePath: String {
        NSString("~/.config/oppi/server.log").expandingTildeInPath
    }

    /// Path to the rotated (previous) log file.
    private static var rotatedLogFilePath: String {
        NSString("~/.config/oppi/server.log.1").expandingTildeInPath
    }

    /// Open (or rotate + reopen) the persistent log file.
    private func openLogFile() {
        let path = Self.logFilePath
        let fm = FileManager.default

        // Rotate if over size limit
        if fm.fileExists(atPath: path),
           let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64,
           size > Self.maxLogFileSize {
            let rotated = Self.rotatedLogFilePath
            try? fm.removeItem(atPath: rotated)
            try? fm.moveItem(atPath: path, toPath: rotated)
            logger.info("Rotated server log (\(size) bytes)")
        }

        // Create if needed
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            logger.error("Failed to open server log file at \(path)")
            return
        }
        handle.seekToEndOfFile()

        // Write a separator for this run
        let header = "\n--- server start \(ISO8601DateFormatter().string(from: Date())) ---\n"
        if let data = header.data(using: .utf8) {
            handle.write(data)
        }

        logFileHandle = handle
    }

    /// Close the persistent log file.
    private func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    /// Write raw text to the persistent log file.
    private func writeToLogFile(_ text: String, stream: Stream) {
        guard let handle = logFileHandle,
              let data = text.data(using: .utf8) else { return }
        handle.write(data)
    }

    // MARK: - Pipe handling

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
                self?.writeToLogFile(text, stream: stream)
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
        let reason = proc.terminationReason
        let signal = reason == .uncaughtSignal ? " (signal)" : ""
        logger.error("Server process exited: status=\(status)\(signal) reason=\(reason.rawValue)")

        cleanup()

        guard !isIntentionalStop else {
            state = .stopped
            return
        }

        // Log recent stderr lines so crash reason survives in os_log
        let recentStderr = logBuffer.suffix(20)
            .filter { $0.stream == .stderr }
            .map(\.text)
            .joined(separator: "\n")
        if !recentStderr.isEmpty {
            logger.error("Last stderr before exit:\n\(recentStderr)")
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
        closeLogFile()
        process = nil
    }
}
