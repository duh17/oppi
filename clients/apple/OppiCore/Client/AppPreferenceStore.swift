import Foundation

/// UIKit-free UserDefaults-backed preferences shared by Apple clients.
///
/// Keys match iOS `AppPreferences` so a device-local value round-trips across
/// the iOS and Mac apps. Platform Settings views paint these values.
enum AppPreferenceStore {

    // MARK: - Session

    /// Session behavior preferences (auto-title, etc.).
    enum Session {
        /// Which backend generates session titles.
        enum AutoTitleProvider: String, CaseIterable, Identifiable, Sendable {
            /// Server generates the title using a configured model.
            case server
            /// On-device Foundation model generates the title.
            case onDevice
            /// Title generation disabled.
            case off

            var id: String { rawValue }

            var label: String {
                switch self {
                case .server: return "Server"
                case .onDevice: return "On-device"
                case .off: return "Off"
                }
            }
        }

        static let autoTitleProviderKey = "\(AppIdentifiers.subsystem).session.autoTitle.provider"

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

        static var isAutoTitleEnabled: Bool {
            autoTitleProvider != .off
        }
    }

    // MARK: - Voice

    /// User-facing preferences for dictation engine selection and voice replies.
    enum Voice {
        enum EngineMode: String, CaseIterable, Identifiable, Sendable {
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

        /// User-facing engine choices. Auto remains available only as a stored
        /// value so older installs can be migrated safely.
        static let supportedModes: [EngineMode] = [.remote, .onDevice]

        static let engineModeKey = "\(AppIdentifiers.subsystem).voice.engineMode"
        static let replyModeKey = "\(AppIdentifiers.subsystem).voice.replyMode"
        static let sessionReplyModeOverridesKey = "\(AppIdentifiers.subsystem).voice.sessionReplyModeOverrides"

        static var engineMode: EngineMode {
            guard let raw = UserDefaults.standard.string(forKey: engineModeKey),
                  let mode = EngineMode(rawValue: raw)
            else {
                return .remote
            }
            return mode == .auto ? .remote : mode
        }

        static func setEngineMode(_ mode: EngineMode) {
            let normalizedMode: EngineMode = mode == .auto ? .remote : mode
            UserDefaults.standard.set(normalizedMode.rawValue, forKey: engineModeKey)
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
        enum TimeoutPreset: Int, CaseIterable, Identifiable, Sendable {
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

        static var timeoutPreset: TimeoutPreset {
            if let raw = UserDefaults.standard.object(forKey: timeoutPresetKey) as? Int,
               let preset = TimeoutPreset(rawValue: raw) {
                return preset
            }
            return .twoMinutes
        }

        static var keepAwakeDuration: Duration? {
            timeoutPreset.duration
        }

        static func setTimeoutPreset(_ preset: TimeoutPreset) {
            UserDefaults.standard.set(preset.rawValue, forKey: timeoutPresetKey)
        }
    }

    // MARK: - Appearance

    /// Spinner animation style. Key matches iOS `AppPreferences.Appearance`.
    enum Appearance {
        static let spinnerStyleKey = "spinnerStyle"
        static let spinnerDidChangeNotification = Notification.Name(
            "\(AppIdentifiers.subsystem).appearance.spinnerStyleDidChange"
        )

        static var spinnerStyle: SpinnerStyle {
            guard let raw = UserDefaults.standard.string(forKey: spinnerStyleKey),
                  let style = SpinnerStyle(rawValue: raw)
            else {
                return .brailleDots
            }
            return style
        }

        static func setSpinnerStyle(_ style: SpinnerStyle) {
            guard style != spinnerStyle else { return }
            UserDefaults.standard.set(style.rawValue, forKey: spinnerStyleKey)
            NotificationCenter.default.post(name: spinnerDidChangeNotification, object: nil)
        }
    }
}
