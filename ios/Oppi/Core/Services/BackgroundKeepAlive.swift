import os
import UIKit

/// Keeps the app process alive while agents are actively working.
///
/// Uses `UIApplication.beginBackgroundTask` to prevent iOS from suspending
/// the process when agents are in `busy` or `starting` status. This keeps
/// the WebSocket alive so permission requests arrive instantly and session
/// re-entry doesn't require a multi-second TLS reconnect.
///
/// The task ends when:
/// - All sessions leave busy/starting state (observed via polling)
/// - The app returns to foreground (`end()` called)
/// - iOS expires the background task (~30s, but often longer on modern devices)
@MainActor
struct BackgroundKeepAlive {
    private static let log = Logger(subsystem: "dev.chenda.Oppi", category: "BackgroundKeepAlive")

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var pollingTask: Task<Void, Never>?

    /// Begin background execution if any agent is active.
    mutating func begin(sessionStore: SessionStore) {
        guard taskID == .invalid else { return }

        taskID = UIApplication.shared.beginBackgroundTask(withName: "agent-keep-alive") { [self] in
            Self.log.info("Background task expired by OS")
            // Can't mutate self in the expiration handler directly,
            // but the task will be invalidated. Next foreground `end()` cleans up.
        }

        guard taskID != .invalid else {
            Self.log.warning("OS denied background task request")
            return
        }

        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingDesc = remaining > 99_999 ? "unlimited" : String(format: "%.0fs", remaining)
        Self.log.info("Background keep-alive started (remaining: \(remainingDesc))")

        // Poll session status — end when no agents are busy.
        let capturedTaskID = taskID
        pollingTask = Task { @MainActor [sessionStore] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }

                let stillActive = sessionStore.sessions.contains {
                    $0.status == .busy || $0.status == .starting
                }

                if !stillActive {
                    Self.log.info("No active agents — ending background keep-alive")
                    UIApplication.shared.endBackgroundTask(capturedTaskID)
                    break
                }

                let left = UIApplication.shared.backgroundTimeRemaining
                let leftDesc = left > 99_999 ? "unlimited" : String(format: "%.0fs", left)
                Self.log.debug("Background keep-alive polling (remaining: \(leftDesc))")
            }
        }
    }

    /// End background execution (called on foreground or when no longer needed).
    mutating func end() {
        pollingTask?.cancel()
        pollingTask = nil

        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
}
