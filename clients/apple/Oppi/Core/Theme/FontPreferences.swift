import UIKit

/// User-configurable font preferences, persisted via UserDefaults.
///
/// Two independent axes:
/// - `codeFont`: monospaced font for code blocks, tool output, diffs, inline code
/// - `codeFontSize`: content size for dense monospaced/code surfaces
/// - `useMonoForMessages`: when true, applies the code font to message body text too
///
/// Changes post a notification so observers (AppFont, caches) can rebuild.
enum FontPreferences {
    static let didChangeNotification = Notification.Name("FontPreferencesDidChange")

    private static let codeFontKey = "codeFontFamily"
    private static let codeFontSizeKey = "codeFontSize"
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

    // MARK: - Code Font Size

    enum CodeFontSize: String, CaseIterable, Identifiable, Sendable {
        case compact
        case standard
        case comfortable
        case large

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .compact: return "Compact"
            case .standard: return "Standard"
            case .comfortable: return "Comfortable"
            case .large: return "Large"
            }
        }

        var detail: String {
            switch self {
            case .compact: return "11 pt iPhone, 12 pt iPad"
            case .standard: return "12 pt iPhone, 13 pt iPad"
            case .comfortable: return "14 pt iPhone, 15 pt iPad"
            case .large: return "16 pt iPhone, 17 pt iPad"
            }
        }

        fileprivate var phoneRegularPointSize: CGFloat {
            switch self {
            case .compact: return 11
            case .standard: return 12
            case .comfortable: return 14
            case .large: return 16
            }
        }
    }

    /// Current code font size. Defaults to Standard so primary code content is
    /// above Apple's 11 pt iOS/iPadOS minimum, while still keeping dense diffs
    /// and terminal output usable on iPhone.
    static var codeFontSize: CodeFontSize {
        guard let raw = UserDefaults.standard.string(forKey: codeFontSizeKey),
              let size = CodeFontSize(rawValue: raw) else {
            return .standard
        }
        return size
    }

    /// Set the code font size and rebuild all font constants.
    @MainActor
    static func setCodeFontSize(_ size: CodeFontSize) {
        UserDefaults.standard.set(size.rawValue, forKey: codeFontSizeKey)
        AppFont.rebuild()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func codePointSize(
        baseSize: CGFloat,
        idiom: UIUserInterfaceIdiom = currentIdiom
    ) -> CGFloat {
        let selectedRegularSize = codeFontSize.phoneRegularPointSize
        let baseRegularSize: CGFloat = 11
        let platformDelta: CGFloat = idiom == .pad ? 1 : 0
        return max(11, baseSize + (selectedRegularSize - baseRegularSize) + platformDelta)
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
