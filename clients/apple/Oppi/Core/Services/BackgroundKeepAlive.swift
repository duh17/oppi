import os
import UIKit

/// Starts and ends one UIKit background task. `UIApplication` in the app; a fake in tests.
@MainActor
protocol AppBackgroundTasks {
    /// Nil when iOS refuses. `expiration` runs on the main actor when iOS is
    /// about to suspend the process; the task must be ended by then.
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier?
    func end(_ task: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIApplicationBackgroundTasks: AppBackgroundTasks {
    let name: String

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        let task = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
        return task == .invalid ? nil : task
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Keeps the app process alive while agents are actively working.
///
/// Uses a background task to prevent iOS from suspending the process when
/// agents are in `busy` or `starting` status. This keeps the WebSocket alive
/// so status updates arrive promptly and session re-entry doesn't require a
/// multi-second TLS reconnect.
///
/// The task ends when:
/// - All sessions leave busy/starting state (observed via polling)
/// - The app returns to foreground (`end()` called)
/// - iOS expires the background task (~30s, but often longer on modern devices).
///   The streams then close with goingAway, as when nothing was busy, and the
///   foreground reconnect reopens them. A task left running at expiration gets
///   the process killed.
@MainActor
final class BackgroundKeepAlive {
    private static let log = Logger(subsystem: AppIdentifiers.subsystem, category: "BackgroundKeepAlive")
    private static let pollInterval: Duration = .seconds(5)

    /// One keep-alive window. A class: iOS may call the expiration handler
    /// before `begin` returns, and a stale handler must recognize it is not
    /// the current window.
    private final class Window {
        var identifier: UIBackgroundTaskIdentifier?
        var polling: Task<Void, Never>?
        /// The window is finished; its task is ended once its identifier is known.
        var over = false
        var taskEnded = false
    }

    private let backgroundTasks: any AppBackgroundTasks
    private let sleep: @Sendable (Duration) async throws -> Void
    private var window: Window?

    init(
        backgroundTasks: any AppBackgroundTasks = UIApplicationBackgroundTasks(name: "agent-keep-alive"),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.backgroundTasks = backgroundTasks
        self.sleep = sleep
    }

    /// Shared predicate used both before starting and while polling. It must
    /// include inactive server connections because their agents continue work
    /// while another server is selected.
    static func hasActiveAgent(in connections: some Sequence<ServerConnection>) -> Bool {
        connections.contains { connection in
            connection.sessionStore.sessions.contains {
                $0.status == .busy || $0.status == .starting
            }
        }
    }

    /// Begin background execution if any agent on any connection is active.
    func begin(coordinator: ConnectionCoordinator) {
        guard window == nil else { return }

        // Set before `begin`: iOS may call the expiration handler before it returns.
        let current = Window()
        window = current
        let identifier = backgroundTasks.begin { [weak self, weak coordinator] in
            Self.log.error("Background task expired by OS")
            guard let self else { return }
            if self.window === current { coordinator?.prepareAllForBackground() }
            self.finish(current)
        }
        guard let identifier else {
            window = nil
            Self.log.warning("OS denied background task request")
            return
        }
        current.identifier = identifier
        if current.over {
            // The expiration handler already ran inside `begin`.
            finish(current)
            return
        }

        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingDesc = remaining > 99_999 ? "unlimited" : String(format: "%.0fs", remaining)
        Self.log.warning("Background keep-alive started (remaining: \(remainingDesc))")

        // Poll session status — end when no agents are busy.
        current.polling = Task { [weak self, weak coordinator, sleep] in
            while true {
                do { try await sleep(Self.pollInterval) } catch { return }
                guard !Task.isCancelled else { return }
                guard let coordinator, Self.hasActiveAgent(in: coordinator.connections.values) else {
                    Self.log.info("No active agents — ending background keep-alive")
                    self?.finish(current)
                    return
                }

                let left = UIApplication.shared.backgroundTimeRemaining
                let leftDesc = left > 99_999 ? "unlimited" : String(format: "%.0fs", left)
                Self.log.debug("Background keep-alive polling (remaining: \(leftDesc))")
            }
        }
    }

    /// End background execution (called on foreground or when no longer needed).
    func end() {
        if let window { finish(window) }
    }

    /// Ends this window's background task exactly once. Before `begin` returned
    /// the identifier is unknown; `begin` ends it then.
    private func finish(_ current: Window) {
        if window === current { window = nil }
        current.polling?.cancel()
        current.over = true
        if let identifier = current.identifier, !current.taskEnded {
            current.taskEnded = true
            backgroundTasks.end(identifier)
        }
    }
}
