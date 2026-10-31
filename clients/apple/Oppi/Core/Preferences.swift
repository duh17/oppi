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
///     AppPreferences.Voice.setEngineMode(.remote)
///
/// Per-server settings live with their feature: `PushRegistration` and
/// `LiveActivitySettings`.
enum AppPreferences {

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

    // MARK: - Experiments

    /// Opt-in features, saved on this device. Every flag defaults to off.
    enum Experiments {
        static let liveVoiceKey = "\(AppIdentifiers.subsystem).experiments.liveVoice"

        /// Live Voice: the call entries in chat and Quick Session. It only governs new
        /// starts; a call already running keeps running when this turns off.
        static var liveVoiceEnabled: Bool {
            UserDefaults.standard.bool(forKey: liveVoiceKey)
        }
    }

    // MARK: - Session Rows

    /// Device-local session list display: one saved row appearance.
    enum SessionRows {
        static let displayKey = "\(AppIdentifiers.subsystem).sessionRows.display"
        static let didChangeNotification = Notification.Name("oppi.sessionRows.displayDidChange")

        /// Missing, malformed, or unrecognized stored values fall back to today's rich rows.
        static var display: SessionRowDisplay {
            guard let data = UserDefaults.standard.data(forKey: displayKey),
                  let stored = try? JSONDecoder().decode(SessionRowDisplay.self, from: data)
            else {
                return .standard
            }
            return stored
        }

        static func setDisplay(_ display: SessionRowDisplay) {
            guard display != Self.display, let data = try? JSONEncoder().encode(display) else { return }
            UserDefaults.standard.set(data, forKey: displayKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - Browser

    /// User-facing preference for where regular web links open.
    enum Browser {
        typealias LinkOpeningMode = AppPreferenceStore.Browser.LinkOpeningMode

        static var linkOpeningMode: LinkOpeningMode {
            AppPreferenceStore.Browser.linkOpeningMode
        }

        static func setLinkOpeningMode(_ mode: LinkOpeningMode) {
            AppPreferenceStore.Browser.setLinkOpeningMode(mode)
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

    /// Device-local chat style. It applies to every session, classic and
    /// durable, at every width, and never changes session or Agent data sent
    /// over the wire. An Agent may carry its own style on this device (Edit
    /// Agent → Chat Style); its sessions use that instead of `style`.
    enum ChatDisplay {
        /// How chats look. Full shows every tool call and thinking block;
        /// Compact folds each turn's work into a strip drawn in
        /// `WorkStripStyle`; Chat uses the messaging layout
        /// (`ChatTimelineChromeStyle.conversation`) with a
        /// "Worked \u{00B7} N steps" pill, which ignores `WorkStripStyle`.
        enum Style: String, CaseIterable, Identifiable {
            case full
            case compact
            case chat

            var id: String { rawValue }

            var label: String {
                switch self {
                case .full: return "Full"
                case .compact: return "Compact"
                case .chat: return "Chat"
                }
            }

            /// Compact and Chat fold each turn's tool calls and thinking.
            var foldsWork: Bool { self != .full }
        }

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

        static let styleKey = "\(AppIdentifiers.subsystem).chatDisplay.style"
        static let workStripStyleKey = "\(AppIdentifiers.subsystem).chatDisplay.workStripStyle"
        /// `[serverId: [agentId: Style.rawValue]]`. Agent IDs are per server.
        static let agentStylesKey = "\(AppIdentifiers.subsystem).chatDisplay.agentStyles"
        static let didChangeNotification = Notification.Name("oppi.chatDisplay.didChange")

        static var style: Style {
            UserDefaults.standard.string(forKey: styleKey).flatMap(Style.init(rawValue:)) ?? .full
        }

        /// The style a session shows: its Agent's style on this device, else
        /// the Settings style.
        static func style(serverId: String?, agentId: String?) -> Style {
            guard let serverId, let agentId else { return style }
            return agentStyle(serverId: serverId, agentId: agentId) ?? style
        }

        /// The style this Agent's sessions use on this device; nil follows `style`.
        static func agentStyle(serverId: String, agentId: String) -> Style? {
            agentStyles[serverId]?[agentId].flatMap(Style.init(rawValue:))
        }

        static func setAgentStyle(_ style: Style?, serverId: String, agentId: String) {
            guard style != agentStyle(serverId: serverId, agentId: agentId) else { return }
            var all = agentStyles
            var server = all[serverId] ?? [:]
            server[agentId] = style?.rawValue
            all[serverId] = server.isEmpty ? nil : server
            UserDefaults.standard.set(all, forKey: agentStylesKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }

        private static var agentStyles: [String: [String: String]] {
            UserDefaults.standard.dictionary(forKey: agentStylesKey) as? [String: [String: String]] ?? [:]
        }

        static var workStripStyle: WorkStripStyle {
            guard let raw = UserDefaults.standard.string(forKey: workStripStyleKey),
                  let style = WorkStripStyle(rawValue: raw) else {
                return .icons
            }
            return style
        }

        static func setStyle(_ style: Style) {
            guard style != self.style else { return }
            UserDefaults.standard.set(style.rawValue, forKey: styleKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }

        static func setWorkStripStyle(_ style: WorkStripStyle) {
            guard style != workStripStyle else { return }
            UserDefaults.standard.set(style.rawValue, forKey: workStripStyleKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - Chat Top Bar

    /// Which buttons the chat's top bar shows (Files, Git, Outline, Context, Terminal)
    /// and in what order. Hidden buttons live in the bar's … menu. Device-local,
    /// like the other chat display preferences, and the same for every session.
    enum ChatTopBar {
        static let orderKey = "\(AppIdentifiers.subsystem).chatDisplay.topBarOrder"
        static let shownKey = "\(AppIdentifiers.subsystem).chatDisplay.topBarShown"
        static let didChangeNotification = Notification.Name("oppi.chatTopBar.didChange")

        static let preference = BarLayoutPreference<ChatTopBarAction>(
            orderKey: orderKey, shownKey: shownKey, didChangeNotification: didChangeNotification
        )

        /// The stored order and visibility, or the default bar (the context ring
        /// alone, the rest in the menu). Only the Top Bar page's switches and
        /// drags write it (`BarLayoutPreference`).
        static var layout: ChatTopBarLayout { preference.layout(in: .standard) }

        static func layout(in defaults: UserDefaults) -> ChatTopBarLayout {
            preference.layout(in: defaults)
        }

        static func setLayout(_ layout: ChatTopBarLayout) {
            preference.save(layout, in: .standard)
        }

        static func setLayout(_ layout: ChatTopBarLayout, in defaults: UserDefaults) {
            preference.save(layout, in: defaults)
        }
    }

    // MARK: - Appearance

    /// Spinner and dictation indicator style preferences.
    enum Appearance {
        static var spinnerStyle: SpinnerStyle {
            AppPreferenceStore.Appearance.spinnerStyle
        }

        static func setSpinnerStyle(_ style: SpinnerStyle) {
            AppPreferenceStore.Appearance.setSpinnerStyle(style)
        }

        static var dictationIndicatorStyle: DictationIndicatorStyle {
            AppPreferenceStore.Appearance.dictationIndicatorStyle
        }

        static func setDictationIndicatorStyle(_ style: DictationIndicatorStyle) {
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(style)
        }
    }

    // MARK: - Interaction

    /// User-facing preference for optional tactile feedback.
    enum Interaction {
        static var isHapticFeedbackEnabled: Bool {
            AppPreferenceStore.Interaction.isHapticFeedbackEnabled
        }

        static func setHapticFeedbackEnabled(_ enabled: Bool) {
            AppPreferenceStore.Interaction.setHapticFeedbackEnabled(enabled)
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

    // MARK: - Tailnet

    /// Whether Oppi runs its embedded Tailscale node. Default is OFF; the
    /// user turns it on from Settings. Launch restarts it only when a paired
    /// Tailscale hostname needs it; otherwise it starts lazily.
    enum Tailnet {
        private static let enabledKey = "\(AppIdentifiers.subsystem).tailnet.enabled"

        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: enabledKey)
        }

        static func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
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
