import Foundation
import UIKit

/// Controls `UIApplication.isIdleTimerDisabled` for chat activity.
///
/// Sole iOS writer of the idle timer. Reasons are voice capture (not a session
/// id) and `session::<id>` for running agents.
///
/// Behavior:
/// - While voice capture is active or any tracked session is running, screen
///   sleep is prevented immediately.
/// - After every reason clears, prevention remains enabled for the configured
///   timeout (`AppPreferences.ScreenAwake`) before releasing. Off (`nil`)
///   releases immediately.
@MainActor
final class ScreenAwakeController {
    static let shared = ScreenAwakeController()

    typealias TimeoutProvider = @MainActor () -> Duration?
    typealias IdleTimerSetter = @MainActor (Bool) -> Void
    typealias SleepFunction = @Sendable (Duration) async throws -> Void

    private static let voiceInputReason = "voice-input"

    private let timeoutProvider: TimeoutProvider
    private let idleTimerSetter: IdleTimerSetter
    private let sleepFunction: SleepFunction

    private var activeReasons: Set<String> = []
    private var releaseTask: Task<Void, Never>?

    private(set) var isPreventingSleep = false

    init(
        timeoutProvider: @escaping TimeoutProvider = { AppPreferences.ScreenAwake.keepAwakeDuration },
        idleTimerSetter: @escaping IdleTimerSetter = { UIApplication.shared.isIdleTimerDisabled = $0 },
        sleepFunction: @escaping SleepFunction = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeoutProvider = timeoutProvider
        self.idleTimerSetter = idleTimerSetter
        self.sleepFunction = sleepFunction
    }

    func setVoiceInputActive(_ isActive: Bool) {
        setReason(Self.voiceInputReason, isActive: isActive)
    }

    func setSessionActivity(_ isActive: Bool, sessionId: String) {
        setReason(sessionReason(for: sessionId), isActive: isActive)
    }

    func clearSessionActivity(sessionId: String) {
        activeReasons.remove(sessionReason(for: sessionId))
        reevaluateLockState()
    }

    func refreshFromPreferences() {
        reevaluateLockState()
    }

    private func setReason(_ reason: String, isActive: Bool) {
        if isActive {
            activeReasons.insert(reason)
        } else {
            activeReasons.remove(reason)
        }
        reevaluateLockState()
    }

    private func sessionReason(for sessionId: String) -> String {
        "session::\(sessionId)"
    }

    private func reevaluateLockState() {
        releaseTask?.cancel()
        releaseTask = nil

        if !activeReasons.isEmpty {
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
        guard activeReasons.isEmpty else { return }
        applyIdleTimerDisabled(false)
        releaseTask = nil
    }

    private func applyIdleTimerDisabled(_ disabled: Bool) {
        guard isPreventingSleep != disabled else { return }
        isPreventingSleep = disabled
        idleTimerSetter(disabled)
    }
}
