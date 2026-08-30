import Foundation

/// Unified preference system for all UserDefaults-backed settings.
///
/// Organized by domain — each is an enum with static getters and setters,
/// following the `FontPreferences` pattern. Every runtime preference key
/// lives here for discoverability.
///
/// Typography preferences remain in `FontPreferences` due to their
/// notification/font-rebuild lifecycle. `QuickCommentTemplateStore` manages its
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
        typealias TimeoutPreset = AppPreferenceStore.ScreenAwake.TimeoutPreset

        static var timeoutPreset: TimeoutPreset {
            AppPreferenceStore.ScreenAwake.timeoutPreset
        }

        static var keepAwakeDuration: Duration? {
            AppPreferenceStore.ScreenAwake.keepAwakeDuration
        }

        static func setTimeoutPreset(_ preset: TimeoutPreset) {
            AppPreferenceStore.ScreenAwake.setTimeoutPreset(preset)
        }
    }

    // MARK: - Browser

    /// User-facing preference for where regular web links open.
    enum Browser {
        enum LinkOpeningMode: String, CaseIterable, Identifiable {
            case inApp
            case external

            var id: String { rawValue }

            var label: String {
                switch self {
                case .inApp: return "In-App Browser"
                case .external: return "External Browser"
                }
            }

            var detail: String {
                switch self {
                case .inApp:
                    return "Open web links in Oppi's built-in Safari sheet. Oppi cannot read browser cookies or page data."
                case .external:
                    return "Open web links in your default browser outside Oppi."
                }
            }

            var openActionTitle: String {
                switch self {
                case .inApp: return "Open In-App Browser"
                case .external: return "Open in External Browser"
                }
            }
        }

        private static let linkOpeningModeKey = "\(AppIdentifiers.subsystem).browser.linkOpeningMode"

        static var linkOpeningMode: LinkOpeningMode {
            guard let raw = UserDefaults.standard.string(forKey: linkOpeningModeKey),
                  let mode = LinkOpeningMode(rawValue: raw)
            else {
                return .inApp
            }
            return mode
        }

        static func setLinkOpeningMode(_ mode: LinkOpeningMode) {
            UserDefaults.standard.set(mode.rawValue, forKey: linkOpeningModeKey)
        }
    }

    // MARK: - Voice Input

    /// User-facing preferences for voice input engine selection.
    enum Voice {
        typealias EngineMode = AppPreferenceStore.Voice.EngineMode
        typealias ReplyMode = AppPreferenceStore.Voice.ReplyMode

        /// User-facing engine choices. Auto remains available only as a legacy
        /// stored value so older installs can be migrated safely.
        static let supportedModes: [EngineMode] = AppPreferenceStore.Voice.supportedModes

        static var engineMode: EngineMode {
            AppPreferenceStore.Voice.engineMode
        }

        static var replyMode: ReplyMode {
            AppPreferenceStore.Voice.replyMode
        }

        static func setEngineMode(_ mode: EngineMode) {
            AppPreferenceStore.Voice.setEngineMode(mode)
        }

        static func setReplyMode(_ mode: ReplyMode) {
            AppPreferenceStore.Voice.setReplyMode(mode)
        }

        static func sessionReplyMode(for sessionId: String?) -> ReplyMode? {
            AppPreferenceStore.Voice.sessionReplyMode(for: sessionId)
        }

        static func setSessionReplyMode(_ mode: ReplyMode?, for sessionId: String?) {
            AppPreferenceStore.Voice.setSessionReplyMode(mode, for: sessionId)
        }

        static func applySessionReplyModeDetails(_ details: JSONValue?, sessionId: String?) {
            AppPreferenceStore.Voice.applySessionReplyModeDetails(details, sessionId: sessionId)
        }

        static func shouldAutoplay(playbackBehavior: AudioPlaybackBehavior?, sessionId: String? = nil) -> Bool {
            AppPreferenceStore.Voice.shouldAutoplay(playbackBehavior: playbackBehavior, sessionId: sessionId)
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
        private static let lastThinkingLevelKey = "\(prefix).lastThinkingLevel"
        private static let lastAgentIdKey = "\(prefix).lastAgentId"
        private static let pendingDictationCleanupKey = "\(prefix).pendingDictationCleanup"

        struct PendingDictationCleanup: Codable, Sendable, Equatable {
            let serverId: String
            let workspaceId: String
            let sessionId: String
        }

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

        // MARK: Thinking

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

        // MARK: Agent

        /// Last Quick Session Agent pick. `nil` means plain Pi.
        static var lastAgentId: String? {
            UserDefaults.standard.string(forKey: lastAgentIdKey)
        }

        static func saveAgentId(_ id: String?) {
            let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                UserDefaults.standard.set(normalized, forKey: lastAgentIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastAgentIdKey)
            }
        }

        // MARK: Pending Dictation Cleanup

        static var pendingDictationCleanups: [PendingDictationCleanup] {
            guard let data = UserDefaults.standard.data(forKey: pendingDictationCleanupKey) else {
                return []
            }
            do {
                return try JSONDecoder().decode([PendingDictationCleanup].self, from: data)
            } catch {
                UserDefaults.standard.removeObject(forKey: pendingDictationCleanupKey)
                return []
            }
        }

        static func enqueuePendingDictationCleanup(_ cleanup: PendingDictationCleanup) {
            var items = pendingDictationCleanups
            if !items.contains(cleanup) {
                items.append(cleanup)
            }
            savePendingDictationCleanups(items)
        }

        static func removePendingDictationCleanup(_ cleanup: PendingDictationCleanup) {
            let items = pendingDictationCleanups.filter { $0 != cleanup }
            savePendingDictationCleanups(items)
        }

        static func clearPendingDictationCleanups() {
            UserDefaults.standard.removeObject(forKey: pendingDictationCleanupKey)
        }

        private static func savePendingDictationCleanups(_ items: [PendingDictationCleanup]) {
            guard !items.isEmpty else {
                clearPendingDictationCleanups()
                return
            }
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: pendingDictationCleanupKey)
            }
        }

    }

    // MARK: - Chat Display

    /// Device-local Compact turns preference. It never changes session or
    /// Agent data sent over the wire.
    enum ChatDisplay {
        enum WorkStripStyle: String, CaseIterable, Identifiable {
            case icons
            case words

            var id: String { rawValue }

            var label: String {
                switch self {
                case .icons: return "Icons"
                case .words: return "Words"
                }
            }
        }

        static let compactTurnsKey = "\(AppIdentifiers.subsystem).chatDisplay.compactTurns"
        static let workStripStyleKey = "\(AppIdentifiers.subsystem).chatDisplay.workStripStyle"
        static let didChangeNotification = Notification.Name("oppi.chatDisplay.compactTurnsDidChange")

        static var isCompactTurnsEnabled: Bool {
            UserDefaults.standard.object(forKey: compactTurnsKey) as? Bool ?? false
        }

        static var workStripStyle: WorkStripStyle {
            guard let raw = UserDefaults.standard.string(forKey: workStripStyleKey),
                  let style = WorkStripStyle(rawValue: raw) else {
                return .icons
            }
            return style
        }

        static func setCompactTurnsEnabled(_ enabled: Bool) {
            guard enabled != isCompactTurnsEnabled else { return }
            UserDefaults.standard.set(enabled, forKey: compactTurnsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }

        static func setWorkStripStyle(_ style: WorkStripStyle) {
            guard style != workStripStyle else { return }
            UserDefaults.standard.set(style.rawValue, forKey: workStripStyleKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - Appearance

    /// Spinner animation style preference.
    enum Appearance {
        static var spinnerStyle: SpinnerStyle {
            AppPreferenceStore.Appearance.spinnerStyle
        }

        static func setSpinnerStyle(_ style: SpinnerStyle) {
            AppPreferenceStore.Appearance.setSpinnerStyle(style)
        }
    }

    // MARK: - Interaction

    /// User-facing preference for optional tactile feedback.
    enum Interaction {
        private static let hapticFeedbackEnabledKey = "\(AppIdentifiers.subsystem).interaction.hapticFeedback.enabled"

        static var isHapticFeedbackEnabled: Bool {
            UserDefaults.standard.object(forKey: hapticFeedbackEnabledKey) as? Bool ?? true
        }

        static func setHapticFeedbackEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: hapticFeedbackEnabledKey)
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
        typealias AutoTitleProvider = AppPreferenceStore.Session.AutoTitleProvider

        /// UserDefaults key for auto-title provider.
        static let autoTitleProviderKey = AppPreferenceStore.Session.autoTitleProviderKey

        /// The active auto-title provider.
        static var autoTitleProvider: AutoTitleProvider {
            AppPreferenceStore.Session.autoTitleProvider
        }

        static func setAutoTitleProvider(_ provider: AutoTitleProvider) {
            AppPreferenceStore.Session.setAutoTitleProvider(provider)
        }

        /// Convenience: true when any provider is active.
        static var isAutoTitleEnabled: Bool {
            AppPreferenceStore.Session.isAutoTitleEnabled
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

    /// User preference for uploading diagnostics to the paired server.
    ///
    /// Until the user chooses, diagnostics default ON for internal builds and
    /// OFF for public builds. The explicit choice is device-local and applies
    /// to MetricKit payloads, client logs, and performance metrics.
    enum Telemetry {
        private static let enabledKey = "\(AppIdentifiers.subsystem).telemetry.enabled"

        static var isEnabled: Bool {
            resolvedEnabled(
                storedValue: UserDefaults.standard.object(forKey: enabledKey) as? Bool,
                defaultEnabled: TelemetryMode.current.diagnosticsEnabledByDefault
            )
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
        }

        static func resolvedEnabled(storedValue: Bool?, defaultEnabled: Bool) -> Bool {
            storedValue ?? defaultEnabled
        }
    }

    // MARK: - Biometric

    /// Whether biometric gating is enabled for sensitive local actions.
    /// Default is ON.
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
