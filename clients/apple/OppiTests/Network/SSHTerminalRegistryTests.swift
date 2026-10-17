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
        /// Stands in for the app's preferences; the registry watches its flag.
        let defaults = UserDefaults(suiteName: "SSHTerminalRegistryTests.\(UUID().uuidString)")!
        static let flag = "sshTerminalEnabled"

        init(denyBackgroundTask: Bool = false) {
            tasks.denies = denyBackgroundTask
            defaults.set(true, forKey: Self.flag)
            let defaults = defaults
            registry = SSHTerminalRegistry(
                backgroundTasks: tasks, sleep: { [gate] _ in try await gate.wait() },
                defaults: defaults, experimentEnabled: { defaults.bool(forKey: Self.flag) }
            )
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

    /// The Settings toggle only writes the flag; no SSH screen is mounted to react.
    @Test func turningTheExperimentOffEndsTerminalsAndConnectsWithNoViewMounted() async throws {
        let harness = Harness()
        let live = try harness.open()
        let attempt = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let recorder = AttemptRecorder()
        harness.registry.track(attempt: UUID(), task: attempt) { recorder.ends.append($0) }

        harness.defaults.set(false, forKey: Harness.flag)
        try await waitUntil { !live.channel.connected }
        #expect(live.channel.reason == "SSH Terminal was turned off.")
        #expect(harness.registry.terminal(for: live.profile.id) == nil)
        #expect(attempt.isCancelled)
        #expect(recorder.ends == [.experimentDisabled])

        // A connect that was already past its last check is refused too.
        let late = try SSHTerminalChannel()
        let lateConnection = FakeConnection()
        late.opened(lateConnection)
        #expect(!harness.registry.adopt(late, profile: live.profile, queue: SSHTerminalEventQueue()))
        #expect(!late.connected && lateConnection.closed.withLock { $0 })
    }

    @Test func otherPreferenceChangesLeaveTerminalsAlone() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.defaults.set("x", forKey: "unrelated")
        for _ in 0..<20 { await Task.yield() }
        #expect(live.channel.connected)
        live.channel.close(reason: "done")
    }

    // MARK: - Connects in flight

    @Test func aConnectInFlightIsCancelledWhenOppiEntersTheBackground() async throws {
        let harness = Harness()
        let attempt = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let recorder = AttemptRecorder()
        harness.registry.track(attempt: UUID(), task: attempt) { recorder.ends.append($0) }
        harness.registry.appDidEnterBackground()
        #expect(attempt.isCancelled)
        #expect(recorder.ends == [.background])
        // Done once: a finished attempt is not cancelled again.
        harness.registry.appDidEnterBackground()
        #expect(recorder.ends == [.background])
        #expect(harness.tasks.began == 0)
    }

    @Test func aConnectThatFinishedItsAttemptIsNotCancelledLater() async throws {
        let harness = Harness()
        let attempt = Task<Void, Never> {}
        let recorder = AttemptRecorder()
        let id = UUID()
        harness.registry.track(attempt: id, task: attempt) { recorder.ends.append($0) }
        harness.registry.untrack(attempt: id)
        harness.registry.appDidEnterBackground()
        #expect(recorder.ends.isEmpty)
    }

    @Test func aConnectThatOpensInTheBackgroundWithNoGraceIsDiscarded() async throws {
        let harness = Harness()
        harness.registry.appDidEnterBackground()
        let channel = try SSHTerminalChannel()
        let connection = FakeConnection()
        channel.opened(connection)
        let profile = SSHTerminalProfile(host: "one.ts.net", username: "alice")
        #expect(!harness.registry.adopt(channel, profile: profile, queue: SSHTerminalEventQueue()))
        #expect(!channel.connected)
        #expect(channel.closedForBackground)
        #expect(connection.closed.withLock { $0 })
        #expect(!harness.registry.holds(channel))
        #expect(harness.registry.terminal(for: profile.id) == nil)

        // Back in front, a connect is adopted again.
        harness.registry.appDidBecomeActive()
        let next = try SSHTerminalChannel()
        next.opened(FakeConnection())
        #expect(harness.registry.adopt(next, profile: profile, queue: SSHTerminalEventQueue()))
        next.close(reason: "done")
    }

    @Test func aConnectThatOpensDuringTheGraceIsClosedWithTheOthersWhenItEnds() async throws {
        let harness = Harness()
        let first = try harness.open()
        harness.registry.appDidEnterBackground()
        let second = try harness.open(SSHTerminalProfile(host: "two.ts.net", username: "alice"))
        #expect(second.channel.connected)
        harness.gate.open()
        await harness.tasks.waitForEnd()
        #expect(!first.channel.connected && !second.channel.connected)
    }

    /// A reconnect from the terminal screen has no host-list view mounted; its
    /// channel is the one the screen shows and must read as closed for the background.
    @Test func aSessionConnectCancelledByTheBackgroundClosesItsChannelForTheBackground() async throws {
        let harness = Harness()
        let session = SSHTerminalConnectSession(registry: harness.registry)
        let pending = try SSHTerminalChannel()
        session.channel = pending
        session.connecting = true
        session.handleBackground()
        #expect(!session.connecting)
        #expect(pending.closedForBackground && !pending.connected && !pending.connecting)
        #expect(session.failure == SSHTerminalConnectSession.backgroundFailure)
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

    @Test func iOSExpirationClosesOnTheWireBeforeEndingTheTask() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        var closedWhenTaskEnded: Bool?
        harness.tasks.atEnd = { closedWhenTaskEnded = live.connection.closed.withLock { $0 } }
        harness.tasks.expire()
        #expect(!live.channel.connected)
        #expect(live.channel.closedForBackground)
        #expect(harness.tasks.endedCount == 1)
        // The close was submitted before the process could suspend, not left to a later task.
        #expect(closedWhenTaskEnded == true)
        // The timer arriving afterwards cannot end the task a second time.
        harness.gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.tasks.endedCount == 1)
    }

    /// iOS may run the handler before `beginBackgroundTask` returns.
    @Test func expirationInsideBeginStillClosesAndEndsTheTaskOnce() async throws {
        let harness = Harness()
        harness.tasks.expireInsideBegin = true
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        #expect(!live.channel.connected)
        #expect(live.channel.closedForBackground)
        #expect(harness.tasks.endedIDs == [harness.tasks.identifier])
        harness.gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.tasks.endedCount == 1)
    }

    /// A handler left over from a grace that already ended must not close what
    /// is running now.
    @Test func aStaleExpirationAfterReturnLeavesTerminalsAlone() async throws {
        let harness = Harness()
        let live = try harness.open()
        harness.registry.appDidEnterBackground()
        harness.registry.appDidBecomeActive()
        #expect(harness.tasks.endedCount == 1)
        harness.tasks.expire()
        #expect(live.channel.connected)
        #expect(!live.channel.closedForBackground)
        #expect(harness.registry.terminal(for: live.profile.id)?.channel === live.channel)
        #expect(harness.tasks.endedCount == 1)
        live.channel.close(reason: "done")
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

@MainActor
private final class AttemptRecorder {
    var ends = [SSHTerminalRegistry.AttemptEnd]()
}

private final class FakeConnection: SSHTerminalConnection {
    let cancelled = Mutex(false)
    /// `close()` submitted: on the wire, whether or not anyone awaited it.
    let closed = Mutex(false)
    func close() { closed.withLock { $0 = true } }
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
    /// Runs the expiration handler before `begin` returns.
    var expireInsideBegin = false
    var atEnd: (() -> Void)?
    let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
    private(set) var began = 0
    private(set) var endedCount = 0
    private(set) var endedIDs = [UIBackgroundTaskIdentifier]()
    private var expiration: (@MainActor () -> Void)?
    private var endWaiter: CheckedContinuation<Void, Never>?

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        guard !denies else { return nil }
        began += 1
        self.expiration = expiration
        if expireInsideBegin { expiration() }
        return identifier
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        endedCount += 1
        endedIDs.append(task)
        atEnd?()
        endWaiter?.resume()
        endWaiter = nil
    }

    func expire() { expiration?() }

    func waitForEnd() async {
        guard endedCount == 0 else { return }
        await withCheckedContinuation { endWaiter = $0 }
    }
}
