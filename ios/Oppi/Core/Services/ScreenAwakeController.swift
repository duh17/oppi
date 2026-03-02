import Foundation
import UIKit

/// Controls `UIApplication.isIdleTimerDisabled` for chat activity.
///
/// Behavior:
/// - While any tracked session is active (voice input or busy agent), screen
///   sleep is prevented immediately.
/// - After activity stops, prevention remains enabled for the configured
///   timeout (`ScreenAwakePreferences`) before releasing.
@MainActor
final class ScreenAwakeController {
    static let shared = ScreenAwakeController()

    typealias TimeoutProvider = @MainActor () -> Duration?
    typealias IdleTimerSetter = @MainActor (Bool) -> Void
    typealias SleepFunction = @Sendable (Duration) async throws -> Void

    private let timeoutProvider: TimeoutProvider
    private let idleTimerSetter: IdleTimerSetter
    private let sleepFunction: SleepFunction

    private var activeSessionReasons: Set<String> = []
    private var releaseTask: Task<Void, Never>?

    private(set) var isPreventingSleep = false

    init(
        timeoutProvider: @escaping TimeoutProvider = { ScreenAwakePreferences.keepAwakeDuration },
        idleTimerSetter: @escaping IdleTimerSetter = { UIApplication.shared.isIdleTimerDisabled = $0 },
        sleepFunction: @escaping SleepFunction = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeoutProvider = timeoutProvider
        self.idleTimerSetter = idleTimerSetter
        self.sleepFunction = sleepFunction
    }

    func setSessionActivity(_ isActive: Bool, sessionId: String) {
        let reason = sessionReason(for: sessionId)

        if isActive {
            activeSessionReasons.insert(reason)
        } else {
            activeSessionReasons.remove(reason)
        }

        reevaluateLockState()
    }

    func clearSessionActivity(sessionId: String) {
        activeSessionReasons.remove(sessionReason(for: sessionId))
        reevaluateLockState()
    }

    func refreshFromPreferences() {
        reevaluateLockState()
    }

    private func sessionReason(for sessionId: String) -> String {
        "session::\(sessionId)"
    }

    private func reevaluateLockState() {
        releaseTask?.cancel()
        releaseTask = nil

        if !activeSessionReasons.isEmpty {
            applyIdleTimerDisabled(true)
            return
        }

        guard let timeout = timeoutProvider() else {
            applyIdleTimerDisabled(false)
            return
        }

        applyIdleTimerDisabled(true)

        releaseTask = Task { [weak self, sleepFunction] in
            do {
                try await sleepFunction(timeout)
            } catch {
                return
            }
            self?.handleReleaseTimerFired()
        }
    }

    private func handleReleaseTimerFired() {
        guard activeSessionReasons.isEmpty else { return }
        applyIdleTimerDisabled(false)
        releaseTask = nil
    }

    private func applyIdleTimerDisabled(_ disabled: Bool) {
        guard isPreventingSleep != disabled else { return }
        isPreventingSleep = disabled
        idleTimerSetter(disabled)
    }
}
