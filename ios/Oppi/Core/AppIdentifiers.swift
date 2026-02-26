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

/// Persisted keyboard language for voice input locale detection.
///
/// `UITextView.textInputMode` only reports the active keyboard when the text
/// view is first responder. Before the user taps the composer, we fall back
/// to the last-known language stored here. Updated every time the keyboard
/// language changes while the composer is focused.
enum KeyboardLanguageStore {
    private static let key = "\(AppIdentifiers.subsystem).keyboardLanguage"

    /// The last-known keyboard language (BCP 47), or nil if never recorded.
    static var lastLanguage: String? {
        UserDefaults.standard.string(forKey: key)
    }

    /// Persist a new keyboard language. No-ops on nil or unchanged values.
    static func save(_ language: String?) {
        guard let language, language != lastLanguage else { return }
        UserDefaults.standard.set(language, forKey: key)
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

    /// Composer microphone button + on-device speech-to-text via SpeechAnalyzer.
    static let voiceInputEnabled = true
}
