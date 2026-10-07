import Foundation
import LocalAuthentication

/// How long Oppi may stay in the background before App Lock asks for device
/// authentication again.
enum AppLockTimeout: String, CaseIterable, Identifiable, Sendable {
    case off
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var id: String { rawValue }

    var isEnabled: Bool { self != .off }

    /// Background time that makes a lock due; nil when App Lock is off.
    var lockAfter: TimeInterval? {
        switch self {
        case .off: nil
        case .immediately: 0
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .immediately: String(localized: "Immediately")
        case .oneMinute: String(localized: "After 1 Minute")
        case .fiveMinutes: String(localized: "After 5 Minutes")
        case .fifteenMinutes: String(localized: "After 15 Minutes")
        }
    }
}

/// Device-local App Lock preference.
///
/// Stored in the shared app group (not `UserDefaults.standard`) so the Share
/// extension, which runs in its own process, gates on the same setting.
enum AppLockSettings {
    static let timeoutKey = "appLock.timeout"

    static func timeout(in defaults: UserDefaults = SharedConstants.sharedDefaults) -> AppLockTimeout {
        defaults.string(forKey: timeoutKey).flatMap(AppLockTimeout.init(rawValue:)) ?? .off
    }

    static func setTimeout(_ timeout: AppLockTimeout, in defaults: UserDefaults = SharedConstants.sharedDefaults) {
        defaults.set(timeout.rawValue, forKey: timeoutKey)
    }

    /// The Share extension cannot see whether the app is unlocked, so while
    /// App Lock is on it asks on every presentation, before listing workspaces.
    static func shareRequiresAuthentication(in defaults: UserDefaults = SharedConstants.sharedDefaults) -> Bool {
        timeout(in: defaults).isEnabled
    }
}

/// The one LocalAuthentication entry point for App Lock, protected actions,
/// Confirm New Servers, and the Share extension.
enum DeviceOwnerAuthentication {
    /// Face ID / Touch ID with device passcode fallback. Chen decided
    /// (2026-10-07) to keep passcode fallback everywhere, including protected
    /// destructive actions; the App Lock footer says so. Change it here only.
    static let policy: LAPolicy = .deviceOwnerAuthentication

    enum Availability: Equatable, Sendable {
        case available
        /// No device passcode: the only state that turns App Lock off.
        case noPasscode
        /// Any other LocalAuthentication error. App Lock stays on and locked;
        /// the Unlock button tries again.
        case unavailable
    }

    enum Outcome: Equatable, Sendable {
        case success
        case cancelled
        case failed
        /// The device can no longer authenticate (passcode removed).
        case unavailable
    }

    static func availability() -> Availability {
        var error: NSError?
        if LAContext().canEvaluatePolicy(policy, error: &error) {
            return .available
        }
        if (error as? LAError)?.code == .passcodeNotSet {
            return .noPasscode
        }
        return .unavailable
    }

    enum Method: Equatable, Sendable {
        case faceID
        case touchID
        case opticID
        /// Biometrics unusable by Oppi (not enrolled, or Face ID permission
        /// denied); the device passcode is asked instead.
        case passcode

        var name: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .passcode: String(localized: "Passcode")
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .passcode: "lock.open"
            }
        }
    }

    static func method() -> Method {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .passcode
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .passcode
        @unknown default: return .passcode
        }
    }

    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .failed
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                return .cancelled
            case .passcodeNotSet:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
