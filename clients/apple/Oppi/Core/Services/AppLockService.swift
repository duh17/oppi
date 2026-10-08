import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppLock")

/// Time source for App Lock timeouts. `CLOCK_MONOTONIC` on Darwin keeps
/// counting while the device sleeps and does not move when the user changes
/// the date and time, so setting the clock back cannot extend a timeout.
enum AppLockClock {
    static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// Pure App Lock state machine. Times are seconds on the system monotonic
/// clock (`AppLockClock`), which keeps counting through sleep and ignores
/// wall-clock changes, so setting the clock back cannot extend the timeout.
/// Tests pass their own values.
///
/// Rules:
/// - Cold launch with App Lock on starts locked.
/// - Only a full app background starts the timeout. `inactive` (Control
///   Center, the app switcher, the Face ID / passcode sheet itself) never does,
///   so the system auth sheet cannot cause a lock loop.
/// - `Immediately` locks as the app backgrounds; timed values lock on return
///   when the background time reached the timeout (boundary inclusive).
/// - The lock cover prompts by itself once per lock. After a cancel or
///   failure it waits for the Unlock button.
/// - `scopedUnlockGeneration` advances whenever the app locks, and, with App
///   Lock off, whenever the app leaves the foreground.
struct AppLockMachine: Equatable {
    private(set) var timeout: AppLockTimeout
    private(set) var isAvailable: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var backgroundedAt: TimeInterval?
    private(set) var shouldAutoPrompt: Bool
    private(set) var scopedUnlockGeneration = 0

    init(timeout: AppLockTimeout, isAvailable: Bool) {
        self.timeout = timeout
        self.isAvailable = isAvailable
        let locked = isAvailable && timeout.isEnabled
        isLocked = locked
        shouldAutoPrompt = locked
    }

    /// App Lock is configured and the device can authenticate.
    var isEnabled: Bool { isAvailable && timeout.isEnabled }

    /// Whether the app would show its lock cover at `now`, including a lock
    /// that is due but not applied yet because the app has not foregrounded.
    func requiresUnlock(at now: TimeInterval) -> Bool {
        guard isEnabled else { return false }
        return isLocked || isLockDue(at: now)
    }

    mutating func didEnterBackground(at now: TimeInterval) {
        if backgroundedAt == nil {
            backgroundedAt = now
        }
        guard isEnabled else {
            scopedUnlockGeneration &+= 1
            return
        }
        if timeout == .immediately {
            lock()
        }
    }

    /// Call when any scene becomes active. Applies a due lock and ends the
    /// background period.
    mutating func didBecomeActive(at now: TimeInterval) {
        lockIfDue(at: now)
        backgroundedAt = nil
    }

    mutating func lockIfDue(at now: TimeInterval) {
        if isEnabled, isLockDue(at: now) {
            lock()
        }
    }

    /// Returns true once per lock; the cover starts unlock without a tap.
    mutating func takeAutoPrompt() -> Bool {
        guard isLocked, shouldAutoPrompt, !isAuthenticating else { return false }
        shouldAutoPrompt = false
        return true
    }

    /// Returns false when nothing needs unlocking or an attempt is running.
    mutating func beginUnlock() -> Bool {
        guard isLocked, !isAuthenticating else { return false }
        isAuthenticating = true
        shouldAutoPrompt = false
        return true
    }

    mutating func finishUnlock(_ outcome: DeviceOwnerAuthentication.Outcome) {
        isAuthenticating = false
        switch outcome {
        case .success:
            isLocked = false
        case .unavailable:
            // The passcode was removed; App Lock cannot run on this device.
            setAvailable(false)
        case .cancelled, .failed:
            break
        }
    }

    mutating func setTimeout(_ timeout: AppLockTimeout) {
        self.timeout = timeout
        if !isEnabled {
            isLocked = false
        }
    }

    mutating func setAvailable(_ available: Bool) {
        isAvailable = available
        if !isEnabled {
            isLocked = false
        }
    }

    private func isLockDue(at now: TimeInterval) -> Bool {
        guard let lockAfter = timeout.lockAfter, let backgroundedAt else { return false }
        let elapsed = now - backgroundedAt
        // Monotonic time cannot go back within a boot; treat it as due if it does.
        return elapsed < 0 || elapsed >= lockAfter
    }

    private mutating func lock() {
        guard !isLocked else { return }
        isLocked = true
        shouldAutoPrompt = true
        scopedUnlockGeneration &+= 1
    }
}

/// App-wide App Lock: owns the lock state, timeout preference, unlock, and the
/// protected-action gate. `AppLockCoverController` paints the cover from it.
@MainActor @Observable
final class AppLockService {
    static let shared = AppLockService()

    private(set) var machine: AppLockMachine
    /// Shown on the lock cover after a failed (not cancelled) attempt.
    private(set) var unlockFailed = false
    /// Face ID / Touch ID, or the passcode when biometrics are unusable.
    private(set) var method: DeviceOwnerAuthentication.Method

    /// Called after every lock-state change so the cover windows update.
    @ObservationIgnored var onLockStateChange: (() -> Void)?
    /// The latest deep link, notification tap, or Quick Session request that
    /// arrived while locked. Runs after the next successful unlock; dropped
    /// on a cancelled or failed unlock and when the app goes to the background.
    @ObservationIgnored private var deferredUntilUnlock: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let monotonicNow: @MainActor () -> TimeInterval
    @ObservationIgnored private let availability: @MainActor () -> DeviceOwnerAuthentication.Availability
    @ObservationIgnored private let authenticator: @MainActor (String) async -> DeviceOwnerAuthentication.Outcome
    @ObservationIgnored private let methodProvider: @MainActor () -> DeviceOwnerAuthentication.Method
    @ObservationIgnored private let stopPlayback: @MainActor () -> Void
    @ObservationIgnored private let didTurnOn: @MainActor () -> Void
    @ObservationIgnored private var unlockTask: Task<Bool, Never>?
    /// Background playback keeps the process alive, so it stops when a timed
    /// lock becomes due even though the lock itself applies on foreground.
    @ObservationIgnored private var playbackStopTask: Task<Void, Never>?
    /// Protected-action prompts in flight; their auth sheet must not obscure.
    /// Observed so controls disabled during a prompt re-enable after it.
    private var protectedAuthenticationsInFlight = 0

    init(
        defaults: UserDefaults = SharedConstants.sharedDefaults,
        monotonicNow: @escaping @MainActor () -> TimeInterval = { AppLockClock.monotonicNow() },
        availability: @escaping @MainActor () -> DeviceOwnerAuthentication.Availability = { DeviceOwnerAuthentication.availability() },
        method: @escaping @MainActor () -> DeviceOwnerAuthentication.Method = { DeviceOwnerAuthentication.method() },
        authenticator: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { await DeviceOwnerAuthentication.authenticate(reason: $0) },
        stopPlayback: @escaping @MainActor () -> Void = { AppLockPlayback.stopAll() },
        didTurnOn: @escaping @MainActor () -> Void = { AppLockService.clearContentShownBeforeAppLock() }
    ) {
        self.defaults = defaults
        self.monotonicNow = monotonicNow
        self.availability = availability
        self.authenticator = authenticator
        self.methodProvider = method
        self.stopPlayback = stopPlayback
        self.didTurnOn = didTurnOn
        self.method = method()
        machine = AppLockMachine(
            timeout: AppLockSettings.timeout(in: defaults),
            isAvailable: availability() != .noPasscode
        )
    }

    private func now() -> TimeInterval { monotonicNow() }

    /// At least one second, at most 30, so a suspended stretch is caught soon
    /// after the process wakes.
    private func secondsUntilLockIsDue() -> TimeInterval {
        guard let lockAfter = machine.timeout.lockAfter, let backgroundedAt = machine.backgroundedAt else { return 30 }
        return min(30, max(1, lockAfter - (now() - backgroundedAt)))
    }

    /// Runs `action` now when Oppi does not need unlocking, otherwise after the
    /// next successful unlock. Deep links, notification taps, and Quick
    /// Session requests go through this so nothing navigates, pairs, or
    /// switches servers behind the cover. Only the latest request is kept.
    func performWhenUnlocked(_ action: @escaping @MainActor () -> Void) {
        guard requiresUnlock() else {
            action()
            return
        }
        deferredUntilUnlock = action
    }

    /// Turning App Lock on: content shown while it was off (ask notifications
    /// with question text, the Live Activity, Picture in Picture) follows the
    /// new setting at once. Runs in the foreground with the user present.
    static func clearContentShownBeforeAppLock() {
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.removeAskNotifications()
        }
        if ReleaseFeatures.liveActivitiesEnabled {
            LiveActivityManager.shared.endAllForAppLock()
        }
        AppLockPlayback.disablePictureInPicture()
    }

    var timeout: AppLockTimeout { machine.timeout }
    var isAvailable: Bool { machine.isAvailable }
    var isEnabled: Bool { machine.isEnabled }
    var isLocked: Bool { machine.isLocked }
    var isAuthenticating: Bool { machine.isAuthenticating || protectedAuthenticationsInFlight > 0 }

    /// `ScopedLockService`: a server, workspace, or session unlock is valid
    /// only while this value is unchanged. It advances whenever the app locks and,
    /// with App Lock off, whenever the app leaves the foreground.
    var scopedUnlockGeneration: Int { machine.scopedUnlockGeneration }

    /// Whether external entry points (intents) must unlock before work.
    func requiresUnlock() -> Bool {
        machine.requiresUnlock(at: now())
    }

    // MARK: - Preferences

    func setTimeout(_ timeout: AppLockTimeout) {
        let wasEnabled = machine.isEnabled
        AppLockSettings.setTimeout(timeout, in: defaults)
        update { $0.setTimeout(timeout) }
        if !wasEnabled, machine.isEnabled {
            didTurnOn()
        }
    }

    /// Re-check passcode and biometry state (the user may have changed them in
    /// iOS Settings while Oppi was in the background).
    func refreshAvailability() {
        method = methodProvider()
        // Only a missing passcode turns App Lock off; any other error keeps it
        // locked so a LocalAuthentication glitch cannot unlock the app.
        let available = availability() != .noPasscode
        guard available != machine.isAvailable else { return }
        update { $0.setAvailable(available) }
    }

    // MARK: - Lifecycle

    /// The last foreground scene entered the background.
    func appDidEnterBackground() {
        deferredUntilUnlock = nil
        update { $0.didEnterBackground(at: now()) }
        playbackStopTask?.cancel()
        guard machine.isEnabled, !machine.isLocked, machine.timeout.lockAfter != nil else { return }
        // Re-checks the monotonic deadline on every wake, so time the process
        // spent suspended still counts. New playback is refused once the lock
        // is due (`requiresUnlock`), so one stop is enough.
        playbackStopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.requiresUnlock() {
                    self.stopPlayback()
                    return
                }
                try? await Task.sleep(for: .seconds(self.secondsUntilLockIsDue()))
            }
        }
    }

    /// A scene became active. Applies a due lock, then starts the one
    /// automatic unlock prompt for this lock.
    @discardableResult
    func sceneDidBecomeActive() -> Task<Bool, Never>? {
        playbackStopTask?.cancel()
        playbackStopTask = nil
        refreshAvailability()
        update { $0.didBecomeActive(at: now()) }
        var autoPrompt = false
        update { autoPrompt = $0.takeAutoPrompt() }
        guard autoPrompt else { return nil }
        return Task { await unlock() }
    }

    /// Whether a scene going inactive should obscure its content. The Face ID
    /// and passcode sheets make the scene inactive; those must not flash it.
    var obscuresInactiveScenes: Bool {
        isEnabled && !isAuthenticating
    }

    // MARK: - Unlock

    /// Unlock the app. Concurrent callers (cover auto-prompt, Unlock button,
    /// a foreground intent) share one authentication attempt.
    @discardableResult
    func unlock() async -> Bool {
        if let unlockTask {
            return await unlockTask.value
        }
        update { $0.lockIfDue(at: now()) }
        guard machine.isLocked else { return true }
        var began = false
        update { began = $0.beginUnlock() }
        guard began else { return false }
        unlockFailed = false

        let task = Task { @MainActor [authenticator] in
            let outcome = await authenticator(String(localized: "Unlock Oppi"))
            logger.info("App Lock unlock outcome: \(String(describing: outcome), privacy: .public)")
            self.unlockFailed = outcome == .failed
            self.update { $0.finishUnlock(outcome) }
            if self.machine.isLocked {
                // Cancelled or failed: the waiting link does not survive.
                self.deferredUntilUnlock = nil
            }
            return !self.machine.isLocked
        }
        unlockTask = task
        let unlocked = await task.value
        unlockTask = nil
        return unlocked
    }

    /// Gate for Remove Server, Revoke Device, Delete Workspace, and Set/Replace
    /// API Key. With App Lock off it allows the action without a prompt.
    func authorizeProtectedAction(reason: String) async -> Bool {
        guard machine.isEnabled else { return true }
        protectedAuthenticationsInFlight += 1
        defer { protectedAuthenticationsInFlight -= 1 }
        switch await authenticator(reason) {
        case .success:
            return true
        case .unavailable:
            // The passcode was removed; App Lock no longer applies.
            update { $0.setAvailable(false) }
            return true
        case .cancelled, .failed:
            return false
        }
    }

    /// Scoped (server, workspace, session) unlock. Unlike protected actions it
    /// asks even with App Lock off, because scoped locks work without it.
    /// Never prompts behind the App Lock cover. A device without a passcode
    /// cannot authenticate, so scoped locks do not apply there.
    func authenticateScopedUnlock(reason: String) async -> Bool {
        guard !requiresUnlock() else { return false }
        protectedAuthenticationsInFlight += 1
        defer { protectedAuthenticationsInFlight -= 1 }
        switch await authenticator(reason) {
        case .success:
            return true
        case .unavailable:
            update { $0.setAvailable(false) }
            return true
        case .cancelled, .failed:
            return false
        }
    }

    private func update(_ change: (inout AppLockMachine) -> Void) {
        let before = machine
        change(&machine)
        guard machine != before else { return }
        onLockStateChange?()
        if machine.isLocked, !before.isLocked {
            stopPlayback()
        }
        if let deferred = deferredUntilUnlock, !requiresUnlock() {
            deferredUntilUnlock = nil
            deferred()
        }
    }
}
