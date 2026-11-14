import os
import UIKit

/// Starts and ends one UIKit background task. `UIApplication` in the app; a
/// fake in tests.
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

/// At most one background task at a time, ended exactly once by `end` or by
/// iOS's expiration, whichever comes first. A task still running at
/// expiration gets the process killed.
///
/// Each window gets a new epoch, so a late `end` or a timer from a window
/// that is over cannot act on the one that replaced it.
@MainActor
final class BackgroundTaskWindow {
    private let backgroundTasks: any AppBackgroundTasks
    private var epoch = 0
    private var identifier: UIBackgroundTaskIdentifier?
    private(set) var isActive = false

    init(backgroundTasks: any AppBackgroundTasks) {
        self.backgroundTasks = backgroundTasks
    }

    /// The new window's epoch; nil when one is already open, iOS refused, or
    /// it already expired. `onExpired` runs only while its window is
    /// current, before the task ends; it must not wait.
    func begin(onExpired: @escaping @MainActor () -> Void) -> Int? {
        guard !isActive else { return nil }
        epoch += 1
        let opened = epoch
        isActive = true
        identifier = nil
        // Strong: the task must end on expiration even if the owner is gone.
        let task = backgroundTasks.begin { [self] in
            guard isCurrent(opened) else { return }
            onExpired()
            end(opened)
        }
        guard let task else {
            isActive = false
            return nil
        }
        // iOS may run the expiration handler before `begin` returns, while
        // the identifier was still unknown.
        guard isCurrent(opened) else {
            backgroundTasks.end(task)
            return nil
        }
        identifier = task
        return opened
    }

    func isCurrent(_ epoch: Int) -> Bool { isActive && self.epoch == epoch }

    /// Does nothing unless `epoch` is the open window.
    func end(_ epoch: Int) {
        guard isCurrent(epoch) else { return }
        isActive = false
        if let identifier { backgroundTasks.end(identifier) }
    }

    func endCurrent() { end(epoch) }
}

extension CrossProcessFileLock {
    /// A UIKit background task for each held lock, so iOS does not suspend the
    /// app while it holds one (`0xdead10cc`). `beginBackgroundTask` and
    /// `endBackgroundTask` may be called from any thread. If iOS refuses the task,
    /// the lock is taken as before. The task ends once: on release, or at
    /// expiration if the lock is still held then, since a task still running at
    /// expiration gets the app killed.
    static func uiKitBackgroundHold(_ application: UIApplication) -> BackgroundHold {
        { lockName in
            let state = OSAllocatedUnfairLock(initialState: HoldState.starting)
            let end: @Sendable () -> Void = {
                let task: UIBackgroundTaskIdentifier? = state.withLock { state in
                    defer { state = .ended }
                    guard case .running(let task) = state else { return nil }
                    return task
                }
                if let task { application.endBackgroundTask(task) }
            }
            let task = application.beginBackgroundTask(withName: "oppi.lock.\(lockName)", expirationHandler: end)
            guard task != .invalid else { return {} }
            // iOS may run the expiration handler before `beginBackgroundTask` returns.
            let expired = state.withLock { state in
                guard case .starting = state else { return true }
                state = .running(task)
                return false
            }
            if expired { application.endBackgroundTask(task) }
            return end
        }
    }

    private enum HoldState: Sendable {
        case starting, running(UIBackgroundTaskIdentifier), ended
    }
}
