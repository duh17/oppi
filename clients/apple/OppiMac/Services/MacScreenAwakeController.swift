import Foundation

/// Prevents Mac display idle sleep while a tracked session is working.
///
/// Uses `ProcessInfo.beginActivity` with `idleDisplaySleepDisabled`.
/// Mac display-sleep prevention stays on Foundation process activity.
@MainActor
final class MacScreenAwakeController {
    static let shared = MacScreenAwakeController()

    typealias TimeoutProvider = @MainActor () -> Duration?
    typealias ActivitySetter = @MainActor (Bool) -> Void
    typealias SleepFunction = @Sendable (Duration) async throws -> Void

    private let timeoutProvider: TimeoutProvider
    private let activitySetter: ActivitySetter
    private let sleepFunction: SleepFunction
    private let usesProcessInfo: Bool

    private var activeSessionReasons: Set<String> = []
    private var releaseTask: Task<Void, Never>?
    private var processActivity: NSObjectProtocol?

    private(set) var isPreventingSleep = false

    init(
        timeoutProvider: @escaping TimeoutProvider = { AppPreferenceStore.ScreenAwake.keepAwakeDuration },
        activitySetter: ActivitySetter? = nil,
        sleepFunction: @escaping SleepFunction = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeoutProvider = timeoutProvider
        self.sleepFunction = sleepFunction
        self.usesProcessInfo = activitySetter == nil
        self.activitySetter = activitySetter ?? { _ in }
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

    /// Replaces event-derived reasons with the authoritative running-session snapshot.
    func reconcileSessionActivity(sessionIds: Set<String>) {
        let reasons = Set(sessionIds.map(sessionReason(for:)))
        guard reasons != activeSessionReasons else { return }
        activeSessionReasons = reasons
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
            applyPreventingSleep(true)
            return
        }

        guard let timeout = timeoutProvider() else {
            applyPreventingSleep(false)
            return
        }

        applyPreventingSleep(true)
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
        applyPreventingSleep(false)
        releaseTask = nil
    }

    private func applyPreventingSleep(_ preventing: Bool) {
        guard isPreventingSleep != preventing else { return }
        isPreventingSleep = preventing
        if usesProcessInfo {
            applyProcessActivity(preventing)
        } else {
            activitySetter(preventing)
        }
    }

    private func applyProcessActivity(_ preventing: Bool) {
        if preventing {
            guard processActivity == nil else { return }
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Oppi session is working"
            )
        } else if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
    }
}
