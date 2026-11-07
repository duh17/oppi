import os
import UIKit

/// Keeps the app process alive while agents are actively working.
///
/// Uses a background task to prevent iOS from suspending the process when
/// agents are `starting`, `busy`, or `stopping` (a runtime still winding down,
/// including a durable abort that lands before `agent_start`). This keeps the WebSocket alive
/// so status updates arrive promptly and session re-entry doesn't require a
/// multi-second TLS reconnect.
///
/// The task ends when:
/// - All sessions leave those states (observed via polling). The sockets
///   then close as in the no-agents background path.
/// - The app returns to foreground (`end()` called)
/// - iOS expires the background task (~30s, but often longer on modern devices).
///   The streams then close with goingAway, as when nothing was busy, and the
///   foreground reconnect reopens them. A task left running at expiration gets
///   the process killed.
@MainActor
final class BackgroundKeepAlive {
    private static let log = Logger(subsystem: AppIdentifiers.subsystem, category: "BackgroundKeepAlive")
    private static let pollInterval: Duration = .seconds(5)

    private let window: BackgroundTaskWindow
    private let sleep: @Sendable (Duration) async throws -> Void
    private var polling: Task<Void, Never>?

    init(
        backgroundTasks: any AppBackgroundTasks = UIApplicationBackgroundTasks(name: "agent-keep-alive"),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.window = BackgroundTaskWindow(backgroundTasks: backgroundTasks)
        self.sleep = sleep
    }

    /// Shared predicate used both before starting and while polling. It must
    /// include inactive server connections because their agents continue work
    /// while another server is selected.
    static func hasActiveAgent(in connections: some Sequence<ServerConnection>) -> Bool {
        connections.contains { connection in
            connection.sessionStore.sessions.contains {
                $0.status == .starting || $0.status.isRunning
            }
        }
    }

    /// Begin background execution if any agent on any connection is active.
    func begin(coordinator: ConnectionCoordinator) {
        guard !window.isActive else { return }
        guard let epoch = window.begin(onExpired: { [weak self, weak coordinator] in
            Self.log.error("Background task expired by OS")
            coordinator?.prepareAllForBackground()
            self?.stopPolling()
        }) else {
            Self.log.warning("OS denied or already expired the background task")
            return
        }

        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingDesc = remaining > 99_999 ? "unlimited" : String(format: "%.0fs", remaining)
        Self.log.warning("Background keep-alive started (remaining: \(remainingDesc))")

        // Poll session status — end when no agents are busy.
        polling = Task { [weak self, weak coordinator, sleep] in
            while true {
                do { try await sleep(Self.pollInterval) } catch { return }
                guard !Task.isCancelled else { return }
                guard let coordinator, Self.hasActiveAgent(in: coordinator.connections.values) else {
                    Self.log.info("No active agents — ending background keep-alive")
                    // The process now suspends with nothing keeping it alive: close the
                    // sockets as the no-agents background path does, unless live audio
                    // still drains over them. Foreground `end()` cancels this poll first.
                    if let coordinator, !coordinator.hasActiveAudioTransportPlayback {
                        coordinator.prepareAllForBackground()
                    }
                    self?.stopPolling()
                    self?.window.end(epoch)
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
        stopPolling()
        window.endCurrent()
    }

    /// Every path that ends a window stops its poll first, so `polling` is
    /// never a newer window's.
    private func stopPolling() {
        polling?.cancel()
        polling = nil
    }
}
