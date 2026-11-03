import Foundation
import Observation
import os.log
import UIKit

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
/// - The stored timeout is what gates: App Lock is on whenever it is not
///   `off`. A device with no passcode cannot authenticate, so Oppi starts
///   locked and stays locked behind the cover until one is set.
/// - Cold launch with App Lock on starts locked.
/// - Only a full app background starts the timeout. `inactive` (Control
///   Center, the app switcher, the Face ID / passcode sheet itself) never does,
///   so the system auth sheet cannot cause a lock loop.
/// - `Immediately` locks as the app backgrounds; timed values lock on return
///   when the background time reached the timeout (boundary inclusive).
/// - The lock cover prompts by itself once per lock, and only when the device
///   can authenticate. After a cancel or failure it waits for the Unlock
///   button.
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
        let locked = timeout.isEnabled
        isLocked = locked
        // Without a passcode there is nothing to prompt for; the pending
        // prompt runs once one is set.
        shouldAutoPrompt = locked && isAvailable
    }

    /// App Lock is configured on. This alone gates: the cover, obscuring,
    /// `requiresUnlock`, and protected actions all read it. `isAvailable` only
    /// says whether the unlocking authentication can run.
    var isEnabled: Bool { timeout.isEnabled }

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
        guard isLocked, shouldAutoPrompt, !isAuthenticating, isAvailable else { return false }
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
            // The passcode was removed between the check and the prompt. The
            // app stays locked; the cover says to set one.
            setAvailable(false)
        case .cancelled, .failed:
            break
        }
    }

    /// Starts over as a cold launch with `timeout` does (locked, auto-prompt
    /// pending). The scoped-unlock generation moves forward, never back to a
    /// value an earlier scoped unlock could still match.
    mutating func restart(timeout: AppLockTimeout) {
        let generation = scopedUnlockGeneration
        self = AppLockMachine(timeout: timeout, isAvailable: isAvailable)
        scopedUnlockGeneration = generation &+ 1
    }

    mutating func setTimeout(_ timeout: AppLockTimeout) {
        self.timeout = timeout
        if !isEnabled {
            isLocked = false
        }
    }

    mutating func setAvailable(_ available: Bool) {
        let wasAvailable = isAvailable
        isAvailable = available
        // Availability never unlocks: only turning App Lock off, or a
        // successful unlock, does. A lock that could not prompt yet gets its
        // one prompt once the device can authenticate.
        if available, !wasAvailable, isLocked, !isAuthenticating {
            shouldAutoPrompt = true
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
    /// on a cancelled or failed unlock, when a newer request replaces it, and
    /// when the app goes to the background.
    @ObservationIgnored private var deferredUntilUnlock: DeferredAction?

    private struct DeferredAction {
        let run: @MainActor () -> Void
        let dropped: (@MainActor () -> Void)?
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let monotonicNow: @MainActor () -> TimeInterval
    @ObservationIgnored private let availability: @MainActor () -> DeviceOwnerAuthentication.Availability
    @ObservationIgnored private let authenticator: @MainActor (String) async -> DeviceOwnerAuthentication.Outcome
    @ObservationIgnored private let methodProvider: @MainActor () -> DeviceOwnerAuthentication.Method
    @ObservationIgnored private let didTurnOn: @MainActor () -> Void
    @ObservationIgnored private let isProtectedDataAvailable: @MainActor () -> Bool
    /// The service started before the first unlock after a reboot (a
    /// background launch): the stored timeout may have been unreadable and
    /// read as `.off`. Cleared by the first read made with protected data
    /// available, or by the user choosing a timeout.
    @ObservationIgnored private var timeoutMayBeUnread: Bool
    @ObservationIgnored private var unlockTask: Task<Bool, Never>?
    /// Protected-action prompts in flight; their auth sheet must not obscure.
    /// Observed so controls disabled during a prompt re-enable after it.
    private var protectedAuthenticationsInFlight = 0

    init(
        defaults: UserDefaults = SharedConstants.sharedDefaults,
        monotonicNow: @escaping @MainActor () -> TimeInterval = { AppLockClock.monotonicNow() },
        availability: @escaping @MainActor () -> DeviceOwnerAuthentication.Availability = { DeviceOwnerAuthentication.availability() },
        method: @escaping @MainActor () -> DeviceOwnerAuthentication.Method = { DeviceOwnerAuthentication.method() },
        authenticator: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { await DeviceOwnerAuthentication.authenticate(reason: $0) },
        didTurnOn: @escaping @MainActor () -> Void = { AppLockService.clearContentShownBeforeAppLock() },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.defaults = defaults
        self.monotonicNow = monotonicNow
        self.availability = availability
        self.authenticator = authenticator
        self.methodProvider = method
        self.didTurnOn = didTurnOn
        self.isProtectedDataAvailable = isProtectedDataAvailable
        timeoutMayBeUnread = !isProtectedDataAvailable()
        self.method = method()
        machine = AppLockMachine(
            timeout: AppLockSettings.timeout(in: defaults),
            isAvailable: availability() != .noPasscode
        )
    }

    private func now() -> TimeInterval { monotonicNow() }

    /// Fails closed after a launch before the first unlock: once protected
    /// data is available, reads the stored timeout again. When App Lock is on,
    /// the machine restarts exactly as a cold launch with App Lock on does
    /// (locked, auto-prompt pending).
    /// Startup calls this as soon as protected data is available so readers of
    /// `isEnabled` never see the stale `.off`; the entry points below repeat it.
    func refreshStoredTimeoutAfterProtectedData() {
        guard timeoutMayBeUnread, isProtectedDataAvailable() else { return }
        timeoutMayBeUnread = false
        let stored = AppLockSettings.timeout(in: defaults)
        guard stored.isEnabled, stored != machine.timeout else { return }
        update { $0.restart(timeout: stored) }
    }

    /// Runs `action` now when Oppi does not need unlocking, otherwise after the
    /// next successful unlock. Deep links, notification taps, and Quick
    /// Session requests go through this so nothing navigates, pairs, or
    /// switches servers behind the cover. Only the latest request is kept.
    /// `onDropped` runs when the action will never run, so the caller can
    /// forget it.
    func performWhenUnlocked(
        _ action: @escaping @MainActor () -> Void,
        onDropped: (@MainActor () -> Void)? = nil
    ) {
        guard requiresUnlock() else {
            action()
            return
        }
        let replaced = deferredUntilUnlock
        deferredUntilUnlock = DeferredAction(run: action, dropped: onDropped)
        replaced?.dropped?()
    }

    private func dropDeferredAction() {
        let dropped = deferredUntilUnlock
        deferredUntilUnlock = nil
        dropped?.dropped?()
    }

    /// Turning App Lock on: content shown while it was off (ask notifications
    /// with question text, `done` banners with session names) follows the new
    /// setting at once. The Live Activity shows counts only, so it stays. Runs
    /// in the foreground with the user present. Playback, including Picture in
    /// Picture, is never affected by App Lock.
    static func clearContentShownBeforeAppLock() {
        AttentionNotificationService.shared.removeLockSensitiveNotifications()
        AttentionNotificationService.shared.removePairingNotifications()
    }

    var timeout: AppLockTimeout { machine.timeout }
    /// Whether the device can authenticate. False means the unlock cannot run
    /// (no passcode), not that App Lock is off.
    var isAvailable: Bool { machine.isAvailable }
    /// App Lock is configured on: the stored timeout is not `off`.
    var isEnabled: Bool { machine.isEnabled }
    var isLocked: Bool { machine.isLocked }
    var isAuthenticating: Bool { machine.isAuthenticating || protectedAuthenticationsInFlight > 0 }

    /// `ScopedLockService`: a server, workspace, or session unlock is valid
    /// only while this value is unchanged. It advances whenever the app locks and,
    /// with App Lock off, whenever the app leaves the foreground.
    var scopedUnlockGeneration: Int { machine.scopedUnlockGeneration }

    /// Whether external entry points (intents) must unlock before work.
    func requiresUnlock() -> Bool {
        refreshStoredTimeoutAfterProtectedData()
        return machine.requiresUnlock(at: now())
    }

    // MARK: - Preferences

    func setTimeout(_ timeout: AppLockTimeout) {
        timeoutMayBeUnread = false
        let wasEnabled = machine.isEnabled
        let previous = machine.timeout
        AppLockSettings.setTimeout(timeout, in: defaults)
        update { $0.setTimeout(timeout) }
        PushRegistration.publishRedactionSnapshot(appLockEnabled: timeout.isEnabled)
        if previous != timeout {
            logTimeoutChange(from: previous, to: timeout)
        }
        if !wasEnabled, machine.isEnabled {
            didTurnOn()
        }
    }

    /// A timeout change is the App Lock event worth having in a report, and its
    /// values are a fixed enum, so both go out public. Sent with client logs as
    /// well, because the unified log never leaves the device
    /// (`ClientLogUploadService` ships info lines only for listed categories).
    private func logTimeoutChange(from previous: AppLockTimeout, to timeout: AppLockTimeout) {
        logger.info(
            "App Lock timeout changed: \(previous.rawValue, privacy: .public) -> \(timeout.rawValue, privacy: .public)"
        )
        ClientLog.info(
            "AppLock",
            "Timeout changed",
            metadata: ["from": previous.rawValue, "to": timeout.rawValue]
        )
    }

    /// Re-check passcode and biometry state (the user may have changed them in
    /// iOS Settings while Oppi was in the background). Records whether the
    /// unlock can run; it never unlocks the app.
    func refreshAvailability() {
        method = methodProvider()
        // Only a missing passcode clears availability; any other error keeps it
        // set, so a LocalAuthentication glitch cannot be mistaken for one.
        let available = availability() != .noPasscode
        guard available != machine.isAvailable else { return }
        update { $0.setAvailable(available) }
    }

    // MARK: - Lifecycle

    /// The last foreground scene entered the background.
    func appDidEnterBackground() {
        dropDeferredAction()
        update { $0.didEnterBackground(at: now()) }
    }

    /// A scene became active. Applies a due lock, then starts the one
    /// automatic unlock prompt for this lock.
    @discardableResult
    func sceneDidBecomeActive() -> Task<Bool, Never>? {
        refreshStoredTimeoutAfterProtectedData()
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
    /// a foreground intent) share one authentication attempt. Re-checks the
    /// device first, so a passcode set in iOS Settings since the last check
    /// unlocks normally; a device that still cannot authenticate keeps the app
    /// locked rather than opening it.
    @discardableResult
    func unlock() async -> Bool {
        if let unlockTask {
            return await unlockTask.value
        }
        refreshAvailability()
        update { $0.lockIfDue(at: now()) }
        guard machine.isLocked else { return true }
        guard machine.isAvailable else { return false }
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
                self.dropDeferredAction()
            }
            return !self.machine.isLocked
        }
        unlockTask = task
        let unlocked = await task.value
        unlockTask = nil
        return unlocked
    }

    /// Gate for Remove Server, Revoke Device, Delete Workspace, and Set/Replace
    /// API Key. With App Lock off it allows the action without a prompt. With
    /// it on, every outcome but a success refuses the action: a device that
    /// cannot authenticate authorizes nothing.
    func authorizeProtectedAction(reason: String) async -> Bool {
        refreshStoredTimeoutAfterProtectedData()
        guard machine.isEnabled else { return true }
        protectedAuthenticationsInFlight += 1
        defer { protectedAuthenticationsInFlight -= 1 }
        switch await authenticator(reason) {
        case .success:
            return true
        case .unavailable:
            // No passcode: refuse, and record why the unlock cannot run. App
            // Lock stays on, so the app stays locked.
            update { $0.setAvailable(false) }
            return false
        case .cancelled, .failed:
            return false
        }
    }

    /// Scoped (server, workspace, session) unlock. Unlike protected actions it
    /// asks even with App Lock off, because scoped locks work without it.
    /// Never prompts behind the App Lock cover. With App Lock on it refuses
    /// whenever the device cannot authenticate, locked or not: a device with
    /// no passcode opens no scope. With App Lock off the documented
    /// no-passcode behaviour is unchanged: an unavailable device opens the
    /// scope.
    func authenticateScopedUnlock(reason: String) async -> Bool {
        guard !requiresUnlock() else { return false }
        protectedAuthenticationsInFlight += 1
        defer { protectedAuthenticationsInFlight -= 1 }
        switch await authenticator(reason) {
        case .success:
            return true
        case .unavailable:
            update { $0.setAvailable(false) }
            // App Lock off has nothing to unlock, so the scope opens as it
            // always has. With App Lock on the stored timeout is still not
            // `off`, so the scope stays locked until a passcode is set.
            return !machine.isEnabled
        case .cancelled, .failed:
            return false
        }
    }

    private func update(_ change: (inout AppLockMachine) -> Void) {
        let before = machine
        change(&machine)
        guard machine != before else { return }
        // A kept SSH sign-in approval ends when App Lock locks.
        if !before.isLocked, machine.isLocked { SSHApprovalCache.shared.invalidateAll() }
        onLockStateChange?()
        if let deferred = deferredUntilUnlock, !requiresUnlock() {
            deferredUntilUnlock = nil
            deferred.run()
        }
    }
}
