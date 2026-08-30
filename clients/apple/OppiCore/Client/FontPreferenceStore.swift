import Foundation

/// UIKit-free typography preference keys, scales, and family names.
///
/// Persistence uses the same UserDefaults keys as iOS `FontPreferences`.
/// Platform apps own UIFont/NSFont loading and cache rebuilds.
enum FontPreferenceStore {
    static let didChangeNotification = Notification.Name("FontPreferencesDidChange")

    static let minimumCodeTextScale = 0.85
    static let standardCodeTextScale = 1.0
    static let maximumCodeTextScale = 1.45
    static let minimumMessageTextScale = 0.90
    static let standardMessageTextScale = 1.0
    static let maximumMessageTextScale = 1.35
    static let defaultEffectiveCodeTextScale = 1.10

    static let codeFontKey = "codeFontFamily"
    static let codeTextScaleKey = "codeTextRelativeScale"
    static let storedEffectiveCodeTextScaleKey = "codeTextScale"
    static let codeFontSizePresetKey = "codeFontSize"
    static let messageTextScaleKey = "messageTextScale"
    static let monoMessagesKey = "useMonoForMessages"

    enum CodeFontFamily: String, CaseIterable, Identifiable, Sendable {
        case system = "system"
        case firaCode = "FiraCode"
        case jetBrainsMono = "JetBrainsMono"
        case cascadiaCode = "CascadiaCode"
        case sourceCodePro = "SourceCodePro"
        case monaspaceNeon = "MonaspaceNeon"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "SF Mono"
            case .firaCode: return "Fira Code"
            case .jetBrainsMono: return "JetBrains Mono"
            case .cascadiaCode: return "Cascadia Code"
            case .sourceCodePro: return "Source Code Pro"
            case .monaspaceNeon: return "Monaspace Neon"
            }
        }

        /// Font name prefix for PostScript lookup. nil means system mono.
        var fontNamePrefix: String? {
            switch self {
            case .system: return nil
            case .firaCode: return "FiraCode"
            case .jetBrainsMono: return "JetBrainsMono"
            case .cascadiaCode: return "CascadiaCode"
            case .sourceCodePro: return "SourceCodePro"
            case .monaspaceNeon: return "MonaspaceNeon"
            }
        }
    }

    static var codeFont: CodeFontFamily {
        guard let raw = UserDefaults.standard.string(forKey: codeFontKey),
              let family = CodeFontFamily(rawValue: raw) else {
            return .system
        }
        return family
    }

    static func setCodeFont(_ family: CodeFontFamily) {
        UserDefaults.standard.set(family.rawValue, forKey: codeFontKey)
        notifyDidChange()
    }

    static var codeTextScale: Double {
        if UserDefaults.standard.object(forKey: codeTextScaleKey) != nil {
            return clampedCodeTextScale(UserDefaults.standard.double(forKey: codeTextScaleKey))
        }

        if UserDefaults.standard.object(forKey: storedEffectiveCodeTextScaleKey) != nil {
            return clampedCodeTextScale(
                UserDefaults.standard.double(forKey: storedEffectiveCodeTextScaleKey)
                    / defaultEffectiveCodeTextScale
            )
        }

        if let presetRaw = UserDefaults.standard.string(forKey: codeFontSizePresetKey) {
            return scaleForStoredCodeFontSizePreset(rawValue: presetRaw)
        }

        return standardCodeTextScale
    }

    static func setCodeTextScale(_ scale: Double) {
        UserDefaults.standard.set(clampedCodeTextScale(scale), forKey: codeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: storedEffectiveCodeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: codeFontSizePresetKey)
        notifyDidChange()
    }

    static func clampedCodeTextScale(_ scale: Double) -> Double {
        min(maximumCodeTextScale, max(minimumCodeTextScale, scale))
    }

    static func effectiveCodeTextScale(_ codeTextScale: Double) -> Double {
        clampedCodeTextScale(codeTextScale) * defaultEffectiveCodeTextScale
    }

    static func codePointSize(baseSize: Double, codeTextScale: Double? = nil) -> Double {
        (baseSize * effectiveCodeTextScale(codeTextScale ?? self.codeTextScale)).rounded()
    }

    static var messageTextScale: Double {
        if UserDefaults.standard.object(forKey: messageTextScaleKey) != nil {
            return clampedMessageTextScale(UserDefaults.standard.double(forKey: messageTextScaleKey))
        }
        return standardMessageTextScale
    }

    static func setMessageTextScale(_ scale: Double) {
        UserDefaults.standard.set(clampedMessageTextScale(scale), forKey: messageTextScaleKey)
        notifyDidChange()
    }

    static func clampedMessageTextScale(_ scale: Double) -> Double {
        min(maximumMessageTextScale, max(minimumMessageTextScale, scale))
    }

    static func messagePointSize(baseSize: Double, messageTextScale: Double? = nil) -> Double {
        baseSize * clampedMessageTextScale(messageTextScale ?? self.messageTextScale)
    }

    static var useMonoForMessages: Bool {
        UserDefaults.standard.bool(forKey: monoMessagesKey)
    }

    static func setUseMonoForMessages(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: monoMessagesKey)
        notifyDidChange()
    }

    static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func scaleForStoredCodeFontSizePreset(rawValue: String) -> Double {
        switch rawValue {
        case "compact": return 1.0
        case "standard": return 12.0 / 11.0
        case "comfortable": return 14.0 / 11.0
        case "large": return maximumCodeTextScale
        default: return standardCodeTextScale
        }
    }
}
