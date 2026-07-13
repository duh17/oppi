import Testing
import Foundation
@testable import Oppi

// MARK: - markRunning state transitions

@Suite("ServerProcessManager — markRunning")
@MainActor
struct MarkRunningTests {

    @Test("transitions to .running from recoverable states",
          arguments: [
            ServerProcessManager.State.stopped,
            .starting,
            .failed("Crashed (exit 1)"),
            .failed(""),
          ])
    func markRunningTransitions(from initial: ServerProcessManager.State) {
        let pm = ServerProcessManager()
        pm._setStateForTesting(initial)

        pm.markRunning()

        #expect(pm.state == .running)
        #expect(pm.processOwner == .externalProcess)
    }

    @Test func markRunningPreservesChildProcessOwner() {
        let pm = ServerProcessManager()
        pm._setStateForTesting(.starting)
        pm._setProcessOwnerForTesting(.childProcess)

        pm.markRunning()

        #expect(pm.state == .running)
        #expect(pm.processOwner == .childProcess)
    }

    @Test("no-op from non-recoverable states",
          arguments: [
            ServerProcessManager.State.running,
            .stopping,
          ])
    func markRunningNoOp(from initial: ServerProcessManager.State) {
        let pm = ServerProcessManager()
        pm._setStateForTesting(initial)

        pm.markRunning()

        #expect(pm.state == initial)
    }
}

// MARK: - start() guard conditions

@Suite("ServerProcessManager — start guard")
@MainActor
struct StartGuardTests {

    /// States that should block a start attempt (state unchanged).
    @Test("rejects start from active states",
          arguments: [
            ServerProcessManager.State.starting,
            .running,
            .stopping,
          ])
    func startRejected(from initial: ServerProcessManager.State) {
        let pm = ServerProcessManager()
        pm._setStateForTesting(initial)

        // Use a bogus path — we only care about the guard, not the launch.
        pm.start(nodePath: "/nonexistent", cliPath: "/nonexistent", dataDir: "/tmp")

        #expect(pm.state == initial, "State should not change when starting from \(initial)")
    }

    /// States that should allow a start attempt (transitions to .starting, then
    /// .failed because the binary does not exist).
    @Test("accepts start from idle states",
          arguments: [
            ServerProcessManager.State.stopped,
            .failed("previous crash"),
          ])
    func startAccepted(from initial: ServerProcessManager.State) {
        let pm = ServerProcessManager()
        pm._setStateForTesting(initial)

        pm.start(nodePath: "/nonexistent-node", cliPath: "/nonexistent-cli", dataDir: "/tmp")

        // start() sets .starting then proc.run() throws → .failed
        if case .failed = pm.state {
            // expected: launch failed because the binary doesn't exist
        } else {
            Issue.record("Expected .failed after start with bogus path, got \(pm.state)")
        }
    }
}

// MARK: - Log buffer

@Suite("ServerProcessManager — log buffer")
@MainActor
struct LogBufferTests {

    @Test func clearLogsEmptiesBuffer() {
        let pm = ServerProcessManager()
        let lines = (0..<10).map { ServerProcessManager.LogLine(stream: .stdout, text: "line \($0)") }
        pm._appendLogLinesForTesting(lines)
        #expect(pm.logBuffer.count == 10)

        pm.clearLogs()

        #expect(pm.logBuffer.isEmpty)
    }

    @Test func bufferCapsAtMaxLogLines() {
        let pm = ServerProcessManager()
        let overflow = ServerProcessManager.maxLogLines + 500
        let lines = (0..<overflow).map {
            ServerProcessManager.LogLine(stream: .stderr, text: "line \($0)")
        }

        pm._appendLogLinesForTesting(lines)

        #expect(pm.logBuffer.count == ServerProcessManager.maxLogLines)
        // Oldest lines should be dropped — last line should be the final one.
        #expect(pm.logBuffer.last?.text == "line \(overflow - 1)")
        // First line should be the one just after the dropped ones.
        #expect(pm.logBuffer.first?.text == "line 500")
    }

    @Test func appendPreservesStreamType() {
        let pm = ServerProcessManager()
        pm._appendLogLinesForTesting([
            .init(stream: .stdout, text: "out"),
            .init(stream: .stderr, text: "err"),
        ])

        #expect(pm.logBuffer[0].stream == .stdout)
        #expect(pm.logBuffer[1].stream == .stderr)
    }

    @Test func persistentLogRotatesWhileRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-server-log-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            ServerProcessManager._setLogFilePathForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let logPath = root.appendingPathComponent("server.log").path
        let rotatedPath = "\(logPath).1"
        ServerProcessManager._setLogFilePathForTesting(logPath)

        let pm = ServerProcessManager()
        pm._openLogFileForTesting()
        let chunkSize = Int(ServerProcessManager._maxLogFileSizeForTesting / 2) + 1_024
        let chunk = String(repeating: "x", count: chunkSize)

        pm._writeToLogFileForTesting(chunk)
        pm._writeToLogFileForTesting(chunk)
        pm._closeLogFileForTesting()

        #expect(FileManager.default.fileExists(atPath: logPath))
        #expect(FileManager.default.fileExists(atPath: rotatedPath))

        let currentSize = try FileManager.default.attributesOfItem(atPath: logPath)[.size] as? UInt64
        let rotatedSize = try FileManager.default.attributesOfItem(atPath: rotatedPath)[.size] as? UInt64
        #expect((currentSize ?? 0) <= ServerProcessManager._maxLogFileSizeForTesting)
        #expect((rotatedSize ?? 0) <= ServerProcessManager._maxLogFileSizeForTesting)
    }
}

// MARK: - Path resolution

@Suite("ServerProcessManager — path resolution")
@MainActor
struct PathResolutionTests {

    @Test func resolveNodePathFindsNode() {
        let path = ServerProcessManager.resolveNodePath()
        #expect(path != nil, "Node.js should be found on the build machine")
        if let path {
            #expect(path.hasSuffix("/node"))
        }
    }

    @Test func resolveServerCLIPathUsesExplicitSourceOverride() {
        let path = ServerProcessManager.resolveServerCLIPath(environment: [
            "OPPI_SERVER_PATH": "/bin/sh",
            "PATH": "",
        ])
        #expect(path == "/bin/sh")
    }

    @Test func resolveServerCLIPathFindsValidatedNpmBinaryOnPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-npm-prefix-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let package = root.appendingPathComponent("lib/node_modules/oppi-server")
        let cli = package.appendingPathComponent("dist/src/cli.js")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "#!/usr/bin/env node\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try #"{"name":"oppi-server","bin":{"oppi":"dist/src/cli.js"},"engines":{"node":">=24.0.0"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let executable = bin.appendingPathComponent("oppi")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: cli)

        let path = ServerProcessManager.resolveServerCLIPath(environment: [
            "PATH": bin.path,
        ])
        #expect(path == executable.path)
    }

    @Test func resolveServerCLIPathRejectsUnrelatedExecutableNamedOppi() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrelated-oppi-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let executable = bin.appendingPathComponent("oppi")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let path = ServerProcessManager.resolveServerCLIPath(environment: [
            "PATH": bin.path,
        ])
        #expect(path == nil)
    }

    @Test func logFilePathEndsWithServerLog() {
        let path = ServerProcessManager.logFilePath
        #expect(path.hasSuffix("server.log"))
        #expect(path.contains("oppi"))
    }

}

// MARK: - Crash classification

@Suite("ServerProcessManager — crash classification")
@MainActor
struct CrashClassificationTests {
    @Test func detectsAddressAlreadyInUseFailures() {
        #expect(ServerProcessManager.isAddressInUseFailure(
            "Fatal error: listen EADDRINUSE: address already in use 0.0.0.0:7749"
        ))
        #expect(ServerProcessManager.isAddressInUseFailure(
            "Error: Address already in use"
        ))
    }

    @Test func ignoresUnrelatedFailures() {
        #expect(!ServerProcessManager.isAddressInUseFailure("SyntaxError: Unexpected token"))
    }
}

// MARK: - Process lifecycle (integration — uses /bin/sleep)

@Suite("ServerProcessManager — process lifecycle")
@MainActor
struct ProcessLifecycleTests {

    @Test func detachExternalServerStopsTrackingWithoutKillingAProcess() {
        let pm = ServerProcessManager()
        pm._setStateForTesting(.running)
        pm._setProcessOwnerForTesting(.externalProcess)

        pm.detachExternalServer()

        #expect(pm.state == .stopped)
        #expect(pm.processOwner == .none)
    }

    @Test func startTransitionsToStartingThenStopWorks() async {
        let pm = ServerProcessManager()
        #expect(pm.state == .stopped)

        // Launch a real but harmless process.
        pm.start(nodePath: "/bin/sleep", cliPath: "60", dataDir: "/tmp")

        // start() sets .starting, then proc.run() succeeds (sleep is a valid binary).
        // Note: the cliPath becomes an argument to sleep, so this runs "sleep 60".
        #expect(pm.state == .starting)
        #expect(pm.processOwner == .childProcess)

        await pm.stop()

        #expect(pm.state == .stopped)
        #expect(pm.processOwner == .none)
    }

    @Test func stopFromStoppedIsNoOp() async {
        let pm = ServerProcessManager()
        #expect(pm.state == .stopped)

        await pm.stop()

        #expect(pm.state == .stopped)
        #expect(pm.processOwner == .none)
    }

    @Test func startCapturesLogOutput() async throws {
        let pm = ServerProcessManager()

        // /bin/echo writes to stdout and exits immediately.
        pm.start(nodePath: "/bin/echo", cliPath: "hello from test", dataDir: "/tmp")

        // Give the pipe handler time to process the output.
        try await Task.sleep(for: .milliseconds(200))

        let hasOutput = pm.logBuffer.contains { $0.text.contains("hello from test") }
        #expect(hasOutput, "Log buffer should capture stdout from the child process")
    }

    @Test func startFromFailedStateRestartsCleanly() async {
        let pm = ServerProcessManager()
        pm._setStateForTesting(.failed("previous crash"))

        pm.start(nodePath: "/bin/sleep", cliPath: "60", dataDir: "/tmp")

        #expect(pm.state == .starting)
        #expect(pm.processOwner == .childProcess)

        await pm.stop()
        #expect(pm.state == .stopped)
        #expect(pm.processOwner == .none)
    }
}
