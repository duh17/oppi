import UIKit

/// Live edit sessions by identity. Reopening a file while a save is in flight
/// reuses that session, so one file never has two writers with different base
/// tags. Settled sessions are dropped. Background checkpoints every session and
/// keeps the process alive for in-flight writes without blocking the transition.
@MainActor
final class WorkspaceFileEditSessionRegistry {
    static let shared = WorkspaceFileEditSessionRegistry()

    private var sessions: [WorkspaceFileEditIdentity: WorkspaceFileEditSession] = [:]
    private var backgroundObserver: NSObjectProtocol?
    private let backgroundTasks: any AppBackgroundTasks

    init(
        observesBackground: Bool = true,
        backgroundTasks: any AppBackgroundTasks = UIApplicationBackgroundTasks(name: "workspace-file-save")
    ) {
        self.backgroundTasks = backgroundTasks
        guard observesBackground else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushAllForBackground()
            }
        }
    }

    func session(for identity: WorkspaceFileEditIdentity) -> WorkspaceFileEditSession? {
        sessions[identity]
    }

    func register(_ session: WorkspaceFileEditSession) {
        sessions[session.identity] = session
        session.onSettled = { [weak self] settled in
            guard let self, self.sessions[settled.identity] === settled, settled.isSettled else { return }
            self.sessions[settled.identity] = nil
        }
    }

    func flushAllForBackground() {
        let pending = sessions.values.filter { $0.hasUnsavedChanges }
        guard !pending.isEmpty else { return }
        for session in pending { session.flush() }
        // One window per background entry: an earlier entry's window waits
        // only for its own writes, not ones started since.
        let window = BackgroundTaskWindow(backgroundTasks: backgroundTasks)
        guard let epoch = window.begin(onExpired: {
            // Out of time: keep each latest draft for the next launch.
            for session in pending { session.checkpoint() }
        }) else { return }
        Task { @MainActor in
            for session in pending { await session.waitForInFlightWrite() }
            window.end(epoch)
        }
    }
}
