import Foundation

/// Unified preference system for all UserDefaults-backed settings.
///
/// Organized by domain — each is an enum with static getters and setters,
/// following the `FontPreferences` pattern. Every runtime preference key
/// lives here for discoverability.
///
/// Typography preferences remain in `FontPreferences` due to their
/// notification/font-rebuild lifecycle. `PiQuickActionStore` manages its
/// own JSON persistence as a full observable store.
///
/// ## Usage
///
///     // New code — use the domain namespace:
///     let enabled = AppPreferences.LiveActivity.isEnabled
///     AppPreferences.Session.setAutoTitleEnabled(true)
///
///     // Legacy typealiases still work for existing consumers:
///     let mode = VoiceInputPreferences.engineMode   // same as AppPreferences.Voice.engineMode
///
enum AppPreferences {

    // MARK: - Live Activity

    /// User-facing preference for Live Activities.
    ///
    /// Default is OFF in app builds to reduce rollout risk. Tests default ON
    /// so existing LiveActivityManager coverage remains stable.
    enum LiveActivity {
        private static let enabledKey = "\(AppIdentifiers.subsystem).liveActivities.enabled"

        private static var defaultEnabled: Bool {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        }

        static var isEnabled: Bool {
            if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
                return stored
            }
            return defaultEnabled
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
        }
    }

    // MARK: - Native Plot

    /// User-facing preference for native chart rendering of `plot` tool output.
    ///
    /// Default is ON in DEBUG builds and tests, OFF in release builds.
    /// When off, plot output falls back to raw JSON text display.
    enum NativePlot {
        private static let enabledKey = "\(AppIdentifiers.subsystem).nativePlot.enabled"

        private static var defaultEnabled: Bool {
            #if DEBUG
                true
            #else
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    || NSClassFromString("XCTestCase") != nil
            #endif
        }

        static var isEnabled: Bool {
            if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
                return stored
            }
            return defaultEnabled
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
        }
    }

    // MARK: - Screen Awake

    /// User-facing preference for keeping the screen awake during active chat work.
    ///
    /// Applies while voice input is active and while the current session is busy.
    /// After activity ends, the selected timeout controls how long the idle timer
    /// stays disabled before normal auto-lock behavior resumes.
    enum ScreenAwake {
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

        private static let presetKey = "\(AppIdentifiers.subsystem).screenAwake.timeoutPreset"

        static var timeoutPreset: TimeoutPreset {
            if let raw = UserDefaults.standard.object(forKey: presetKey) as? Int,
               let preset = TimeoutPreset(rawValue: raw)
            {
                return preset
            }
            return .twoMinutes
        }

        static var keepAwakeDuration: Duration? {
            timeoutPreset.duration
        }

        static func setTimeoutPreset(_ preset: TimeoutPreset) {
            UserDefaults.standard.set(preset.rawValue, forKey: presetKey)
        }
    }

    // MARK: - Voice Input

    /// User-facing preferences for voice input engine selection.
    enum Voice {
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

        private static let engineModeKey = "\(AppIdentifiers.subsystem).voice.engineMode"
        private static let remoteEndpointKey = "\(AppIdentifiers.subsystem).voice.remoteEndpoint"

        static var engineMode: EngineMode {
            guard let raw = UserDefaults.standard.string(forKey: engineModeKey),
                  let mode = EngineMode(rawValue: raw)
            else {
                return .auto
            }
            return mode
        }

        static var remoteEndpoint: URL? {
            guard let raw = UserDefaults.standard.string(forKey: remoteEndpointKey) else {
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
            UserDefaults.standard.set(mode.rawValue, forKey: engineModeKey)
        }

        static func setRemoteEndpoint(_ url: URL?) {
            guard let url else {
                UserDefaults.standard.removeObject(forKey: remoteEndpointKey)
                return
            }
            UserDefaults.standard.set(url.absoluteString, forKey: remoteEndpointKey)
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

    // MARK: - Keyboard Language

    /// Persisted keyboard language for voice input locale detection.
    ///
    /// `UITextView.textInputMode` only reports the active keyboard when the text
    /// view is first responder. Before the user taps the composer, we fall back
    /// to the last-known language stored here. Updated every time the keyboard
    /// language changes while the composer is focused.
    enum Keyboard {
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

    // MARK: - Quick Session

    /// Persisted defaults for the Quick Session sheet.
    ///
    /// Stores the last-used workspace, model, and thinking level so the sheet
    /// opens pre-configured to the user's most recent choices.
    enum QuickSession {
        private static let prefix = "\(AppIdentifiers.subsystem).quickSession"

        private static let lastWorkspaceIdKey = "\(prefix).lastWorkspaceId"
        private static let lastModelIdKey = "\(prefix).lastModelId"
        private static let lastThinkingLevelKey = "\(prefix).lastThinkingLevel"

        // MARK: Workspace

        static var lastWorkspaceId: String? {
            UserDefaults.standard.string(forKey: lastWorkspaceIdKey)
        }

        static func saveWorkspaceId(_ id: String) {
            UserDefaults.standard.set(id, forKey: lastWorkspaceIdKey)
        }

        // MARK: Model

        static var lastModelId: String? {
            UserDefaults.standard.string(forKey: lastModelIdKey)
        }

        static func saveModelId(_ id: String) {
            UserDefaults.standard.set(id, forKey: lastModelIdKey)
        }

        // MARK: Thinking Level

        static var lastThinkingLevel: ThinkingLevel {
            guard let raw = UserDefaults.standard.string(forKey: lastThinkingLevelKey),
                  let level = ThinkingLevel(rawValue: raw)
            else {
                return .medium
            }
            return level
        }

        static func saveThinkingLevel(_ level: ThinkingLevel) {
            UserDefaults.standard.set(level.rawValue, forKey: lastThinkingLevelKey)
        }
    }

    // MARK: - Appearance

    /// Spinner animation style preference.
    enum Appearance {
        private static let spinnerStyleKey = "spinnerStyle"

        static var spinnerStyle: SpinnerStyle {
            guard let raw = UserDefaults.standard.string(forKey: spinnerStyleKey),
                  let style = SpinnerStyle(rawValue: raw)
            else {
                return .brailleDots
            }
            return style
        }

        static func setSpinnerStyle(_ style: SpinnerStyle) {
            UserDefaults.standard.set(style.rawValue, forKey: spinnerStyleKey)
        }
    }

    // MARK: - Recent Models

    /// Tracks recently-used model IDs so the picker can show them first.
    ///
    /// Stored in UserDefaults — lightweight, survives app restarts.
    /// Thread-safe via MainActor (all callers are UI-side).
    @MainActor
    enum RecentModels {
        private static let key = "RecentModelIDs"
        private static let maxRecent = 5

        /// Record a model as most-recently used.
        static func record(_ modelId: String) {
            var ids = load()
            ids.removeAll { $0 == modelId }
            ids.insert(modelId, at: 0)
            if ids.count > maxRecent {
                ids = Array(ids.prefix(maxRecent))
            }
            UserDefaults.standard.set(ids, forKey: key)
        }

        /// Load ordered list of recent model full IDs (most recent first).
        static func load() -> [String] {
            UserDefaults.standard.stringArray(forKey: key) ?? []
        }
    }

    // MARK: - Session

    /// Session behavior preferences (auto-title, etc.).
    enum Session {
        /// UserDefaults key for auto-title enabled state.
        /// Exposed (internal) so test helpers can set up UserDefaults directly.
        static let autoTitleEnabledKey = "\(AppIdentifiers.subsystem).session.autoTitle.enabled"

        static var isAutoTitleEnabled: Bool {
            UserDefaults.standard.object(forKey: autoTitleEnabledKey) as? Bool ?? false
        }

        static func setAutoTitleEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: autoTitleEnabledKey)
        }
    }

    // MARK: - Biometric

    /// Whether biometric gating is enabled for permission approvals.
    /// Default is ON — all permissions require Face ID / Touch ID confirmation.
    enum Biometric {
        private static let enabledKey = "\(AppIdentifiers.subsystem).biometric.enabled"

        static var isEnabled: Bool {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
        }
    }
}

// MARK: - Backward Compatibility

/// Source-compatibility aliases for consumers that reference the old type names.
/// New code should prefer `AppPreferences.LiveActivity`, `AppPreferences.Voice`, etc.
typealias LiveActivityPreferences = AppPreferences.LiveActivity
typealias NativePlotPreferences = AppPreferences.NativePlot
typealias ScreenAwakePreferences = AppPreferences.ScreenAwake
typealias VoiceInputPreferences = AppPreferences.Voice
typealias KeyboardLanguageStore = AppPreferences.Keyboard
typealias QuickSessionDefaults = AppPreferences.QuickSession
typealias RecentModels = AppPreferences.RecentModels
