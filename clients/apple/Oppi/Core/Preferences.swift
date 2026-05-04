import Foundation

enum VoiceReplyDelivery: String, Codable, Sendable, Equatable {
    case voiceMessage
    case directSpeak
}


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
///     let enabled = AppPreferences.LiveActivity.isEnabled
///     AppPreferences.Session.setAutoTitleProvider(.server)
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
                case .remote: return "Server"
                }
            }
        }

        enum ReplyMode: String, CaseIterable, Identifiable {
            case manual
            case autoplay

            var id: String { rawValue }

            var label: String {
                switch self {
                case .manual: return "Tap to play"
                case .autoplay: return "Autoplay"
                }
            }

            var detail: String {
                switch self {
                case .manual:
                    return "Default to playable voice cards. The agent can still speak out loud in this session if you ask."
                case .autoplay:
                    return "Default to speaking voice replies out loud. The agent can still switch this session back to tap-to-play if you ask."
                }
            }
        }

        /// User-facing engine choices. Auto remains available only as a legacy
        /// stored value so older installs can be migrated safely.
        static let supportedModes: [EngineMode] = [.remote, .onDevice]

        private static let engineModeKey = "\(AppIdentifiers.subsystem).voice.engineMode"
        private static let replyModeKey = "\(AppIdentifiers.subsystem).voice.replyMode"
        private static let sessionReplyModeOverridesKey = "\(AppIdentifiers.subsystem).voice.sessionReplyModeOverrides"

        static var engineMode: EngineMode {
            guard let raw = UserDefaults.standard.string(forKey: engineModeKey),
                  let mode = EngineMode(rawValue: raw)
            else {
                return .remote
            }
            return mode == .auto ? .remote : mode
        }

        static var replyMode: ReplyMode {
            guard let raw = UserDefaults.standard.string(forKey: replyModeKey) else {
                return .autoplay
            }
            switch raw {
            case ReplyMode.manual.rawValue, "voice", "voiceMessage":
                return .manual
            case ReplyMode.autoplay.rawValue, "directSpeak":
                return .autoplay
            default:
                return .autoplay
            }
        }

        static func setEngineMode(_ mode: EngineMode) {
            let normalizedMode: EngineMode = mode == .auto ? .remote : mode
            UserDefaults.standard.set(normalizedMode.rawValue, forKey: engineModeKey)
        }

        static func setReplyMode(_ mode: ReplyMode) {
            UserDefaults.standard.set(mode.rawValue, forKey: replyModeKey)
        }

        static func sessionReplyMode(for sessionId: String?) -> ReplyMode? {
            guard let sessionId = normalizedSessionId(sessionId) else { return nil }
            let stored = sessionReplyModeOverrides()[sessionId]
            return stored.flatMap(ReplyMode.init(rawValue:))
        }

        static func setSessionReplyMode(_ mode: ReplyMode?, for sessionId: String?) {
            guard let sessionId = normalizedSessionId(sessionId) else { return }
            var overrides = sessionReplyModeOverrides()
            overrides[sessionId] = mode?.rawValue
            if overrides.isEmpty {
                UserDefaults.standard.removeObject(forKey: sessionReplyModeOverridesKey)
            } else {
                UserDefaults.standard.set(overrides, forKey: sessionReplyModeOverridesKey)
            }
        }

        static func applySessionReplyModeDetails(_ details: JSONValue?, sessionId: String?) {
            guard let object = details?.objectValue,
                  object["kind"]?.stringValue == "voice_reply_mode"
            else {
                return
            }

            switch object["mode"]?.stringValue {
            case ReplyMode.manual.rawValue:
                setSessionReplyMode(.manual, for: sessionId)
            case ReplyMode.autoplay.rawValue:
                setSessionReplyMode(.autoplay, for: sessionId)
            case "default", nil:
                setSessionReplyMode(nil, for: sessionId)
            default:
                break
            }
        }

        static func shouldAutoplay(delivery: VoiceReplyDelivery?, sessionId: String? = nil) -> Bool {
            switch sessionReplyMode(for: sessionId) ?? replyMode {
            case .manual:
                return delivery == .directSpeak
            case .autoplay:
                return delivery != .voiceMessage
            }
        }

        private static func sessionReplyModeOverrides() -> [String: String] {
            UserDefaults.standard.dictionary(forKey: sessionReplyModeOverridesKey) as? [String: String] ?? [:]
        }

        private static func normalizedSessionId(_ sessionId: String?) -> String? {
            guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty else {
                return nil
            }
            return sessionId
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
    /// Stores the last-used workspace so the sheet opens in the user's most recent context.
    enum QuickSession {
        private static let prefix = "\(AppIdentifiers.subsystem).quickSession"

        private static let lastWorkspaceIdKey = "\(prefix).lastWorkspaceId"
        private static let defaultWorkspaceIdKey = "\(prefix).defaultWorkspaceId"

        // MARK: Workspace

        static var lastWorkspaceId: String? {
            UserDefaults.standard.string(forKey: lastWorkspaceIdKey)
        }

        static var defaultWorkspaceId: String? {
            UserDefaults.standard.string(forKey: defaultWorkspaceIdKey)
        }

        static func saveWorkspaceId(_ id: String) {
            UserDefaults.standard.set(id, forKey: lastWorkspaceIdKey)
        }

        static func saveDefaultWorkspaceId(_ id: String?) {
            if let id, !id.isEmpty {
                UserDefaults.standard.set(id, forKey: defaultWorkspaceIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultWorkspaceIdKey)
            }
        }

        struct PreferredWorkspaceSelection: Sendable, Equatable {
            let id: String
            let source: String
        }

        static func preferredWorkspaceSelection(
            in workspaces: [(id: String, name: String)]
        ) -> PreferredWorkspaceSelection? {
            guard !workspaces.isEmpty else { return nil }

            let ids = Set(workspaces.map(\.id))
            if let lastWorkspaceId, ids.contains(lastWorkspaceId) {
                return PreferredWorkspaceSelection(id: lastWorkspaceId, source: "last_used")
            }

            if let explicitDefault = defaultWorkspaceId, ids.contains(explicitDefault) {
                return PreferredWorkspaceSelection(id: explicitDefault, source: "default")
            }

            return PreferredWorkspaceSelection(id: workspaces[0].id, source: "first_available")
        }

        static func preferredWorkspaceId(in workspaces: [(id: String, name: String)]) -> String? {
            preferredWorkspaceSelection(in: workspaces)?.id
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

        /// Which backend generates session titles.
        enum AutoTitleProvider: String, CaseIterable {
            /// Server generates the title using a configured model.
            case server
            /// On-device Foundation model generates the title.
            case onDevice
            /// Title generation disabled.
            case off
        }

        /// UserDefaults key for auto-title provider.
        static let autoTitleProviderKey = "\(AppIdentifiers.subsystem).session.autoTitle.provider"

        /// The active auto-title provider.
        static var autoTitleProvider: AutoTitleProvider {
            if let raw = UserDefaults.standard.string(forKey: autoTitleProviderKey),
               let provider = AutoTitleProvider(rawValue: raw) {
                return provider
            }
            return .server
        }

        static func setAutoTitleProvider(_ provider: AutoTitleProvider) {
            UserDefaults.standard.set(provider.rawValue, forKey: autoTitleProviderKey)
        }

        /// Convenience: true when any provider is active.
        static var isAutoTitleEnabled: Bool {
            autoTitleProvider != .off
        }
    }

    // MARK: - Share

    enum Share {
        private static let redactionPolicyKey = "\(AppIdentifiers.subsystem).share.redactionPolicy.v1"

        static var redactionPolicy: ShareSessionRedactionPolicy {
            guard let data = UserDefaults.standard.data(forKey: redactionPolicyKey),
                  let decoded = try? JSONDecoder().decode(ShareSessionRedactionPolicy.self, from: data)
            else {
                return ShareSessionRedactionPolicy.recommended
            }

            return decoded.normalized
        }

        static func setRedactionPolicy(_ policy: ShareSessionRedactionPolicy) {
            guard let data = try? JSONEncoder().encode(policy.normalized) else { return }
            UserDefaults.standard.set(data, forKey: redactionPolicyKey)
        }
    }

    // MARK: - Telemetry

    /// User opt-in for server-side telemetry in release builds.
    ///
    /// Default is OFF. When enabled, the app uploads MetricKit payloads and
    /// chat performance metrics to the oppi server for diagnostic review.
    /// Debug/internal builds always upload regardless of this setting.
    enum Telemetry {
        private static let enabledKey = "\(AppIdentifiers.subsystem).telemetry.enabled"

        static var isEnabled: Bool {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
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

