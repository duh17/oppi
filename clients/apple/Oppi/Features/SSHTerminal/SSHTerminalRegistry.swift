import Foundation
import Observation
import UIKit

/// Starts and ends the background task that keeps live terminals running for
/// the grace period. `UIApplication` in the app; a fake in tests.
@MainActor
protocol SSHBackgroundTasks {
    /// Nil when iOS refuses. `expiration` runs on the main actor when iOS is
    /// about to suspend the process; the task must be ended by then.
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier?
    func end(_ task: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIApplicationBackgroundTasks: SSHBackgroundTasks {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        let task = UIApplication.shared.beginBackgroundTask(withName: "oppi.ssh.terminal.grace", expirationHandler: expiration)
        return task == .invalid ? nil : task
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Owns every live SSH terminal for the app, so a terminal outlives the screen
/// that opened it.
///
/// Lifetime of a terminal:
/// - It starts when a connect opens its shell (`adopt`). Leaving the screen
///   (Back, another tab, another session) does not touch it; showing that host's
///   terminal again attaches to the same channel and grid.
/// - It ends on Disconnect, when the remote shell or connection ends, when the
///   saved host is edited or deleted, when SSH Terminal is turned off, and when
///   the background grace ends.
///
/// Bound: one terminal per saved host profile, so at most as many as there are
/// saved hosts. Connecting a host that already has one replaces it. Terminals
/// that ended are dropped at once; none is kept for a closed shell.
///
/// Background: when Oppi enters the background with a live terminal, they keep
/// running and reading output for `backgroundGrace` under a background task.
/// Returning in time changes nothing. Otherwise, when the grace ends or iOS
/// calls the expiration handler, every terminal closes with "Oppi went to the
/// background." (`closedForBackground`) before the process can suspend. A terminal
/// that is on screen then reconnects on return.
///
/// A connect still in flight when Oppi enters the background is cancelled
/// (`track`), and a connect that finishes while Oppi is in the background with
/// no grace running is discarded (`adopt`): a live SSH session must never be
/// left for iOS to suspend.
///
/// The registry watches the SSH Terminal experiment flag itself, so turning it
/// off ends every terminal and connect even when no SSH screen is mounted.
@MainActor @Observable
final class SSHTerminalRegistry {
    static let shared = SSHTerminalRegistry()
    /// Shorter than the roughly 30 seconds iOS usually grants a background task.
    static let backgroundGrace: Duration = .seconds(25)

    struct Terminal {
        let profile: SSHTerminalProfile
        let channel: SSHTerminalChannel
        fileprivate let tasks: [Task<Void, Never>]
    }

    /// Why a tracked connect was cancelled from outside its screen.
    enum AttemptEnd { case background, experimentDisabled }

    private struct Attempt {
        let task: Task<Void, Never>
        let ended: @MainActor (AttemptEnd) -> Void
    }

    /// One background task and its grace timer. A class: the expiration
    /// handler may run before `begin` returns, and a stale handler must
    /// recognize it is not the current grace.
    private final class Grace {
        var identifier: UIBackgroundTaskIdentifier?
        var timer: Task<Void, Never>?
        /// The grace is finished; its background task is ended once its identifier is known.
        var over = false
        var taskEnded = false
    }

    private var terminals: [UUID: Terminal] = [:]
    @ObservationIgnored private var attempts: [UUID: Attempt] = [:]
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var grace: Grace?
    @ObservationIgnored private let backgroundTasks: any SSHBackgroundTasks
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let experimentEnabled: @MainActor () -> Bool
    @ObservationIgnored private var flagObserver: FlagObserver?

    /// Removes its notification observer when the registry goes away.
    private final class FlagObserver: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }

    init(
        backgroundTasks: any SSHBackgroundTasks = UIApplicationBackgroundTasks(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        defaults: UserDefaults = .standard,
        experimentEnabled: @escaping @MainActor () -> Bool = { AppPreferences.Experiments.sshTerminalEnabled }
    ) {
        self.backgroundTasks = backgroundTasks
        self.sleep = sleep
        self.experimentEnabled = experimentEnabled
        // The Settings toggle writes this flag; no SSH screen needs to be mounted to hear it.
        flagObserver = FlagObserver(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.experimentMayHaveChanged() }
        })
    }

    private func experimentMayHaveChanged() {
        guard !experimentEnabled() else { return }
        endEverything()
    }

    /// SSH Terminal is off: no terminal, no connect in flight, no kept approval.
    private func endEverything() {
        let pending = attempts
        attempts.removeAll()
        for attempt in pending.values {
            attempt.task.cancel()
            attempt.ended(.experimentDisabled)
        }
        closeAll(reason: "SSH Terminal was turned off.")
        SSHApprovalCache.shared.invalidateAll()
    }

    /// Registers a connect in flight under `id`. Oppi entering the background
    /// or SSH Terminal turning off cancels it and calls `ended`. The connect
    /// calls `untrack` when it finishes.
    func track(attempt id: UUID, task: Task<Void, Never>, ended: @escaping @MainActor (AttemptEnd) -> Void) {
        attempts[id] = Attempt(task: task, ended: ended)
    }

    func untrack(attempt id: UUID) { attempts[id] = nil }

    /// The connected terminal for a saved host, if any.
    func terminal(for profileID: UUID) -> Terminal? {
        guard let terminal = terminals[profileID], terminal.channel.connected else { return nil }
        return terminal
    }

    func isLive(_ profileID: UUID) -> Bool { terminal(for: profileID) != nil }

    /// Whether the registry holds this channel, connected or not yet dropped.
    func holds(_ channel: SSHTerminalChannel) -> Bool {
        terminals.values.contains { $0.channel === channel }
    }

    /// Takes over a channel whose shell just opened. Its output is read here
    /// from now on, whichever screen is showing.
    ///
    /// Refused (the channel is closed, its reason says why) while Oppi is in the
    /// background with no grace running, and while SSH Terminal is off: nothing
    /// would close that session before iOS suspends the process.
    @discardableResult
    func adopt(_ channel: SSHTerminalChannel, profile: SSHTerminalProfile, queue: SSHTerminalEventQueue) -> Bool {
        guard experimentEnabled() else {
            queue.finish()
            channel.close(reason: "SSH Terminal was turned off.")
            return false
        }
        guard !inBackground || grace != nil else {
            queue.finish()
            channel.closeForBackground()
            return false
        }
        close(profile.id, reason: "Replaced by a new connection.")
        let consumer = Task { [weak self] in
            await channel.consume(queue)
            self?.release(channel, of: profile.id)
        }
        // The screen's network watch ends with the screen; this one lasts as long as the terminal.
        let watcher = Task { await channel.watchNetwork() }
        terminals[profile.id] = Terminal(profile: profile, channel: channel, tasks: [consumer, watcher])
        return true
    }

    /// Ends a host's terminal, if it has one.
    func close(_ profileID: UUID, reason: String) {
        guard let terminal = terminals.removeValue(forKey: profileID) else { return }
        terminal.tasks.forEach { $0.cancel() }
        terminal.channel.close(reason: reason)
    }

    func closeAll(reason: String) {
        for id in Array(terminals.keys) { close(id, reason: reason) }
    }

    /// A save of `saved`. A terminal opened with different settings (host,
    /// port, user, sign-in, Run on Connect) no longer matches the host.
    func reconcile(saved: SSHTerminalProfile) {
        guard let terminal = terminals[saved.id], terminal.profile != saved else { return }
        close(saved.id, reason: "The host was edited.")
    }

    private func release(_ channel: SSHTerminalChannel, of profileID: UUID) {
        guard let terminal = terminals[profileID], terminal.channel === channel else { return }
        terminals[profileID] = nil
        terminal.tasks.forEach { $0.cancel() }
    }

    // MARK: - Background grace

    /// Oppi entered the background. A connect in flight is cancelled; live
    /// terminals keep running and reading for the grace period.
    func appDidEnterBackground() {
        inBackground = true
        let pending = attempts
        attempts.removeAll()
        for attempt in pending.values {
            attempt.task.cancel()
            attempt.ended(.background)
        }
        guard grace == nil, terminals.values.contains(where: { $0.channel.connected }) else { return }
        // Set before `begin`: iOS may call the expiration handler before it returns.
        let current = Grace()
        grace = current
        guard let identifier = backgroundTasks.begin(expiration: { [weak self] in self?.graceExpired(current) }) else {
            // Without a background task there is no grace: close before suspension.
            grace = nil
            closeAllForBackground()
            return
        }
        current.identifier = identifier
        if current.over {
            // The expiration handler already ran inside `begin`.
            finish(current)
            return
        }
        current.timer = Task { [weak self, sleep] in
            do { try await sleep(Self.backgroundGrace) } catch { return }
            await self?.graceElapsed(current)
        }
    }

    /// Oppi is active again. Within the grace nothing closed, so nothing reconnects.
    func appDidBecomeActive() {
        inBackground = false
        if let current = grace { finish(current) }
    }

    /// The grace ran out while iOS still allows the process to run: let the
    /// connections finish closing before the background task ends.
    private func graceElapsed(_ current: Grace) async {
        guard grace === current else { return }
        for task in closeAllForBackground() { await task.value }
        finish(current)
    }

    /// iOS is about to suspend: close now, on the wire, and end the task. The
    /// handler cannot wait. A handler for a grace that is over does nothing
    /// to the terminals; it only makes sure its own task ended.
    private func graceExpired(_ current: Grace) {
        if grace === current { closeAllForBackground() }
        finish(current)
    }

    @discardableResult
    private func closeAllForBackground() -> [Task<Void, Never>] {
        var teardowns = [Task<Void, Never>]()
        for id in Array(terminals.keys) {
            guard let terminal = terminals.removeValue(forKey: id) else { continue }
            terminal.tasks.forEach { $0.cancel() }
            terminal.channel.closeForBackground()
            if let teardown = terminal.channel.teardown { teardowns.append(teardown) }
        }
        return teardowns
    }

    /// Ends this grace's background task exactly once. Before `begin` returned
    /// the identifier is unknown; `appDidEnterBackground` ends it then.
    private func finish(_ current: Grace) {
        if grace === current { grace = nil }
        current.timer?.cancel()
        current.over = true
        if let identifier = current.identifier, !current.taskEnded {
            current.taskEnded = true
            backgroundTasks.end(identifier)
        }
    }
}
