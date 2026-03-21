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
/// Default is ON in DEBUG builds and tests, OFF in release builds.
/// When off, plot output falls back to raw JSON text display.
enum NativePlotPreferences {
    private static let enabledDefaultsKey = "\(AppIdentifiers.subsystem).nativePlot.enabled"

    private static var defaultEnabled: Bool {
        #if DEBUG
            true
        #else
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        #endif
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

/// User-facing preference for keeping the screen awake during active chat work.
///
/// Applies while voice input is active and while the current session is busy.
/// After activity ends, the selected timeout controls how long the idle timer
/// stays disabled before normal auto-lock behavior resumes.
enum ScreenAwakePreferences {
    enum TimeoutPreset: Int, CaseIterable, Identifiable {
        case off = 0
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300
        case tenMinutes = 600

        var id: Int { rawValue }

        var duration: Duration? {
            guard rawValue > 0 else { return nil }
            return .seconds(rawValue)
        }

        var label: String {
            switch self {
            case .off: return "Off"
            case .oneMinute: return "1 minute"
            case .twoMinutes: return "2 minutes"
            case .fiveMinutes: return "5 minutes"
            case .tenMinutes: return "10 minutes"
            }
        }
    }

    private static let presetDefaultsKey = "\(AppIdentifiers.subsystem).screenAwake.timeoutPreset"

    static var timeoutPreset: TimeoutPreset {
        if let raw = UserDefaults.standard.object(forKey: presetDefaultsKey) as? Int,
           let preset = TimeoutPreset(rawValue: raw) {
            return preset
        }
        return .twoMinutes
    }

    static var keepAwakeDuration: Duration? {
        timeoutPreset.duration
    }

    static func setTimeoutPreset(_ preset: TimeoutPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: presetDefaultsKey)
    }
}

/// User-facing preferences for voice input engine selection.
enum VoiceInputPreferences {
    enum EngineMode: String, CaseIterable, Identifiable {
        case auto
        case onDevice
        case remote

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .onDevice: return "On-device"
            case .remote: return "Remote ASR"
            }
        }
    }

    private static let engineModeDefaultsKey = "\(AppIdentifiers.subsystem).voice.engineMode"
    private static let remoteEndpointDefaultsKey = "\(AppIdentifiers.subsystem).voice.remoteEndpoint"

    static var engineMode: EngineMode {
        guard let raw = UserDefaults.standard.string(forKey: engineModeDefaultsKey),
              let mode = EngineMode(rawValue: raw)
        else {
            return .auto
        }
        return mode
    }

    static var remoteEndpoint: URL? {
        guard let raw = UserDefaults.standard.string(forKey: remoteEndpointDefaultsKey) else {
            return nil
        }
        return normalizedEndpointURL(from: raw)
    }

    // periphery:ignore - used by RemoteASRTranscriberTests via @testable import
    @discardableResult
    static func setRemoteEndpoint(from raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setRemoteEndpoint(nil)
            return true
        }

        guard let url = normalizedEndpointURL(from: trimmed) else {
            return false
        }

        setRemoteEndpoint(url)
        return true
    }

    static func setEngineMode(_ mode: EngineMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: engineModeDefaultsKey)
    }

    static func setRemoteEndpoint(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: remoteEndpointDefaultsKey)
            return
        }
        UserDefaults.standard.set(url.absoluteString, forKey: remoteEndpointDefaultsKey)
    }

    static func normalizedEndpointURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }

        return components.url
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

    /// Keyboard pseudo-languages reported by UIKit that should not be persisted
    /// or used for speech model routing.
    private static let unsupportedLanguageIDs: Set<String> = ["dictation", "emoji"]

    /// The last-known keyboard language (BCP 47), or nil if never recorded.
    static var lastLanguage: String? {
        normalize(UserDefaults.standard.string(forKey: key))
    }

    /// Persist a new keyboard language. No-ops on nil/unsupported/unchanged values.
    static func save(_ language: String?) {
        guard let normalized = normalize(language), normalized != lastLanguage else { return }
        UserDefaults.standard.set(normalized, forKey: key)
    }

    /// Normalize keyboard language identifiers for locale routing.
    /// Returns nil for pseudo-languages (emoji/dictation) and malformed values.
    static func normalize(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let lowered = raw.lowercased()
        guard !unsupportedLanguageIDs.contains(lowered) else {
            return nil
        }

        let primary = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? raw
        guard (2...3).contains(primary.count) else {
            return nil
        }
        guard primary.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) else {
            return nil
        }

        return raw
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
