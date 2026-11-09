import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Clock, VoiceOver, and announcement seams for `NoticeDismissTimer`.
@MainActor
struct NoticeTimerEnvironment {
    var now: () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var isVoiceOverRunning: () -> Bool = {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }
    var announce: (String) -> Void = { message in
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

enum NoticeDismiss {
    /// How long every transient notice stays before it removes itself.
    static let duration: Duration = .seconds(6)
}

/// The one auto-dismiss behaviour for transient notices (extension notify
/// chips, dictation failures, and the like), keyed by whatever identifies a
/// notice slot.
///
/// - A notice stays `NoticeDismiss.duration`, then `onExpire(key)` runs; the
///   owner removes the notice there. `start` again restarts the full duration.
/// - `setPaused(true, ...)` holds the remaining time while the notice is
///   expanded or being touched; `false` resumes with what was left. The
///   pause outlives `start` until `cancel`, so a notice replaced while
///   expanded stays put.
/// - `cancel` is the explicit dismiss: it drops the timer and the pause.
/// - A notice that carries an action passes `keepsUntilDismissed`: with
///   VoiceOver running it is announced and never auto-dismissed. Apple's
///   Accessibility HIG asks apps to minimize time-boxed UI because people
///   who need longer to process it lose it, and `UIAccessibility.announcement`
///   is for events the UI shows only briefly. Without VoiceOver it times out
///   like any other notice.
///
/// Every notice also needs a visible Dismiss control (accessibilityLabel
/// "Dismiss") calling the owner's dismiss, which ends in `cancel`.
@MainActor
final class NoticeDismissTimer<Key: Hashable> {
    private struct Entry {
        var remaining: Duration
        var startedAt: ContinuousClock.Instant?
        var task: Task<Void, Never>?
    }

    private var entries: [Key: Entry] = [:]
    private var paused: Set<Key> = []
    private let duration: Duration
    private let environment: NoticeTimerEnvironment
    private let onExpire: (Key) -> Void

    init(
        duration: Duration = NoticeDismiss.duration,
        environment: NoticeTimerEnvironment = NoticeTimerEnvironment(),
        onExpire: @escaping (Key) -> Void
    ) {
        self.duration = duration
        self.environment = environment
        self.onExpire = onExpire
    }

    /// Shows or refreshes a notice: the full duration, from now.
    func start(_ key: Key, keepsUntilDismissed: Bool = false, announcement: String? = nil) {
        stop(key)
        if keepsUntilDismissed, environment.isVoiceOverRunning() {
            if let announcement { environment.announce(announcement) }
            return
        }
        entries[key] = Entry(remaining: duration)
        if !paused.contains(key) { run(key) }
    }

    func setPaused(_ isPaused: Bool, for key: Key) {
        if isPaused {
            paused.insert(key)
            guard var entry = entries[key], let started = entry.startedAt else { return }
            let elapsed = environment.now() - started
            entry.remaining = entry.remaining > elapsed ? entry.remaining - elapsed : .zero
            entry.startedAt = nil
            entry.task?.cancel()
            entry.task = nil
            entries[key] = entry
        } else {
            paused.remove(key)
            guard let entry = entries[key], entry.task == nil else { return }
            run(key)
        }
    }

    func cancel(_ key: Key) {
        stop(key)
        paused.remove(key)
    }

    private func stop(_ key: Key) {
        entries.removeValue(forKey: key)?.task?.cancel()
    }

    private func run(_ key: Key) {
        guard var entry = entries[key] else { return }
        entry.task?.cancel()
        if entry.remaining <= .zero {
            cancel(key)
            onExpire(key)
            return
        }
        let remaining = entry.remaining
        entry.startedAt = environment.now()
        entry.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.environment.sleep(remaining)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.cancel(key)
            self.onExpire(key)
        }
        entries[key] = entry
    }
}
