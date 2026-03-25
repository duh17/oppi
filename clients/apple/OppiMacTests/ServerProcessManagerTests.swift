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

    @Test func resolveServerCLIPathFindsRepoCLI() {
        let path = ServerProcessManager.resolveServerCLIPath()
        #expect(path != nil, "Server CLI should be found on the build machine")
        if let path {
            #expect(path.hasSuffix("cli.js"))
        }
    }

    @Test func logFilePathEndsWithServerLog() {
        let path = ServerProcessManager.logFilePath
        #expect(path.hasSuffix("server.log"))
        #expect(path.contains("oppi"))
    }
}

// MARK: - Process lifecycle (integration — uses /bin/sleep)

@Suite("ServerProcessManager — process lifecycle")
@MainActor
struct ProcessLifecycleTests {

    @Test func startTransitionsToStartingThenStopWorks() async {
        let pm = ServerProcessManager()
        #expect(pm.state == .stopped)

        // Launch a real but harmless process.
        pm.start(nodePath: "/bin/sleep", cliPath: "60", dataDir: "/tmp")

        // start() sets .starting, then proc.run() succeeds (sleep is a valid binary).
        // Note: the cliPath becomes an argument to sleep, so this runs "sleep 60".
        #expect(pm.state == .starting)

        await pm.stop()

        #expect(pm.state == .stopped)
    }

    @Test func stopFromStoppedIsNoOp() async {
        let pm = ServerProcessManager()
        #expect(pm.state == .stopped)

        await pm.stop()

        #expect(pm.state == .stopped)
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

        await pm.stop()
        #expect(pm.state == .stopped)
    }
}
