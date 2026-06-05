import UIKit

/// User-configurable font preferences, persisted via UserDefaults.
///
/// Two independent axes:
/// - `codeFont`: monospaced font for code blocks, tool output, diffs, inline code
/// - `codeTextScale`: local text scale for dense monospaced/code surfaces
/// - `messageTextScale`: local text scale for chat message body text
/// - `useMonoForMessages`: when true, applies the code font to message body text too
///
/// Changes post a notification so observers (AppFont, caches) can rebuild.
enum FontPreferences {
    static let didChangeNotification = Notification.Name("FontPreferencesDidChange")
    static let minimumCodeTextScale: CGFloat = 0.85
    static let standardCodeTextScale: CGFloat = 1.0
    static let maximumCodeTextScale: CGFloat = 1.45
    static let minimumMessageTextScale: CGFloat = 0.90
    static let standardMessageTextScale: CGFloat = 1.0
    static let maximumMessageTextScale: CGFloat = 1.35
    private static let defaultEffectiveCodeTextScale: CGFloat = 1.10

    private static let codeFontKey = "codeFontFamily"
    private static let codeTextScaleKey = "codeTextRelativeScale"
    private static let storedEffectiveCodeTextScaleKey = "codeTextScale"
    private static let codeFontSizePresetKey = "codeFontSize"
    private static let messageTextScaleKey = "messageTextScale"
    private static let monoMessagesKey = "useMonoForMessages"

    // MARK: - Code Font

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

        /// Font name prefix for UIFont(name:size:). nil means use system mono.
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

        /// PostScript name suffix for each weight.
        func postScriptName(weight: UIFont.Weight) -> String? {
            guard let prefix = fontNamePrefix else { return nil }
            let suffix: String
            switch weight {
            case .bold:
                suffix = "Bold"
            case .semibold:
                // Source Code Pro uses "Semibold" (lowercase b), others use "SemiBold"
                suffix = self == .sourceCodePro ? "Semibold" : "SemiBold"
            default:
                suffix = "Regular"
            }
            return "\(prefix)-\(suffix)"
        }

        /// Create a UIFont for the given size and weight. Falls back to system mono if the font can't be loaded.
        func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            if let psName = postScriptName(weight: weight),
               let font = UIFont(name: psName, size: size) {
                return font
            }
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    // MARK: - Code Text Scale

    /// Current user-facing code text scale. Defaults to 100%, where 100% maps
    /// to the app's readable code baseline. iPhone and iPad use the same scale;
    /// each device persists its own local value through UserDefaults.
    static var codeTextScale: CGFloat {
        if UserDefaults.standard.object(forKey: codeTextScaleKey) != nil {
            return clampedCodeTextScale(UserDefaults.standard.double(forKey: codeTextScaleKey))
        }

        if UserDefaults.standard.object(forKey: storedEffectiveCodeTextScaleKey) != nil {
            return clampedCodeTextScale(
                UserDefaults.standard.double(forKey: storedEffectiveCodeTextScaleKey) / defaultEffectiveCodeTextScale
            )
        }

        if let presetRaw = UserDefaults.standard.string(forKey: codeFontSizePresetKey) {
            return scaleForStoredCodeFontSizePreset(rawValue: presetRaw)
        }

        return standardCodeTextScale
    }

    /// Set the code text scale and rebuild all font constants.
    @MainActor
    static func setCodeTextScale(_ scale: CGFloat) {
        UserDefaults.standard.set(clampedCodeTextScale(scale), forKey: codeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: storedEffectiveCodeTextScaleKey)
        UserDefaults.standard.removeObject(forKey: codeFontSizePresetKey)
        AppFont.rebuild()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func clampedCodeTextScale(_ scale: CGFloat) -> CGFloat {
        min(maximumCodeTextScale, max(minimumCodeTextScale, scale))
    }

    private static func scaleForStoredCodeFontSizePreset(rawValue: String) -> CGFloat {
        switch rawValue {
        case "compact": return 1.0
        case "standard": return 12 / 11
        case "comfortable": return 14 / 11
        case "large": return maximumCodeTextScale
        default: return standardCodeTextScale
        }
    }

    static func codePointSize(
        baseSize: CGFloat,
        idiom: UIUserInterfaceIdiom = currentIdiom
    ) -> CGFloat {
        _ = idiom
        return codePointSize(baseSize: baseSize, codeTextScale: codeTextScale)
    }

    static func codePointSize(baseSize: CGFloat, codeTextScale: CGFloat) -> CGFloat {
        (baseSize * effectiveCodeTextScale(codeTextScale)).rounded()
    }

    static func effectiveCodeTextScale(_ codeTextScale: CGFloat) -> CGFloat {
        clampedCodeTextScale(codeTextScale) * defaultEffectiveCodeTextScale
    }

    // MARK: - Message Text Scale

    /// Current chat message body scale. Defaults to 100%.
    static var messageTextScale: CGFloat {
        if UserDefaults.standard.object(forKey: messageTextScaleKey) != nil {
            return clampedMessageTextScale(UserDefaults.standard.double(forKey: messageTextScaleKey))
        }
        return standardMessageTextScale
    }

    /// Set the chat message body scale and rebuild all font constants.
    @MainActor
    static func setMessageTextScale(_ scale: CGFloat) {
        UserDefaults.standard.set(clampedMessageTextScale(scale), forKey: messageTextScaleKey)
        AppFont.rebuild()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func clampedMessageTextScale(_ scale: CGFloat) -> CGFloat {
        min(maximumMessageTextScale, max(minimumMessageTextScale, scale))
    }

    static func messagePointSize(baseSize: CGFloat) -> CGFloat {
        baseSize * messageTextScale
    }

    static func messagePointSize(baseSize: CGFloat, messageTextScale: CGFloat) -> CGFloat {
        baseSize * clampedMessageTextScale(messageTextScale)
    }

    static func scaledCodeFont(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        idiom: UIUserInterfaceIdiom = currentIdiom,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let baseFont = codeFont.font(
            size: codePointSize(baseSize: baseSize, idiom: idiom),
            weight: weight
        )
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        if let traitCollection {
            return metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
        }
        return metrics.scaledFont(for: baseFont)
    }

    private static var currentIdiom: UIUserInterfaceIdiom {
        guard Thread.isMainThread else { return .phone }
        return MainActor.assumeIsolated {
            UIDevice.current.userInterfaceIdiom
        }
    }

    /// Current code font family.
    static var codeFont: CodeFontFamily {
        guard let raw = UserDefaults.standard.string(forKey: codeFontKey),
              let family = CodeFontFamily(rawValue: raw) else {
            return .system
        }
        return family
    }

    /// Set the code font and rebuild all font constants.
    @MainActor
    static func setCodeFont(_ family: CodeFontFamily) {
        UserDefaults.standard.set(family.rawValue, forKey: codeFontKey)
        AppFont.rebuild()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Mono Messages

    /// Whether message body text uses the selected code font.
    static var useMonoForMessages: Bool {
        UserDefaults.standard.bool(forKey: monoMessagesKey)
    }

    /// Set mono messages preference and rebuild all font constants.
    @MainActor
    static func setUseMonoForMessages(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: monoMessagesKey)
        AppFont.rebuild()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
