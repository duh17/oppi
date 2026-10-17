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

    private struct Grace {
        let id = UUID()
        let backgroundTask: UIBackgroundTaskIdentifier
        var timer: Task<Void, Never>?
    }

    private var terminals: [UUID: Terminal] = [:]
    @ObservationIgnored private var grace: Grace?
    @ObservationIgnored private let backgroundTasks: any SSHBackgroundTasks
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        backgroundTasks: any SSHBackgroundTasks = UIApplicationBackgroundTasks(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.backgroundTasks = backgroundTasks
        self.sleep = sleep
    }

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
    func adopt(_ channel: SSHTerminalChannel, profile: SSHTerminalProfile, queue: SSHTerminalEventQueue) {
        close(profile.id, reason: "Replaced by a new connection.")
        let consumer = Task { [weak self] in
            await channel.consume(queue)
            self?.release(channel, of: profile.id)
        }
        // The screen's network watch ends with the screen; this one lasts as long as the terminal.
        let watcher = Task { await channel.watchNetwork() }
        terminals[profile.id] = Terminal(profile: profile, channel: channel, tasks: [consumer, watcher])
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

    /// Oppi entered the background. Live terminals keep running and reading
    /// for the grace period.
    func appDidEnterBackground() {
        guard grace == nil, terminals.values.contains(where: { $0.channel.connected }) else { return }
        let backgroundTask = backgroundTasks.begin { [weak self] in self?.graceExpired() }
        guard let backgroundTask else {
            // Without a background task there is no grace: close before suspension.
            closeAllForBackground()
            return
        }
        var started = Grace(backgroundTask: backgroundTask)
        let id = started.id
        started.timer = Task { [weak self, sleep] in
            do { try await sleep(Self.backgroundGrace) } catch { return }
            await self?.graceElapsed(id)
        }
        grace = started
    }

    /// Oppi is active again. Within the grace nothing closed, so nothing reconnects.
    func appDidBecomeActive() {
        endGrace()
    }

    /// The grace ran out while iOS still allows the process to run: let the
    /// connections finish closing before the background task ends.
    private func graceElapsed(_ id: UUID) async {
        guard grace?.id == id else { return }
        for task in closeAllForBackground() { await task.value }
        if grace?.id == id { endGrace() }
    }

    /// iOS is about to suspend: close now and return. The handler may not wait.
    private func graceExpired() {
        closeAllForBackground()
        endGrace()
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

    private func endGrace() {
        guard let ended = grace else { return }
        grace = nil
        ended.timer?.cancel()
        backgroundTasks.end(ended.backgroundTask)
    }
}
