import Foundation
import Synchronization
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal registry", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalRegistryTests {
    @MainActor
    private struct Harness {
        let registry: SSHTerminalRegistry
        let tasks = FakeBackgroundTasks()
        let gate = SleepGate()

        init(denyBackgroundTask: Bool = false) {
            tasks.denies = denyBackgroundTask
            registry = SSHTerminalRegistry(backgroundTasks: tasks, sleep: { [gate] _ in try await gate.wait() })
        }

        /// A live terminal for a saved host, with its byte queue.
        func open(_ profile: SSHTerminalProfile = SSHTerminalProfile(host: "one.ts.net", username: "alice"))
            throws -> (channel: SSHTerminalChannel, queue: SSHTerminalEventQueue, connection: FakeConnection, profile: SSHTerminalProfile) {
            let channel = try SSHTerminalChannel()
            let connection = FakeConnection()
            let queue = SSHTerminalEventQueue()
            channel.opened(connection)
            registry.adopt(channel, profile: profile, queue: queue)
            return (channel, queue, connection, profile)
        }
    }

    @Test func aTerminalStaysLiveForItsHostUntilExplicitDisconnect() async throws {
        let harness = Harness()
        let live = try harness.open()
        #expect(harness.registry.terminal(for: live.profile.id)?.channel === live.channel)
        #expect(harness.registry.isLive(live.profile.id))
        // Disconnect in the terminal's menu.
        live.channel.close(reason: "Closed by you.")
        #expect(harness.registry.terminal(for: live.profile.id) == nil)
        #expect(!harness.registry.isLive(live.profile.id))
    }

    @Test func aRemoteShellExitEndsTheTerminal() async throws {
        let harness = Harness()
        let live = try harness.open()
        live.queue.push(.exitStatus(0))
        try await waitUntil { !live.channel.connected }
        #expect(harness.registry.terminal(for: live.profile.id) == nil)
        #expect(live.channel.reason.contains("exited with status 0"))
        try await waitUntil { !harness.registry.holds(live.channel) }
    }

    @Test func outputIsReadWhileNoScreenShowsTheTerminal() async throws {
        let harness = Harness()
        let live = try harness.open()
        live.queue.push(.data(Data("read-offscreen".utf8)))
        try await waitUntil { rowText(live.channel) == "read-offscreen" }
        live.channel.close(reason: "done")
    }

    @Test func oneTerminalPerHostAndANewConnectionReplacesIt() async throws {
        let harness = Harness()
        let first = try harness.open()
        let other = try harness.open(SSHTerminalProfile(host: "two.ts.net", username: "alice"))
        let replacement = try SSHTerminalChannel()
        replacement.opened(FakeConnection())
        harness.registry.adopt(replacement, profile: first.profile, queue: SSHTerminalEventQueue())
        #expect(!first.channel.connected)
        #expect(first.channel.reason == "Replaced by a new connection.")
        #expect(harness.registry.terminal(for: first.profile.id)?.channel === replacement)
        #expect(other.channel.connected)
        harness.registry.closeAll(reason: "done")
        #expect(!replacement.connected && !other.channel.connected)
    }

    @Test func editingOrDeletingTheHostEndsItButAnUnchangedSaveDoesNot() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.reconcile(saved: live.profile)
        #expect(live.channel.connected)
        var edited = live.profile
        edited.startupCommand = "herdr"
        harness.registry.reconcile(saved: edited)
        #expect(!live.channel.connected)

        let doomed = try harness.open()
        harness.registry.close(doomed.profile.id, reason: "The host was deleted.")
        #expect(doomed.channel.reason == "The host was deleted.")
        #expect(harness.registry.terminal(for: doomed.profile.id) == nil)
    }

    @Test func connectingAHostWithALiveTerminalAttachesToItWithoutDialing() async throws {
        let harness = Harness()
        let live = try harness.open()
        let session = SSHTerminalConnectSession(registry: harness.registry)
        session.connect(profile: live.profile, experimentEnabled: true)
        #expect(session.showsTerminal)
        #expect(session.channel === live.channel)
        #expect(!session.connecting)
        #expect(session.failure == nil)
        // The session going away does not take the terminal with it.
        session.cancel()
        session.showsTerminal = false
        #expect(live.channel.connected)
        live.channel.close(reason: "done")
    }

    @Test func turningTheExperimentOffEndsEveryTerminal() async throws {
        let harness = Harness()
        let live = try harness.open()
        SSHTerminalConnectSession(registry: harness.registry).handleExperimentDisabled()
        #expect(!live.channel.connected)
    }

    // MARK: - Background grace

    @Test func graceKeepsTerminalsRunningAndReadingThenClosesBeforeSuspension() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        #expect(harness.tasks.began == 1)
        // Still connected and still reading: no bytes are lost during the grace.
        live.queue.push(.data(Data("during-grace".utf8)))
        try await waitUntil { rowText(live.channel) == "during-grace" }
        #expect(live.channel.connected)
        #expect(harness.tasks.endedCount == 0)

        harness.gate.open()
        await harness.tasks.waitForEnd()
        #expect(!live.channel.connected)
        #expect(live.channel.closedForBackground)
        #expect(live.channel.reason == "Oppi went to the background.")
        // The background task outlives the connection's teardown.
        #expect(live.connection.cancelled.withLock { $0 })
        #expect(harness.tasks.endedCount == 1)
    }

    @Test func returningWithinTheGraceChangesNothing() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        harness.registry.appDidBecomeActive()
        #expect(harness.tasks.endedCount == 1)
        // The grace timer firing late does not close anything.
        harness.gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(live.channel.connected)
        #expect(!live.channel.closedForBackground)
        #expect(harness.registry.terminal(for: live.profile.id)?.channel === live.channel)
        live.channel.close(reason: "done")
    }

    @Test func iOSExpirationClosesAtOnceAndEndsTheTask() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        harness.tasks.expire()
        #expect(!live.channel.connected)
        #expect(live.channel.closedForBackground)
        #expect(harness.tasks.endedCount == 1)
        // The timer arriving afterwards cannot end the task a second time.
        harness.gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.tasks.endedCount == 1)
    }

    @Test func withoutABackgroundTaskTerminalsCloseImmediately() async throws {
        let harness = Harness(denyBackgroundTask: true)
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        #expect(!live.channel.connected)
        #expect(live.channel.closedForBackground)
    }

    @Test func noLiveTerminalMeansNoBackgroundTask() async throws {
        let harness = Harness()
        harness.registry.appDidEnterBackground()
        #expect(harness.tasks.began == 0)
        let live = try harness.open()
        live.channel.close(reason: "done")
        harness.registry.appDidEnterBackground()
        #expect(harness.tasks.began == 0)
    }

    @Test func aSecondBackgroundEntryDuringTheGraceDoesNotStartAnotherTask() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        harness.registry.appDidEnterBackground()
        #expect(harness.tasks.began == 1)
        harness.registry.appDidBecomeActive()
        live.channel.close(reason: "done")
    }
}

// MARK: - Fixtures

@MainActor
private func rowText(_ channel: SSHTerminalChannel) -> String {
    channel.engine.frame().rows[0].map(\.text).joined().trimmingCharacters(in: .whitespaces)
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition was not met within 2 seconds")
}

private final class FakeConnection: SSHTerminalConnection {
    let cancelled = Mutex(false)
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    func cancel() async { cancelled.withLock { $0 = true } }
}

/// Holds the grace timer until the test opens the gate.
private final class SleepGate: Sendable {
    private let stream: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation

    init() { (stream, sink) = AsyncStream.makeStream() }

    func wait() async throws {
        for await _ in stream { break }
        try Task.checkCancellation()
    }

    func open() { sink.yield(()) }
}

@MainActor
private final class FakeBackgroundTasks: SSHBackgroundTasks {
    var denies = false
    private(set) var began = 0
    private(set) var endedCount = 0
    private var expiration: (@MainActor () -> Void)?
    private var endWaiter: CheckedContinuation<Void, Never>?

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        guard !denies else { return nil }
        began += 1
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: 42)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        endedCount += 1
        endWaiter?.resume()
        endWaiter = nil
    }

    func expire() { expiration?() }

    func waitForEnd() async {
        guard endedCount == 0 else { return }
        await withCheckedContinuation { endWaiter = $0 }
    }
}
