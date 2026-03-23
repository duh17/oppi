import UIKit

/// User-configurable font preferences, persisted via UserDefaults.
///
/// Two independent axes:
/// - `codeFont`: monospaced font for code blocks, tool output, diffs, inline code
/// - `useMonoForMessages`: when true, applies the code font to message body text too
///
/// Changes post a notification so observers (AppFont, caches) can rebuild.
enum FontPreferences {
    static let didChangeNotification = Notification.Name("FontPreferencesDidChange")

    private static let codeFontKey = "codeFontFamily"
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
