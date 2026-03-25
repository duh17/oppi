import Testing
import Foundation
@testable import Oppi

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    // MARK: - augmentedEnvironment

    @Test func augmentedEnvironmentIncludesHomebrewPath() {
        let env = ProcessRunner.augmentedEnvironment
        let path = env["PATH"] ?? ""

        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
    }

    @Test func augmentedEnvironmentPrependsHomebrewPaths() {
        let env = ProcessRunner.augmentedEnvironment
        let path = env["PATH"] ?? ""

        // Homebrew paths should come first so they shadow system binaries.
        #expect(path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"))
    }

    @Test func augmentedEnvironmentPreservesExistingVars() {
        let env = ProcessRunner.augmentedEnvironment

        // HOME should always be present in the inherited environment.
        #expect(env["HOME"] != nil)
    }

    // MARK: - run (integration, uses real binaries)

    @Test func runEchoReturnsOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["hello"]
        )

        #expect(result.stdout == "hello")
        #expect(result.exitCode == 0)
    }

    @Test func runFailingCommandReturnsNonZeroExit() async throws {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/false",
            arguments: []
        )

        #expect(result.exitCode != 0)
    }

    @Test func runThrowsForMissingExecutable() async {
        do {
            _ = try await ProcessRunner.run(
                executable: "/nonexistent/binary",
                arguments: []
            )
            Issue.record("Expected an error for missing executable")
        } catch {
            // expected
        }
    }

    @Test func runCapturingStderrCapturesBothStreams() async throws {
        // /bin/sh -c 'echo out; echo err >&2'
        let result = try await ProcessRunner.runCapturingStderr(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2"]
        )

        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
        #expect(result.exitCode == 0)
    }

    // MARK: - which (integration)

    @Test func whichFindsLs() async {
        let path = await ProcessRunner.which("ls")
        #expect(path != nil)
        if let path {
            #expect(path.hasSuffix("/ls"))
        }
    }

    @Test func whichReturnsNilForBogusCommand() async {
        let path = await ProcessRunner.which("definitely-not-a-real-command-\(UUID())")
        #expect(path == nil)
    }

    // MARK: - version (integration)

    @Test func versionReturnsNodeVersion() async {
        guard let nodePath = await ProcessRunner.which("node") else {
            return // skip if node not installed
        }
        let version = await ProcessRunner.version(nodePath)
        #expect(version != nil)
        if let version {
            #expect(version.hasPrefix("v"))
        }
    }
}
