import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Clock, assistive-technology, and announcement seams for `NoticeDismissTimer`.
@MainActor
struct NoticeTimerEnvironment {
    var now: () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// VoiceOver or Switch Control is running: people who need more time to
    /// reach a notice.
    var isAssistiveTechnologyRunning: () -> Bool = {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        false
        #endif
    }
    /// Calls the handler whenever VoiceOver or Switch Control turns on or off.
    /// The returned token keeps the observation alive.
    var observeAssistiveStatus: (@escaping @MainActor () -> Void) -> [any NSObjectProtocol] = { handler in
        #if canImport(UIKit)
        [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                }
            }
        #else
        []
        #endif
    }
    var announce: (String) -> Void = { message in
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

enum NoticeDismiss {
    /// How long a short transient notice stays before it removes itself.
    static let duration: Duration = .seconds(6)
    static let maxDuration: Duration = .seconds(12)
    static let wordsPerExtraSecond = 15

    /// A longer message takes longer to read: `duration` plus one second per
    /// 15 words, at most `maxDuration`.
    static func duration(forMessage message: String?) -> Duration {
        guard let message else { return duration }
        let words = message.split(whereSeparator: \.isWhitespace).count
        return min(duration + .seconds(words / wordsPerExtraSecond), maxDuration)
    }
}

/// The one auto-dismiss behaviour for transient notices (extension notify
/// chips, dictation failures, and the like), keyed by whatever identifies a
/// notice slot.
///
/// - A notice stays `NoticeDismiss.duration(forMessage:)`, then `onExpire(key)`
///   runs; the owner removes the notice there. `start` again restarts the
///   full duration.
/// - `setPaused(true, ...)` holds the remaining time while the notice is
///   expanded or being touched; `false` resumes with what was left. The
///   pause outlives `start` until `cancel`, so a notice replaced while
///   expanded stays put.
/// - `cancel` is the explicit dismiss: it drops the timer and the pause.
/// - A notice that carries an action, or an error the person must read (one
///   that used to stay until cleared), passes `keepsUntilDismissed`: while
///   VoiceOver or Switch Control is running it is announced and never
///   auto-dismissed, and it follows those turning on or off while it shows.
///   Apple's Accessibility HIG asks apps to minimize time-boxed UI because
///   people who need longer to process it lose it, and
///   `UIAccessibility.announcement` is for events the UI shows only briefly.
///   Without them it times out like any other notice.
///
/// Every notice also needs a visible Dismiss control (accessibilityLabel
/// "Dismiss") calling the owner's dismiss, which ends in `cancel`.
/// Removes its notification observers when the timer that owns it goes away.
private final class ObserverTokens: @unchecked Sendable {
    private let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor
final class NoticeDismissTimer<Key: Hashable> {
    private struct Entry {
        var remaining: Duration
        var keepsUntilDismissed: Bool
        var startedAt: ContinuousClock.Instant?
        var task: Task<Void, Never>?
    }

    private var entries: [Key: Entry] = [:]
    private var paused: Set<Key> = []
    private let environment: NoticeTimerEnvironment
    private let onExpire: (Key) -> Void
    private var observation: ObserverTokens?

    init(
        environment: NoticeTimerEnvironment = NoticeTimerEnvironment(),
        onExpire: @escaping (Key) -> Void
    ) {
        self.environment = environment
        self.onExpire = onExpire
        observation = ObserverTokens(environment.observeAssistiveStatus { [weak self] in self?.assistiveStatusChanged() })
    }

    /// Shows or refreshes a notice: its full duration, from now. `message`
    /// sets the duration by length; nil is the base duration.
    func start(
        _ key: Key,
        message: String? = nil,
        keepsUntilDismissed: Bool = false,
        announcement: String? = nil
    ) {
        stop(key)
        entries[key] = Entry(
            remaining: NoticeDismiss.duration(forMessage: message),
            keepsUntilDismissed: keepsUntilDismissed
        )
        if keepsUntilDismissed, environment.isAssistiveTechnologyRunning() {
            if let announcement { environment.announce(announcement) }
            return
        }
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
            guard let entry = entries[key], entry.task == nil, !isHeld(entry) else { return }
            run(key)
        }
    }

    func cancel(_ key: Key) {
        stop(key)
        paused.remove(key)
    }

    private func isHeld(_ entry: Entry) -> Bool {
        entry.keepsUntilDismissed && environment.isAssistiveTechnologyRunning()
    }

    /// A notice that must be kept stops its timer when VoiceOver or Switch
    /// Control turns on, and starts a fresh one when they turn off.
    private func assistiveStatusChanged() {
        for (key, var entry) in entries where entry.keepsUntilDismissed {
            if isHeld(entry) {
                entry.task?.cancel()
                entry.task = nil
                entry.startedAt = nil
                entries[key] = entry
            } else if entry.task == nil, !paused.contains(key) {
                run(key)
            }
        }
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
