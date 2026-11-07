import Foundation
import UIKit

/// Controls `UIApplication.isIdleTimerDisabled` for chat activity.
///
/// Sole iOS writer of the idle timer. Reasons are voice capture, Install & Start
/// on Set Up a Computer, and each connection's running sessions
/// (`Session.holdsScreenAwake`).
///
/// Behavior:
/// - While voice capture is active or any tracked session is running, screen
///   sleep is prevented immediately.
/// - After every reason clears, prevention remains enabled for the configured
///   timeout (`AppPreferences.ScreenAwake`) before releasing. Off (`nil`)
///   releases immediately.
/// - A write that changes no reason does nothing: it must neither wake an idle
///   screen nor restart the timeout, or routine updates for idle sessions would
///   keep the screen on for as long as they keep arriving.
@MainActor
final class ScreenAwakeController {
    static let shared = ScreenAwakeController()

    typealias TimeoutProvider = @MainActor () -> Duration?
    typealias IdleTimerSetter = @MainActor (Bool) -> Void
    typealias SleepFunction = @Sendable (Duration) async throws -> Void

    private static let voiceInputReason = "voice-input"
    private static let setupInstallReason = "setup-install"

    private let timeoutProvider: TimeoutProvider
    private let idleTimerSetter: IdleTimerSetter
    private let sleepFunction: SleepFunction

    private var activeReasons: Set<String> = []
    private var runningSessionsByOwner: [ObjectIdentifier: Set<String>] = [:]
    private var releaseTask: Task<Void, Never>?

    private(set) var isPreventingSleep = false

    var isVoiceInputActive: Bool {
        activeReasons.contains(Self.voiceInputReason)
    }

    var hasRunningSession: Bool {
        !runningSessionsByOwner.isEmpty
    }

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

    /// Install & Start runs over an in-process SSH connection that a locked,
    /// suspended app would drop.
    func setSetupInstallActive(_ isActive: Bool) {
        setReason(Self.setupInstallReason, isActive: isActive)
    }

    /// Replaces the running sessions one owner (a `ServerConnection`) reports, so a
    /// session that left that owner's store can never keep a reason held.
    func reconcileSessionActivity(sessionIds: Set<String>, owner: ObjectIdentifier) {
        guard runningSessionsByOwner[owner, default: []] != sessionIds else { return }
        runningSessionsByOwner[owner] = sessionIds.isEmpty ? nil : sessionIds
        reevaluateLockState()
    }

    func refreshFromPreferences() {
        reevaluateLockState()
    }

    private func setReason(_ reason: String, isActive: Bool) {
        let changed = isActive
            ? activeReasons.insert(reason).inserted
            : activeReasons.remove(reason) != nil
        if changed { reevaluateLockState() }
    }

    private func reevaluateLockState() {
        releaseTask?.cancel()
        releaseTask = nil

        if !activeReasons.isEmpty || hasRunningSession {
            applyIdleTimerDisabled(true)
            return
        }

        // Nothing held and nothing to release (a preference change while idle).
        guard isPreventingSleep, let timeout = timeoutProvider() else {
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

extension Session {
    /// A turn is in flight: busy, or stopping one that started. Terminating an idle
    /// session reads `stopping` too but never had a turn, so it does not hold the screen.
    /// `SessionStore`'s merge keeps `currentTurnStartedAt` through `stopping` when a
    /// later summary omits it, and the row's next ready/stopped status releases it.
    var holdsScreenAwake: Bool {
        status == .busy || (status == .stopping && currentTurnStartedAt != nil)
    }
}
