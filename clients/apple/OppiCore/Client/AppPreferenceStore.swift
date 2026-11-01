import Foundation

/// UIKit-free UserDefaults-backed preferences shared by Apple clients.
///
/// Keys match iOS `AppPreferences` so a device-local value round-trips across
/// the iOS and Mac apps. Platform Settings views paint these values.
enum AppPreferenceStore {

    // MARK: - Voice

    /// User-facing preferences for dictation engine selection and voice replies.
    enum Voice {
        enum EngineMode: String, CaseIterable, Identifiable, Sendable {
            case onDevice
            case remote

            var id: String { rawValue }

            var label: String {
                switch self {
                case .onDevice: return "On-device"
                case .remote: return "Server"
                }
            }
        }

        enum ReplyMode: String, CaseIterable, Identifiable, Sendable {
            case manual
            case autoplay

            var id: String { rawValue }

            var label: String {
                switch self {
                case .manual: return "Manual"
                case .autoplay: return "Agent decides"
                }
            }

            var detail: String {
                switch self {
                case .manual:
                    return "Keep voice replies tap-to-play in this app until you change the setting or session mode."
                case .autoplay:
                    return "Let each reply choose whether to play now or stay tap-to-play."
                }
            }
        }

        /// User-facing engine choices.
        static let supportedModes: [EngineMode] = [.remote, .onDevice]

        static let engineModeKey = "\(AppIdentifiers.subsystem).voice.engineMode"
        static let replyModeKey = "\(AppIdentifiers.subsystem).voice.replyMode"
        static let sessionReplyModeOverridesKey = "\(AppIdentifiers.subsystem).voice.sessionReplyModeOverrides"

        /// Unset (new install) is On-device, so audio leaves the phone only after the
        /// user picks Server. A stored `auto` was only ever written by an explicit
        /// "Automatic" pick in the old three-way picker (server when connected, else
        /// on-device), so it keeps the nearest current meaning: Server.
        static var engineMode: EngineMode {
            guard let raw = UserDefaults.standard.string(forKey: engineModeKey) else {
                return .onDevice
            }
            if raw == "auto" { return .remote }
            return EngineMode(rawValue: raw) ?? .onDevice
        }

        static func setEngineMode(_ mode: EngineMode) {
            UserDefaults.standard.set(mode.rawValue, forKey: engineModeKey)
        }

        static var replyMode: ReplyMode {
            guard let raw = UserDefaults.standard.string(forKey: replyModeKey) else {
                return .autoplay
            }
            switch raw {
            case ReplyMode.manual.rawValue, "voice", "audioMessage":
                return .manual
            case ReplyMode.autoplay.rawValue, "directSpeak":
                return .autoplay
            default:
                return .autoplay
            }
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

        static func shouldAutoplay(playbackBehavior: AudioPlaybackBehavior?, sessionId: String? = nil) -> Bool {
            let resolvedBehavior = playbackBehavior ?? .tapToPlay
            switch sessionReplyMode(for: sessionId) ?? replyMode {
            case .manual:
                return false
            case .autoplay:
                return resolvedBehavior == .playNow
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

    // MARK: - Screen Awake

    /// Keep the display awake while a session is working. Key matches iOS
    /// `AppPreferences.ScreenAwake`.
    enum ScreenAwake {
        enum TimeoutPreset: Int, CaseIterable, Identifiable, Sendable, Codable {
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

        static let timeoutPresetKey = "\(AppIdentifiers.subsystem).screenAwake.timeoutPreset"
        /// What nothing stored means; `SettingsCatalog.keepAwakeAfterActivity` uses this same constant.
        static let timeoutPresetDefault = TimeoutPreset.twoMinutes

        static var timeoutPreset: TimeoutPreset {
            if let raw = UserDefaults.standard.object(forKey: timeoutPresetKey) as? Int,
               let preset = TimeoutPreset(rawValue: raw) {
                return preset
            }
            return timeoutPresetDefault
        }

        static var keepAwakeDuration: Duration? {
            timeoutPreset.duration
        }

        static func setTimeoutPreset(_ preset: TimeoutPreset) {
            UserDefaults.standard.set(preset.rawValue, forKey: timeoutPresetKey)
        }
    }

    // MARK: - Editor

    /// The code editor's Auto-Save, for every document the editor writes. Key
    /// matches `CodeEditorPreferences`, which stores and reads this same value,
    /// so the editor's "…" menu, Settings > Editor, and the edit session's
    /// write gate see one setting.
    enum Editor {
        static let autoSaveKey = "\(AppIdentifiers.subsystem).editor.autoSave"
        /// Off: nothing is written until a person saves. `SettingsCatalog.autoSave` uses this constant.
        static let autoSaveDefault = false
    }

    // MARK: - Interaction

    /// Optional tactile feedback. Key matches iOS `AppPreferences.Interaction`.
    enum Interaction {
        static let hapticFeedbackEnabledKey = "\(AppIdentifiers.subsystem).interaction.hapticFeedback.enabled"
        /// What nothing stored means; `SettingsCatalog.hapticFeedback` uses this same constant.
        static let hapticFeedbackEnabledDefault = true

        static var isHapticFeedbackEnabled: Bool { isHapticFeedbackEnabled(in: .standard) }

        static func isHapticFeedbackEnabled(in defaults: UserDefaults) -> Bool {
            defaults.object(forKey: hapticFeedbackEnabledKey) as? Bool ?? hapticFeedbackEnabledDefault
        }

        static func setHapticFeedbackEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: hapticFeedbackEnabledKey)
        }
    }

    // MARK: - Experiments

    /// Opt-in features, kept on this device (Settings → Experiments). Every flag
    /// defaults to off, and this is the one place their keys live, so iOS
    /// `AppPreferences.Experiments` and `SettingsCatalog` read one value.
    enum Experiments {
        static let rexKey = "\(AppIdentifiers.subsystem).experiments.rex"
        static let herdrKey = "\(AppIdentifiers.subsystem).experiments.herdr"
        /// What nothing stored means; both declarations use it.
        static let enabledDefault = false

        /// Rex: the Terminal tab's Rex sections, Rex screens, panes and tailnet list.
        static var rexEnabled: Bool { flag(rexKey) }

        /// Herdr: its bar button, agents and workspaces, and opening a folder inside it.
        static var herdrEnabled: Bool { flag(herdrKey) }

        /// Nothing stored means the default; anything stored reads as a bool, so a
        /// launch argument's `-key YES` (a test's switch) counts too.
        private static func flag(_ key: String) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? enabledDefault : UserDefaults.standard.bool(forKey: key)
        }
    }

    // MARK: - Terminal

    /// The Terminal page's mode (`SSHTerminalPageMode`), kept as its raw value on
    /// this device. Nothing stored means the page's own fallback (Rex while its
    /// experiment is on, else Shell), which is why the default is empty rather than
    /// a mode: a stored value is always a choice someone made.
    enum Terminal {
        static let pageModeKey = "\(AppIdentifiers.subsystem).sshTerminal.pageMode"
        static let pageModeDefault = ""
    }

    // MARK: - Durable Sessions

    /// Which engine Quick Session starts a new session on, where its server has Durable
    /// Sessions on (Server Settings). The pill still switches one session either way.
    enum DurableSessions {
        /// Kept under the name it had on the Experiments page, so that choice carries over.
        static let startDurableKey = "\(AppIdentifiers.subsystem).experiments.durableSessionsDefault"
        /// What nothing stored means; `SettingsCatalog.startSessionsAsDurable` uses this same constant.
        static let startDurableDefault = false

        static var startsDurable: Bool {
            UserDefaults.standard.object(forKey: startDurableKey) as? Bool ?? startDurableDefault
        }
    }

    // MARK: - Browser

    /// Where regular web links open. Key matches iOS `AppPreferences.Browser`.
    enum Browser {
        enum LinkOpeningMode: String, CaseIterable, Identifiable, Sendable, Codable {
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

        static let linkOpeningModeKey = "\(AppIdentifiers.subsystem).browser.linkOpeningMode"
        /// What nothing stored means; `SettingsCatalog.openLinks` uses this same constant.
        static let linkOpeningModeDefault = LinkOpeningMode.inApp

        static var linkOpeningMode: LinkOpeningMode { linkOpeningMode(in: .standard) }

        static func linkOpeningMode(in defaults: UserDefaults) -> LinkOpeningMode {
            guard let raw = defaults.string(forKey: linkOpeningModeKey),
                  let mode = LinkOpeningMode(rawValue: raw)
            else {
                return linkOpeningModeDefault
            }
            return mode
        }

        static func setLinkOpeningMode(_ mode: LinkOpeningMode, in defaults: UserDefaults = .standard) {
            defaults.set(mode.rawValue, forKey: linkOpeningModeKey)
        }
    }

    // MARK: - Appearance

    /// Spinner and dictation indicator styles. Spinner key matches iOS
    /// `AppPreferences.Appearance`.
    enum Appearance {
        static let spinnerStyleKey = "spinnerStyle"
        static let dictationIndicatorStyleKey =
            "\(AppIdentifiers.subsystem).appearance.dictationIndicatorStyle"
        static let spinnerDidChangeNotification = Notification.Name(
            "\(AppIdentifiers.subsystem).appearance.spinnerStyleDidChange"
        )
        static let dictationIndicatorDidChangeNotification = Notification.Name(
            "\(AppIdentifiers.subsystem).appearance.dictationIndicatorStyleDidChange"
        )

        static var spinnerStyle: SpinnerStyle { spinnerStyle(in: .standard) }

        static func spinnerStyle(in defaults: UserDefaults) -> SpinnerStyle {
            guard let raw = defaults.string(forKey: spinnerStyleKey),
                  let style = SpinnerStyle(rawValue: raw)
            else {
                return .working
            }
            return style
        }

        static func setSpinnerStyle(_ style: SpinnerStyle, in defaults: UserDefaults = .standard) {
            guard style != spinnerStyle(in: defaults) else { return }
            defaults.set(style.rawValue, forKey: spinnerStyleKey)
            NotificationCenter.default.post(name: spinnerDidChangeNotification, object: nil)
        }

        static var dictationIndicatorStyle: DictationIndicatorStyle { dictationIndicatorStyle(in: .standard) }

        static func dictationIndicatorStyle(in defaults: UserDefaults) -> DictationIndicatorStyle {
            guard let raw = defaults.string(forKey: dictationIndicatorStyleKey),
                  let style = DictationIndicatorStyle(rawValue: raw)
            else {
                return .ring
            }
            return style
        }

        static func setDictationIndicatorStyle(_ style: DictationIndicatorStyle, in defaults: UserDefaults = .standard) {
            guard style != dictationIndicatorStyle(in: defaults) else { return }
            defaults.set(style.rawValue, forKey: dictationIndicatorStyleKey)
            NotificationCenter.default.post(name: dictationIndicatorDidChangeNotification, object: nil)
        }
    }
}
