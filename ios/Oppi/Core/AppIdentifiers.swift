import Foundation

/// Centralized app identifiers. Fork-friendly: change `bundleIdPrefix` in
/// `project.yml` and these derive automatically from the bundle identifier.
///
/// All logging subsystems, storage keys, notification names, and service
/// identifiers reference this enum so forks only need to update one place
/// (the Xcode project / XcodeGen config).
enum AppIdentifiers {
    /// Primary subsystem identifier for os_log, Keychain, and storage keys.
    /// Matches the main app's bundle identifier at runtime.
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi"
}

/// User-facing preference for Live Activities.
///
/// Default is OFF in app builds to reduce rollout risk. Tests default ON so
/// existing LiveActivityManager coverage remains stable without per-test setup.
enum LiveActivityPreferences {
    private static let enabledDefaultsKey = "\(AppIdentifiers.subsystem).liveActivities.enabled"

    private static var defaultEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool {
            return stored
        }
        return defaultEnabled
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    }
}

/// User-facing preference for native chart rendering of `plot` tool output.
///
/// Default is OFF in app builds. When off, plot output falls back to raw
/// JSON text display. Tests default ON so chart rendering tests remain stable.
enum NativePlotPreferences {
    private static let enabledDefaultsKey = "\(AppIdentifiers.subsystem).nativePlot.enabled"

    private static var defaultEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool {
            return stored
        }
        return defaultEnabled
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    }
}

/// Shipping toggles for first release hardening.
///
/// Keep these centralized so we can re-enable features intentionally
/// once reliability is proven.
enum ReleaseFeatures {
    /// Remote/local notification flow for permission prompts.
    static let pushNotificationsEnabled = false

    /// Live Activity codepath availability (runtime opt-in handled by
    /// `LiveActivityPreferences`).
    static let liveActivitiesEnabled = true

    /// Native chart rendering for `plot` tool output (runtime opt-in handled
    /// by `NativePlotPreferences`).
    static let nativePlotRenderingEnabled = true

    /// Composer microphone button + custom speech-to-text flow.
    static let composerDictationEnabled = false
}
