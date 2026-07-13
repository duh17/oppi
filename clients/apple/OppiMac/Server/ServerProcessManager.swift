import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OppiMac", category: "ServerProcessManager")

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

    enum ProcessOwner: Sendable, Equatable {
        case none
        case childProcess
        case externalProcess
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
    private(set) var processOwner: ProcessOwner = .none
    private(set) var logBuffer: [LogLine] = []

    #if DEBUG
    /// Test-only: override state for unit test setup.
    func _setStateForTesting(_ newState: State) { state = newState }

    /// Test-only: override owner for unit test setup.
    func _setProcessOwnerForTesting(_ newOwner: ProcessOwner) { processOwner = newOwner }

    /// Test-only: inject log lines for buffer cap / clear testing.
    func _appendLogLinesForTesting(_ lines: [LogLine]) { appendLogLines(lines) }

    /// Test-only: redirect persistent server logs away from the user's data dir.
    static func _setLogFilePathForTesting(_ path: String?) { logFilePathOverrideForTesting = path }

    /// Test-only: exercise persistent log rotation without spawning a process.
    func _openLogFileForTesting() { openLogFile() }
    func _writeToLogFileForTesting(_ text: String) { writeToLogFile(text, stream: .stdout) }
    func _closeLogFileForTesting() { closeLogFile() }
    static var _maxLogFileSizeForTesting: UInt64 { maxLogFileSize }
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
    private var logFileSize: UInt64 = 0
    private var restartAttempts = 0
    private var isIntentionalStop = false

    /// Maximum size for the persistent log file before rotation (5 MB).
    private static let maxLogFileSize: UInt64 = 5 * 1024 * 1024

    #if DEBUG
    private static var logFilePathOverrideForTesting: String?
    #endif

    // MARK: - Path resolution

    /// Shared server data directory used by the Mac app and the npm-installed CLI.
    static let serverDataDir: String = {
        NSString("~/.config/oppi").expandingTildeInPath
    }()

    /// Resolves the single npm-installed `oppi` CLI.
    ///
    /// `OPPI_SERVER_PATH` remains an explicit source-checkout override for local
    /// development. Production app launches otherwise use the same global CLI
    /// that a human gets from `npm install -g oppi-server`.
    static func resolveServerCLIPath(
        environment: [String: String] = ProcessRunner.augmentedEnvironment
    ) -> String? {
        if let envPath = environment["OPPI_SERVER_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathEntries {
            let candidate = (directory as NSString).appendingPathComponent("oppi")
            if FileManager.default.isExecutableFile(atPath: candidate),
               isNpmOppiCLI(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func isNpmOppiCLI(_ path: String) -> Bool {
        guard let package = npmPackageMetadata(forCLIPath: path) else { return false }
        return package.name == "oppi-server" && package.bin?["oppi"] == "dist/src/cli.js"
    }

    private static func npmPackageMetadata(forCLIPath path: String) -> NpmPackageMetadata? {
        let packageURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL) else { return nil }
        return try? JSONDecoder().decode(NpmPackageMetadata.self, from: data)
    }

    private struct NpmPackageMetadata: Decodable {
        let name: String
        let bin: [String: String]?
        let engines: [String: String]?
    }

    /// Resolves the Node.js runtime binary path.
    ///
    /// Search order:
    /// 1. Homebrew Node.js
    /// 2. /usr/local Node.js
    /// 3. System Node.js
    ///
    /// Returns nil when Node.js is missing or does not satisfy the server's
    /// declared minimum version in package.json.
    static func resolveRuntimePath() -> String? {
        guard let nodePath = resolveNodePath() else {
            return nil
        }
        guard runtimeCompatibilityIssue(nodePath: nodePath) == nil else {
            return nil
        }
        return nodePath
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

    /// Human-readable runtime failure reason for onboarding and launch errors.
    static func runtimeFailureReason() -> String {
        guard let nodePath = resolveNodePath() else {
            if let required = minimumRequiredNodeVersion() {
                return "Node.js \(required) or newer not found"
            }
            return "Node.js not found"
        }
        return runtimeCompatibilityIssue(nodePath: nodePath) ?? "Node.js runtime unavailable"
    }

    private static func runtimeCompatibilityIssue(nodePath: String) -> String? {
        guard let required = minimumRequiredNodeVersion() else {
            return nil
        }
        guard let installed = nodeVersion(at: nodePath) else {
            return "Could not read Node.js version at \(nodePath)"
        }
        guard installed >= required else {
            return "Node.js \(installed) found, but Oppi requires Node.js \(required) or newer"
        }
        return nil
    }

    private static func minimumRequiredNodeVersion() -> SemanticVersion? {
        guard let cliPath = resolveServerCLIPath(),
              let nodeRange = npmPackageMetadata(forCLIPath: cliPath)?.engines?["node"] else {
            return nil
        }
        return SemanticVersion.minimumVersion(in: nodeRange)
    }

    private static func nodeVersion(at path: String) -> SemanticVersion? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return SemanticVersion(output)
    }

    private struct SemanticVersion: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ raw: String) {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
            let majorToken = parts.indices.contains(0) ? String(parts[0]) : "0"
            let minorToken = parts.indices.contains(1) ? String(parts[1]) : "0"
            let patchToken = parts.indices.contains(2) ? String(parts[2]) : "0"
            guard let major = Int(majorToken),
                  let minor = Int(minorToken),
                  let patch = Int(patchToken) else {
                return nil
            }
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }

        var description: String { "\(major).\(minor).\(patch)" }

        static func minimumVersion(in range: String) -> SemanticVersion? {
            let trimmed = range.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = trimmed.range(of: #">=\s*([0-9]+(?:\.[0-9]+){0,2})"#, options: .regularExpression) else {
                return nil
            }
            let token = String(trimmed[match]).replacingOccurrences(of: ">=", with: "")
            return SemanticVersion(token)
        }
    }

    // MARK: - Lifecycle

    /// Kill any existing server process and stale Bonjour advertisements.
    ///
    /// On launch the Mac app may find orphaned `node cli.js serve` or `dns-sd`
    /// processes from a prior app instance. This cleans them up so we can spawn
    /// a fresh server with full lifecycle control (termination handler, pipes, logs).
    static func killExistingServer() {
        // Find server processes matching our CLI pattern.
        let serverPids = pidsMatching(pattern: "(node|bun).*cli\\.js.*serve")
        for pid in serverPids {
            logger.warning("Killing existing server process (pid \(pid))")
            kill(pid, SIGTERM)
        }

        // Find stale dns-sd Bonjour advertisements for oppi.
        let dnsPids = pidsMatching(pattern: "dns-sd.*_oppi._tcp")
        for pid in dnsPids {
            logger.warning("Killing stale dns-sd process (pid \(pid))")
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

    static func retiredRuntimeServerIsRunning() -> Bool {
        !pidsMatching(pattern: "(node|bun).*(server-runtime|server-seed).*cli\\.js.*serve").isEmpty
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

    /// Start the npm-installed server using default resolved paths.
    func startWithDefaults() {
        guard let runtimePath = Self.resolveRuntimePath() else {
            let reason = Self.runtimeFailureReason()
            state = .failed(reason)
            logger.error("\(reason, privacy: .public)")
            return
        }
        guard let cliPath = Self.resolveServerCLIPath() else {
            state = .failed("Server CLI not found")
            logger.error("Oppi CLI not found — run npm install -g oppi-server")
            return
        }
        let dataDir = Self.serverDataDir

        start(nodePath: runtimePath, cliPath: cliPath, dataDir: dataDir)
    }

    /// Spawn the server process.
    ///
    /// - Parameters:
    ///   - nodePath: Absolute path to the Node.js binary.
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
        logger.warning("Starting server: node=\(nodePath) cli=\(cliPath) data=\(dataDir) extra=\(extraArgs)")

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
            processOwner = .childProcess
            logger.warning("Server process launched (pid \(proc.processIdentifier))")
        } catch {
            processOwner = .none
            state = .failed(error.localizedDescription)
            logger.error("Failed to launch server process: \(error.localizedDescription)")
        }
    }

    /// Gracefully stop the server: SIGTERM, then SIGKILL after 5 seconds.
    func stop() async {
        guard processOwner == .childProcess else {
            detachExternalServer()
            return
        }

        guard let proc = process, proc.isRunning else {
            cleanup()
            processOwner = .none
            state = .stopped
            return
        }

        state = .stopping
        isIntentionalStop = true
        logger.warning("Stopping server (pid \(proc.processIdentifier))")

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
        logger.warning("Server stopped")
    }

    func detachExternalServer() {
        guard processOwner != .childProcess else { return }
        cleanup()
        processOwner = .none
        state = .stopped
        logger.warning("Detached from external server")
    }

    func markFailed(_ reason: String) {
        cleanup()
        processOwner = .none
        state = .failed(reason)
        logger.error("Server marked failed: \(reason, privacy: .public)")
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
            if processOwner == .none {
                processOwner = .externalProcess
            }
            state = .running
            restartAttempts = 0
            logger.warning("Server marked as running (was \(String(describing: previous)))")
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

    static func isAddressInUseFailure(_ stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("eaddrinuse")
            || normalized.contains("address already in use")
    }

    // MARK: - Persistent log file

    /// Path to the persistent server log file.
    static var logFilePath: String {
        #if DEBUG
        if let override = logFilePathOverrideForTesting { return override }
        #endif
        return NSString("~/.config/oppi/server.log").expandingTildeInPath
    }

    /// Path to the rotated (previous) log file.
    private static var rotatedLogFilePath: String {
        "\(logFilePath).1"
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
            logger.warning("Rotated server log (\(size) bytes)")
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
        logFileSize = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        logFileHandle = handle

        writeLogFileHeader("server start")
    }

    /// Close the persistent log file.
    private func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
        logFileSize = 0
    }

    private func writeLogFileHeader(_ label: String) {
        let header = "\n--- \(label) \(ISO8601DateFormatter().string(from: Date())) ---\n"
        guard let data = header.data(using: .utf8) else { return }
        logFileHandle?.write(data)
        logFileSize += UInt64(data.count)
    }

    private func persistentLogData(for text: String) -> Data? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard data.count <= Self.maxLogFileSize else {
            let suffixByteCount = Int(Self.maxLogFileSize / 2)
            let notice = "\n--- log chunk truncated: \(data.count) bytes exceeded \(Self.maxLogFileSize) byte file cap ---\n"
            var truncated = Data(notice.utf8)
            truncated.append(contentsOf: data.suffix(suffixByteCount))
            return truncated
        }
        return data
    }

    private func rotateLogFileIfNeeded(additionalBytes: UInt64) {
        guard logFileSize + additionalBytes > Self.maxLogFileSize else { return }

        try? logFileHandle?.close()
        logFileHandle = nil

        let path = Self.logFilePath
        let rotated = Self.rotatedLogFilePath
        let fm = FileManager.default
        try? fm.removeItem(atPath: rotated)
        if fm.fileExists(atPath: path) {
            try? fm.moveItem(atPath: path, toPath: rotated)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            logFileSize = 0
            logger.error("Failed to reopen server log file at \(path)")
            return
        }
        handle.seekToEndOfFile()
        logFileHandle = handle
        logFileSize = 0
        writeLogFileHeader("server log rotated")
        logger.warning("Rotated server log while running")
    }

    /// Write raw text to the persistent log file.
    private func writeToLogFile(_ text: String, stream: Stream) {
        guard let data = persistentLogData(for: text) else { return }
        rotateLogFileIfNeeded(additionalBytes: UInt64(data.count))
        guard let handle = logFileHandle else { return }
        handle.write(data)
        logFileSize += UInt64(data.count)
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

        if Self.isAddressInUseFailure(recentStderr) {
            processOwner = .none
            state = .failed("Port 7749 is already in use by another server")
            logger.error("Server port is already in use; not auto-restarting")
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
        closeLogFile()
        process = nil
        if processOwner == .childProcess {
            processOwner = .none
        }
    }

}
