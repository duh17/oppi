import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "ProcessRunner")

/// Shared process-spawning utility for the Mac app.
///
/// Centralizes PATH augmentation (homebrew) and Process lifecycle
/// so onboarding views, health monitor, and doctor don't duplicate boilerplate.
enum ProcessRunner {

    /// Environment with homebrew paths prepended to PATH.
    static var augmentedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + current
        return env
    }

    /// Run a process and return (stdout, exitCode). Throws on launch failure.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the executable, or a command name resolved via `env`.
    ///   - arguments: Command-line arguments.
    ///   - environment: Process environment. Defaults to ``augmentedEnvironment``.
    /// - Returns: Tuple of stdout text and exit code.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (stdout: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = environment ?? augmentedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (output, proc.terminationStatus)
    }

    /// Locate a command via `which`, using augmented PATH.
    ///
    /// - Parameter command: Name of the command (e.g. "node", "pi").
    /// - Returns: Absolute path if found, nil otherwise.
    static func which(_ command: String) async -> String? {
        do {
            let result = try await run(
                executable: "/usr/bin/env",
                arguments: ["which", command]
            )
            guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
            return result.stdout
        } catch {
            logger.debug("which \(command) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get version output from an executable (e.g. `node --version`).
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - args: Arguments (typically `["--version"]`).
    /// - Returns: Version string or nil on failure.
    static func version(_ executablePath: String, args: [String] = ["--version"]) async -> String? {
        do {
            let result = try await run(executable: executablePath, arguments: args)
            guard result.exitCode == 0 else { return nil }
            return result.stdout
        } catch {
            return nil
        }
    }

    /// Read stderr from a failed process run. Useful for error messages.
    static func runCapturingStderr(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = environment ?? augmentedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutText = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (stdoutText, stderrText, proc.terminationStatus)
    }
}
