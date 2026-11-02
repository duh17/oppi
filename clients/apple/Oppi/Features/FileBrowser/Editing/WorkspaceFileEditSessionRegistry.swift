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
        let saveTask = SaveTask(backgroundTasks)
        saveTask.identifier = backgroundTasks.begin {
            // Out of time: keep each latest draft for the next launch.
            for session in pending { session.checkpoint() }
            saveTask.finish()
        }
        if saveTask.over {
            // The expiration handler already ran inside `begin`.
            saveTask.finish()
            return
        }
        Task { @MainActor in
            for session in pending { await session.waitForInFlightWrite() }
            saveTask.finish()
        }
    }

    /// The background task kept for in-flight writes. Expiration or the
    /// finished writes, whichever comes first, ends it; the other does nothing.
    /// iOS may call the expiration handler before `begin` returns.
    @MainActor
    private final class SaveTask {
        private let backgroundTasks: any AppBackgroundTasks
        var identifier: UIBackgroundTaskIdentifier?
        private(set) var over = false
        private var ended = false

        init(_ backgroundTasks: any AppBackgroundTasks) {
            self.backgroundTasks = backgroundTasks
        }

        func finish() {
            over = true
            guard let identifier, !ended else { return }
            ended = true
            backgroundTasks.end(identifier)
        }
    }
}
